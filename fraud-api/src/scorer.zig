const std = @import("std");
const builtin = @import("builtin");
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
pub const NPROBE: u32 = 16;
pub const TOTAL_SCAN_BUDGET: u32 = 6_000;
const REFINE_SCAN_BUDGET: u32 = 3_000_000;
const STATS_SAMPLE_SHIFT: u6 = 6;
const STATS_SAMPLE_RATE: u64 = @as(u64, 1) << STATS_SAMPLE_SHIFT;

const TopK = struct {
    distances: [K]i64,
    indices: [K]u32,
    count: u32,

    fn init() TopK {
        var t = TopK{
            .distances = undefined,
            .indices = undefined,
            .count = 0,
        };
        @memset(&t.distances, 0);
        @memset(&t.indices, 0);
        return t;
    }

    fn insert(t: *TopK, dist: i64, idx: u32) bool {
        if (t.count < K) {
            var pos = t.count;
            while (pos > 0 and dist < t.distances[pos - 1]) : (pos -= 1) {
                t.distances[pos] = t.distances[pos - 1];
                t.indices[pos] = t.indices[pos - 1];
            }
            t.distances[pos] = dist;
            t.indices[pos] = idx;
            t.count += 1;
            return true;
        }

        if (dist >= t.distances[K - 1]) return false;

        var pos: u32 = K - 1;
        while (pos > 0 and dist < t.distances[pos - 1]) : (pos -= 1) {
            t.distances[pos] = t.distances[pos - 1];
            t.indices[pos] = t.indices[pos - 1];
        }
        t.distances[pos] = dist;
        t.indices[pos] = idx;
        return true;
    }

    fn insertUnique(t: *TopK, dist: i64, idx: u32) void {
        var i: u32 = 0;
        while (i < t.count) : (i += 1) {
            if (t.indices[i] == idx) return;
        }
        _ = t.insert(dist, idx);
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

fn distance(q: *const QueryVector, v: []const i16) i64 {
    var sum: i64 = 0;
    for (0..VECTOR_DIM) |i| {
        const diff = @as(i64, q[i]) - @as(i64, v[i]);
        sum += diff * diff;
    }
    return sum;
}

const Vec16I8 = @Vector(16, i8);
const Vec16I16 = @Vector(16, i16);
const Vec16I32 = @Vector(16, i32);
const Vec16I64 = @Vector(16, i64);

inline fn queryToVec16I16(q: *const QueryVector) Vec16I16 {
    return q.*;
}

inline fn queryToVec16I8(q: *const QueryVector) Vec16I8 {
    var vals: [16]i8 = undefined;
    inline for (0..16) |i| {
        const scaled = @divTrunc(q[i], 258);
        vals[i] = @as(i8, @intCast(std.math.clamp(scaled, @as(i16, -128), @as(i16, 127))));
    }
    return vals;
}

inline fn distanceFromCentroidBytesVec(q_i8: Vec16I8, vbytes: []const u8) i64 {
    const v_u8: @Vector(16, u8) = vbytes[0..16].*;
    const v_i8: Vec16I8 = @bitCast(v_u8);
    const diff: Vec16I16 = @as(Vec16I16, q_i8) - @as(Vec16I16, v_i8);
    const diff_i32: Vec16I32 = @as(Vec16I32, diff);
    const sq: Vec16I32 = diff_i32 * diff_i32;
    return @reduce(.Add, sq);
}

inline fn readVec16I16(vbytes: []const u8) Vec16I16 {
    var vals: [16]i16 = undefined;
    inline for (0..16) |i| {
        const off = i * 2;
        const raw = @as(u16, vbytes[off]) | (@as(u16, vbytes[off + 1]) << 8);
        vals[i] = @as(i16, @bitCast(raw));
    }
    return vals;
}

inline fn distanceFromBytesVec(q_i16: Vec16I16, vbytes: []const u8) i64 {
    const v_i16 = readVec16I16(vbytes);
    const diff: Vec16I16 = q_i16 - v_i16;
    const diff_i64: Vec16I64 = @as(Vec16I64, diff);
    const sq: Vec16I64 = diff_i64 * diff_i64;
    return @reduce(.Add, sq);
}

inline fn shouldSampleStats(req_num: u64) bool {
    return (req_num & (STATS_SAMPLE_RATE - 1)) == 0;
}

fn getPerfEnv(name: []const u8) ?[]const u8 {
    if (!builtin.is_test) return null;
    return std.process.Environ.getPosix(std.testing.environ, name);
}

fn perfTestsEnabled() bool {
    const raw = getPerfEnv("RUN_PERF_TESTS") orelse return false;
    return std.mem.eql(u8, raw, "1") or std.ascii.eqlIgnoreCase(raw, "true") or std.ascii.eqlIgnoreCase(raw, "yes");
}

fn parseEnvU64(name: []const u8, default_value: u64) u64 {
    const raw = getPerfEnv(name) orelse return default_value;
    return std.fmt.parseInt(u64, raw, 10) catch default_value;
}

fn monotonicNowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn runScorePerfGate() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const warmup_iters = @max(parseEnvU64("PERF_WARMUP_ITERS", 5_000), 1);
    const iters = @max(parseEnvU64("PERF_ITERS", 20_000), 1);
    const max_ns = @max(parseEnvU64("PERF_MAX_NS", 3_500), 1);
    const data_dir = getPerfEnv("PERF_DATA_DIR") orelse "fraud-engine/vector-index";

    var ds = dataset.Dataset.init();
    defer ds.deinit();
    try ds.load(data_dir);

    var scorer_instance = Scorer.init(&ds);
    const query: QueryVector = .{ 7, -4, 31, -16, 22, 8, -11, 3, 9, -2, 5, 1, -7, 13, -19, 27 };
    var sink: f32 = 0.0;

    var i: u64 = 0;
    while (i < warmup_iters) : (i += 1) sink += scorer_instance.score(&query);

    const start_ns = monotonicNowNs();
    i = 0;
    while (i < iters) : (i += 1) sink += scorer_instance.score(&query);
    const end_ns = monotonicNowNs();
    if (end_ns <= start_ns) return error.SkipZigTest;

    const ns_per_op = (end_ns - start_ns) / iters;
    std.debug.print("perf(score): ns/op={d} max={d} iters={d} warmup={d} sink={d}\n", .{ ns_per_op, max_ns, iters, warmup_iters, sink });
    try std.testing.expect(ns_per_op <= max_ns);
    try std.testing.expect(!std.math.isNan(sink));
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

        const clusters_to_scan = @min(s.n_clusters, 256);
        const nprobe_count: usize = @intCast(@min(nprobe, s.n_clusters));
        const q_i8 = queryToVec16I8(query);
        var best_indices: [NPROBE]u32 = undefined;
        var best_dists: [NPROBE]i64 = undefined;
        @memset(&best_indices, 0);
        for (0..NPROBE) |k| best_dists[k] = std.math.maxInt(i64);

        var best_count: usize = 0;
        var i: u32 = 0;
        while (i < clusters_to_scan) : (i += 1) {
            const centroid_offset = @as(usize, i) * 16;
            const centroid_bytes = s.dataset.centroids_mmap[centroid_offset .. centroid_offset + 16];
            const dist = distanceFromCentroidBytesVec(q_i8, centroid_bytes);

            if (best_count < nprobe_count) {
                var pos = best_count;
                while (pos > 0 and dist < best_dists[pos - 1]) : (pos -= 1) {
                    best_dists[pos] = best_dists[pos - 1];
                    best_indices[pos] = best_indices[pos - 1];
                }
                best_dists[pos] = dist;
                best_indices[pos] = i;
                best_count += 1;
                continue;
            }

            if (nprobe_count == 0 or dist >= best_dists[nprobe_count - 1]) continue;

            var pos = nprobe_count - 1;
            while (pos > 0 and dist < best_dists[pos - 1]) : (pos -= 1) {
                best_dists[pos] = best_dists[pos - 1];
                best_indices[pos] = best_indices[pos - 1];
            }
            best_dists[pos] = dist;
            best_indices[pos] = i;
        }

        for (0..nprobe_count) |k| {
            result[k] = best_indices[k];
        }

        return result;
    }

    pub fn score(s: *const Scorer, query: *const QueryVector) f32 {
        const req_num = runtime_stats.requests.fetchAdd(1, .monotonic) + 1;
        const sample_stats = shouldSampleStats(req_num);
        if (s.n_clusters == 0 or s.dataset.vectors_mmap.len == 0) {
            return 0.0;
        }

        const cluster_indices = s.findNearestClusters(query, NPROBE);
        const q_i16 = queryToVec16I16(query);

        const max_vec_idx = @as(u32, @truncate(s.dataset.vectors_mmap.len / 32));
        var top_k = TopK.init();
        var cluster_contrib: [NPROBE]u32 = undefined;
        @memset(&cluster_contrib, 0);

        const pass1_budget = @as(u32, @intCast(@as(u64, TOTAL_SCAN_BUDGET) * 60 / 100));
        var remaining_budget: u32 = pass1_budget;
        const probes_total: usize = NPROBE;
        for (0..probes_total) |i| {
            if (remaining_budget == 0) break;

            const cluster_id = cluster_indices[i];
            if (cluster_id >= s.n_clusters) continue;

            if (top_k.count >= K) {
                const centroid_offset = @as(usize, cluster_id) * 16;
                const ptr = @as([*]const u8, @ptrFromInt(@intFromPtr(s.dataset.centroids_mmap.ptr) + centroid_offset));
                const c_u8: @Vector(16, u8) = ptr[0..16].*;
                const c_i8: Vec16I8 = @bitCast(c_u8);
                const c_i16: Vec16I16 = @as(Vec16I16, c_i8);
                const c_diff: Vec16I16 = q_i16 - c_i16;
                const c_diff_i32: Vec16I32 = @as(Vec16I32, c_diff);
                const c_sq: Vec16I32 = c_diff_i32 * c_diff_i32;
                const centroid_dist = @reduce(.Add, c_sq);
                if (centroid_dist >= top_k.distances[K - 1]) continue;
            }

            const range = s.dataset.clusterRange(cluster_id);
            if (range.start >= range.end) continue;

            const start = range.start;
            const end = @min(range.end, max_vec_idx);
            if (end <= start) continue;

            const probes_left = @as(u32, @intCast(probes_total - i));
            const per_cluster_budget = @max(@divTrunc(remaining_budget, probes_left), 1);
            const cluster_len = end - start;
            const scan_len = @min(cluster_len, per_cluster_budget);
            const scan_end = start + scan_len;

            if (sample_stats) {
                _ = runtime_stats.cluster_scanned_vectors.fetchAdd(@as(u64, scan_len) * STATS_SAMPLE_RATE, .monotonic);
            }
            remaining_budget -|= scan_len;

            const vec_start = @as(u64, start) * 32;
            const vec_end = @as(u64, scan_end) * 32;
            if (vec_end > s.dataset.vectors_mmap.len) continue;

            const vec_slice = s.dataset.vectors_mmap[vec_start..vec_end];
            var j: u32 = 0;
            while (j < scan_len) : (j += 1) {
                const vec_offset = @as(u64, j) * 32;
                if (vec_offset + 32 > vec_slice.len) break;

                if (j + 2 < scan_len) {
                    const pf_offset = @as(usize, @intCast((@as(u64, j) + 2) * 32));
                    if (pf_offset + 32 <= vec_slice.len) {
                        @prefetch(vec_slice.ptr + pf_offset, .{ .rw = .read, .cache = .data, .locality = 3 });
                    }
                }

                const ptr = @as([*]const u8, @ptrFromInt(@intFromPtr(vec_slice.ptr) + vec_offset));
                const dist = distanceFromBytesVec(q_i16, ptr[0..32]);
                const global_idx = start + j;
                if (top_k.insert(dist, global_idx)) {
                    cluster_contrib[i] += 1;
                }
            }
        }

        const pass2_budget = TOTAL_SCAN_BUDGET - pass1_budget;
        var pass2_clusters: [2]u32 = .{ 0, 0 };
        var pass2_counts: [2]u32 = .{ 0, 0 };

        var c: u32 = 0;
        while (c < probes_total) : (c += 1) {
            if (cluster_contrib[c] > 0) {
                if (cluster_contrib[c] >= pass2_counts[0]) {
                    pass2_counts[1] = pass2_counts[0];
                    pass2_clusters[1] = pass2_clusters[0];
                    pass2_counts[0] = cluster_contrib[c];
                    pass2_clusters[0] = @as(u32, @intCast(c));
                } else if (cluster_contrib[c] >= pass2_counts[1]) {
                    pass2_counts[1] = cluster_contrib[c];
                    pass2_clusters[1] = @as(u32, @intCast(c));
                }
            }
        }

        if (pass2_counts[0] > 0) {
            const total_pass2_contrib = pass2_counts[0] + pass2_counts[1];
            var p: u2 = 0;
            while (p < 2) : (p += 1) {
                if (pass2_clusters[p] >= s.n_clusters) continue;
                const probe_idx = pass2_clusters[p];
                if (probe_idx >= NPROBE) continue;
                const ci = cluster_indices[probe_idx];
                if (ci >= s.n_clusters) continue;
                const range = s.dataset.clusterRange(ci);
                if (range.start >= range.end) continue;

                const start = range.start;
                const end = @min(range.end, max_vec_idx);
                if (end <= start) continue;

                const cluster_len = end - start;
                const alloc_budget = @as(u32, @intCast(@as(u64, pass2_budget) * @as(u64, pass2_counts[p]) / @as(u64, total_pass2_contrib)));
                const scan_len = @min(cluster_len, @max(alloc_budget, 1));
                const scan_end = start + scan_len;

                if (sample_stats) {
                    _ = runtime_stats.cluster_scanned_vectors.fetchAdd(@as(u64, scan_len) * STATS_SAMPLE_RATE, .monotonic);
                }

                const vec_start = @as(u64, start) * 32;
                const vec_end = @as(u64, scan_end) * 32;
                if (vec_end > s.dataset.vectors_mmap.len) continue;

                const vec_slice = s.dataset.vectors_mmap[vec_start..vec_end];
                var j: u32 = 0;
                while (j < scan_len) : (j += 1) {
                    const vec_offset = @as(u64, j) * 32;
                    if (vec_offset + 32 > vec_slice.len) break;

                    if (j + 2 < scan_len) {
                        const pf_offset = @as(usize, @intCast((@as(u64, j) + 2) * 32));
                        if (pf_offset + 32 <= vec_slice.len) {
                            @prefetch(vec_slice.ptr + pf_offset, .{ .rw = .read, .cache = .data, .locality = 3 });
                        }
                    }

                    const ptr = @as([*]const u8, @ptrFromInt(@intFromPtr(vec_slice.ptr) + vec_offset));
                    const dist = distanceFromBytesVec(q_i16, ptr[0..32]);
                    top_k.insertUnique(dist, start + j);
                }
            }
        }

        if (top_k.count < K) {
            if (sample_stats) {
                _ = runtime_stats.fallback_hits.fetchAdd(STATS_SAMPLE_RATE, .monotonic);
            }
            if (sample_stats) {
                _ = runtime_stats.fallback_scanned_vectors.fetchAdd(@as(u64, max_vec_idx) * STATS_SAMPLE_RATE, .monotonic);
            }
            var idx: u32 = 0;
            while (idx < max_vec_idx) : (idx += 1) {
                const vec_offset = @as(u64, idx) * 32;
                if (vec_offset + 32 > s.dataset.vectors_mmap.len) break;

                const ptr = @as([*]const u8, @ptrFromInt(@intFromPtr(s.dataset.vectors_mmap.ptr) + vec_offset));
                const dist = distanceFromBytesVec(q_i16, ptr[0..32]);
                top_k.insertUnique(dist, idx);
            }
        }

        if (top_k.count == 0) return 0.0;

        var fraud_count: u32 = 0;
        for (0..top_k.count) |i| {
            const label = s.dataset.labelAt(top_k.indices[i]);
            if (label == 1) fraud_count += 1;
        }

        if (top_k.count == K and fraud_count > 0 and fraud_count < K) {
            return s.refineClusterScore(query, max_vec_idx, &cluster_indices);
        }

        return @as(f32, @floatFromInt(fraud_count)) / @as(f32, @floatFromInt(top_k.count));
    }

    fn refineClusterScore(s: *const Scorer, query: *const QueryVector, max_vec_idx: u32, cluster_indices: *const [NPROBE]u32) f32 {
        const q_i16 = queryToVec16I16(query);
        var top_k = TopK.init();
        var remaining_budget: u32 = REFINE_SCAN_BUDGET;

        for (0..NPROBE) |probe_idx| {
            if (remaining_budget == 0) break;
            const cluster_id = cluster_indices[probe_idx];
            if (cluster_id >= s.n_clusters) continue;
            const range = s.dataset.clusterRange(cluster_id);
            if (range.start >= range.end) continue;

            const end = @min(range.end, max_vec_idx);
            const cluster_len = end - range.start;
            const probes_left = @as(u32, @intCast(NPROBE - probe_idx));
            const scan_len = @min(cluster_len, @max(@divTrunc(remaining_budget, probes_left), 1));
            remaining_budget -|= scan_len;
            const scan_end = range.start + scan_len;
            var idx = range.start;
            while (idx < scan_end) : (idx += 1) {
                const vec_offset = @as(u64, idx) * 32;
                if (vec_offset + 32 > s.dataset.vectors_mmap.len) break;

                const ptr = @as([*]const u8, @ptrFromInt(@intFromPtr(s.dataset.vectors_mmap.ptr) + vec_offset));
                const dist = distanceFromBytesVec(q_i16, ptr[0..32]);
                top_k.insertUnique(dist, idx);
            }
        }

        if (top_k.count == 0) return 0.0;

        var fraud_count: u32 = 0;
        for (0..top_k.count) |i| {
            if (s.dataset.labelAt(top_k.indices[i]) == 1) fraud_count += 1;
        }
        return @as(f32, @floatFromInt(fraud_count)) / @as(f32, @floatFromInt(top_k.count));
    }

    pub fn scoreWithRefIndexCount(s: *const Scorer, query: *const QueryVector, ref_index_count: u32) f32 {
        if (ref_index_count == 0) return 0.0;
        return s.score(query);
    }
};

