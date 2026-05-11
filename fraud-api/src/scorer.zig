const std = @import("std");
const quantization = @import("quantization.zig");
const dataset = @import("dataset.zig");

pub const QueryVector = quantization.QueryVector;
pub const VECTOR_DIM = 16;
pub const K: u32 = 5;
pub const NPROBE: u32 = 8;

const TopK = struct {
    distances: [K]i32,
    indices: [K]u32,
    count: u32,

    fn init() TopK {
        return .{
            .distances = [_]i32{0} ** K,
            .indices = [_]u32{0} ** K,
            .count = 0,
        };
    }

    fn insert(t: *TopK, dist: i32, idx: u32) void {
        if (t.count < K) {
            t.distances[t.count] = dist;
            t.indices[t.count] = idx;
            t.count += 1;
        } else {
            var worst_idx: u32 = 0;
            var worst_dist: i32 = t.distances[0];
            var i: u32 = 1;
            while (i < K) : (i += 1) {
                if (t.distances[i] > worst_dist) {
                    worst_dist = t.distances[i];
                    worst_idx = i;
                }
            }
            if (dist < worst_dist) {
                t.distances[worst_idx] = dist;
                t.indices[worst_idx] = idx;
            }
        }
    }

    fn reset(t: *TopK) void {
        t.count = 0;
        @memset(&t.distances, 0);
        @memset(&t.indices, 0);
    }
};

fn distance(q: *const QueryVector, v: []const i8) i32 {
    var sum: i32 = 0;
    for (0..VECTOR_DIM) |i| {
        const diff = @as(i32, q[i]) - @as(i32, v[i]);
        sum += diff * diff;
    }
    return sum;
}

pub const Scorer = struct {
    dataset: *dataset.Dataset,
    n_clusters: u32,

    pub fn init(ds: *dataset.Dataset) Scorer {
        return .{
            .dataset = ds,
            .n_clusters = if (ds.centroids_mmap.len > 0)
                @as(u32, @truncate(ds.centroids_mmap.len / 16))
            else
                0,
        };
    }

    fn findNearestClusters(s: *const Scorer, query: *const QueryVector, nprobe: u32) [NPROBE]u32 {
        var result: [NPROBE]u32 = undefined;
        @memset(&result, 0);

        if (s.n_clusters == 0 or nprobe == 0) return result;

        var centroid_dists: [256]i32 = undefined;
        @memset(&centroid_dists, 0);

        const clusters_to_scan = @min(s.n_clusters, 256);
        var i: u32 = 0;
        while (i < clusters_to_scan) : (i += 1) {
            const c = s.dataset.centroidAt(i);
            centroid_dists[i] = distance(query, &c);
        }

        var selected: [256]bool = undefined;
        for (0..256) |sel_i| selected[sel_i] = false;

        const nprobe_count = @min(nprobe, s.n_clusters);
        var probe_i: u32 = 0;
        while (probe_i < nprobe_count) : (probe_i += 1) {
            var best_idx: u32 = 0;
            var best_dist: i32 = std.math.maxInt(i32);
            var j: u32 = 0;
            while (j < clusters_to_scan) : (j += 1) {
                if (!selected[j] and centroid_dists[j] < best_dist) {
                    best_dist = centroid_dists[j];
                    best_idx = j;
                }
            }
            result[probe_i] = best_idx;
            selected[best_idx] = true;
        }

        return result;
    }

    pub fn score(s: *const Scorer, query: *const QueryVector) f32 {
        if (s.n_clusters == 0 or s.dataset.vectors_mmap.len == 0) {
            return 0.0;
        }

        const cluster_indices = s.findNearestClusters(query, NPROBE);

        var top_k = TopK.init();

        for (0..NPROBE) |i| {
            const cluster_id = cluster_indices[i];
            if (cluster_id >= s.n_clusters) continue;

            const range = s.dataset.clusterRange(cluster_id);
            if (range.start >= range.end) continue;

            const max_vec_idx = @as(u32, @truncate(s.dataset.vectors_mmap.len / 16));
            const start = range.start;
            const end = @min(range.end, max_vec_idx);

            const vec_start = @as(u64, start) * 16;
            const vec_end = @as(u64, end) * 16;
            if (vec_end > s.dataset.vectors_mmap.len) continue;

            const vec_slice = s.dataset.vectors_mmap[vec_start..vec_end];
            var j: u32 = 0;
            while (j < end - start) : (j += 1) {
                const vec_offset = @as(u64, j) * 16;
                if (vec_offset + 16 > vec_slice.len) break;

                var v: [16]i8 = undefined;
                for (0..16) |dim| {
                    v[dim] = @as(i8, @bitCast(vec_slice[vec_offset + dim]));
                }

                const dist = distance(query, &v);
                const global_idx = start + j;
                top_k.insert(dist, global_idx);
            }
        }

        if (top_k.count == 0) return 0.0;

        var fraud_count: u32 = 0;
        for (0..top_k.count) |i| {
            const label = s.dataset.labelAt(top_k.indices[i]);
            if (label == 1) fraud_count += 1;
        }

        return @as(f32, @floatFromInt(fraud_count)) / @as(f32, @floatFromInt(top_k.count));
    }

    pub fn scoreWithRefIndexCount(s: *const Scorer, query: *const QueryVector, ref_index_count: u32) f32 {
        if (ref_index_count == 0) return 0.0;
        return s.score(query);
    }
};

