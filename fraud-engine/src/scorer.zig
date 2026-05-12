const std = @import("std");
const quantization = @import("quantization.zig");
const dataset = @import("dataset.zig");

pub const RuntimeStats = struct {
    requests: std.atomic.Value(u64) = .init(0),
    fallback_hits: std.atomic.Value(u64) = .init(0),
    fallback_scanned_vectors: std.atomic.Value(u64) = .init(0),
    cluster_scanned_vectors: std.atomic.Value(u64) = .init(0),
};

pub var runtime_stats: RuntimeStats = .{};

pub const QueryVector = quantization.QueryVector;
pub const VECTOR_DIM = 16;
pub const K: u32 = 5;
pub const NPROBE: u32 = 8;
pub const TOTAL_SCAN_BUDGET: u32 = 28_000;

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

    fn contains(t: *const TopK, idx: u32) bool {
        var i: u32 = 0;
        while (i < t.count) : (i += 1) {
            if (t.indices[i] == idx) return true;
        }
        return false;
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
        _ = runtime_stats.requests.fetchAdd(1, .monotonic);
        if (s.n_clusters == 0 or s.dataset.vectors_mmap.len == 0) {
            return 0.0;
        }

        const cluster_indices = s.findNearestClusters(query, NPROBE);

        var top_k = TopK.init();

        var remaining_budget: u32 = TOTAL_SCAN_BUDGET;
        for (0..NPROBE) |i| {
            if (remaining_budget == 0) break;
            const cluster_id = cluster_indices[i];
            if (cluster_id >= s.n_clusters) continue;

            const range = s.dataset.clusterRange(cluster_id);
            if (range.start >= range.end) continue;

            const max_vec_idx = @as(u32, @truncate(s.dataset.vectors_mmap.len / 16));
            const start = range.start;
            const end = @min(range.end, max_vec_idx);
            if (end <= start) continue;

            const probes_left = @as(u32, @intCast(NPROBE - i));
            const per_cluster_budget = @max(@divTrunc(remaining_budget, probes_left), 1);
            const cluster_len = end - start;
            const scan_len = @min(cluster_len, per_cluster_budget);
            const scan_end = start + scan_len;

            _ = runtime_stats.cluster_scanned_vectors.fetchAdd(@as(u64, scan_len), .monotonic);
            remaining_budget -|= scan_len;

            const vec_start = @as(u64, start) * 16;
            const vec_end = @as(u64, scan_end) * 16;
            if (vec_end > s.dataset.vectors_mmap.len) continue;

            const vec_slice = s.dataset.vectors_mmap[vec_start..vec_end];
            var j: u32 = 0;
            while (j < scan_len) : (j += 1) {
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

        if (top_k.count < K) {
            _ = runtime_stats.fallback_hits.fetchAdd(1, .monotonic);
            const max_vec_idx = @as(u32, @truncate(s.dataset.vectors_mmap.len / 16));
            _ = runtime_stats.fallback_scanned_vectors.fetchAdd(@as(u64, max_vec_idx), .monotonic);
            var idx: u32 = 0;
            while (idx < max_vec_idx) : (idx += 1) {
                var v: [16]i8 = undefined;
                const vec_offset = @as(u64, idx) * 16;
                if (vec_offset + 16 > s.dataset.vectors_mmap.len) break;

                for (0..16) |dim| {
                    v[dim] = @as(i8, @bitCast(s.dataset.vectors_mmap[vec_offset + dim]));
                }

                if (top_k.contains(idx)) continue;

                const dist = distance(query, &v);
                top_k.insert(dist, idx);
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