test "distance from bytes equals distance from array" {
    const q: QueryVector = .{ 1200, -800, 3100, -4400, 700, 9000, -300, 5500, -1200, 400, 0, 9900, -12700, 1800, 7600, -6400 };
    const raw: [32]u8 = .{ 1, 0, 255, 255, 10, 0, 250, 255, 17, 0, 222, 255, 13, 0, 205, 255, 48, 0, 10, 0, 200, 255, 7, 0, 128, 255, 99, 0, 54, 0, 180, 255 };

    var v: [16]i16 = undefined;
    for (0..16) |i| {
        const off = i * 2;
        const bits = @as(u16, raw[off]) | (@as(u16, raw[off + 1]) << 8);
        v[i] = @as(i16, @bitCast(bits));
    }

    const want = distance(&q, &v);
    const got = distanceFromBytesVec(queryToVec16I16(&q), raw[0..]);
    try std.testing.expectEqual(want, got);
}

test "topk insertUnique ignores duplicate indices" {
    var topk = TopK.init();
    _ = topk.insert(40, 10);
    topk.insertUnique(20, 10);
    try std.testing.expectEqual(@as(u32, 1), topk.count);
    try std.testing.expectEqual(@as(i64, 40), topk.distances[0]);
}

test "topk keeps sorted best distances" {
    var topk = TopK.init();
    _ = topk.insert(30, 1);
    _ = topk.insert(10, 2);
    _ = topk.insert(20, 3);
    try std.testing.expectEqual(@as(i64, 10), topk.distances[0]);
    try std.testing.expectEqual(@as(i64, 20), topk.distances[1]);
    try std.testing.expectEqual(@as(i64, 30), topk.distances[2]);

    _ = topk.insert(40, 4);
    _ = topk.insert(50, 5);
    _ = topk.insert(25, 6);
    try std.testing.expectEqual(@as(i64, 10), topk.distances[0]);
    try std.testing.expectEqual(@as(i64, 20), topk.distances[1]);
    try std.testing.expectEqual(@as(i64, 25), topk.distances[2]);
    try std.testing.expectEqual(@as(i64, 30), topk.distances[3]);
    try std.testing.expectEqual(@as(i64, 40), topk.distances[4]);
}

test "shouldSampleStats samples each 64 requests" {
    try std.testing.expect(!shouldSampleStats(1));
    try std.testing.expect(!shouldSampleStats(63));
    try std.testing.expect(shouldSampleStats(64));
    try std.testing.expect(shouldSampleStats(128));
}

test "score hot path performance gate" {
    if (!perfTestsEnabled()) return error.SkipZigTest;
    try runScorePerfGate();
}