test "topk insert maintains order" {
    var tk = TopK.init();
    tk.insert(100, 0);
    tk.insert(50, 1);
    tk.insert(75, 2);
    try std.testing.expect(tk.count == 3);
    try std.testing.expect(tk.distances[0] == 100);
    try std.testing.expect(tk.distances[1] == 50);
    try std.testing.expect(tk.distances[2] == 75);
}

test "topk insert replaces worst when full" {
    var tk = TopK.init();
    tk.insert(100, 0);
    tk.insert(90, 1);
    tk.insert(80, 2);
    tk.insert(70, 3);
    tk.insert(60, 4);
    try std.testing.expect(tk.count == 5);

    tk.insert(55, 5);
    try std.testing.expect(tk.count == 5);
    var worst: i32 = 0;
    for (0..tk.count) |i| {
        if (tk.distances[i] > worst) worst = tk.distances[i];
    }
    try std.testing.expect(worst == 90);
}

test "topk reset clears state" {
    var tk = TopK.init();
    tk.insert(100, 0);
    tk.reset();
    try std.testing.expect(tk.count == 0);
}

test "distance identical vectors" {
    const q: QueryVector = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const v = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const d = distance(&q, &v);
    try std.testing.expectEqual(@as(i32, 0), d);
}

test "distance differs" {
    const q: QueryVector = [_]i8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const v = [_]i8{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    const d = distance(&q, &v);
    try std.testing.expectEqual(@as(i32, 16), d);
}

test "distance with negative values" {
    const q: QueryVector = [_]i8{ -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10 };
    const v = [_]i8{ 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10 };
    const d = distance(&q, &v);
    try std.testing.expectEqual(@as(i32, 400 * 16), d);
}

test "scorer empty dataset returns zero" {
    var d = dataset.Dataset.init();
    defer d.deinit();
    var s = Scorer.init(&d);
    const q: QueryVector = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const score = s.score(&q);
    try std.testing.expectEqual(@as(f32, 0.0), score);
}

test "scoreWithRefIndexCount zero ref returns zero" {
    var d = dataset.Dataset.init();
    defer d.deinit();
    var s = Scorer.init(&d);
    const q: QueryVector = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const score = s.scoreWithRefIndexCount(&q, 0);
    try std.testing.expectEqual(@as(f32, 0.0), score);
}