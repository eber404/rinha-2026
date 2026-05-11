const std = @import("std");
const json = std.json;

const DIMS: u32 = 14;
const NUM_CLUSTERS: u32 = 256;

const Record = struct {
    vector: [DIMS]f32,
    label: []const u8,
};

pub fn main() void {
    const data_dir = "./data";
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=== Reading references.json...\n", .{});
    const path = std.fmt.allocPrintZ(allocator, "{s}/references.json", .{data_dir}) catch return;
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1_000_000_000) catch |err| {
        std.debug.print("Failed to read file: {}\n", .{err});
        return;
    };

    const parsed = json.parseFromSlice([]json.Value, allocator, content, .{}) catch |err| {
        std.debug.print("Failed to parse JSON: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    const records = parsed.value;
    const N: u32 = @intCast(records.len);
    std.debug.print("Loaded {d} records\n", .{N});

    var labels = allocator.alloc(u8, N) catch return;
    var means = allocator.alloc(f32, DIMS) catch return;
    var stds = allocator.alloc(f32, DIMS) catch return;
    var mins = allocator.alloc(f32, DIMS) catch return;
    var maxs = allocator.alloc(f32, DIMS) catch return;

    for (0..DIMS) |d| mins[d] = 99999;
    for (0..DIMS) |d| maxs[d] = -99999;

    for (0..DIMS) |d| means[d] = 0;

    for (record_array in records) |rec| {
        const vec = rec.object.get("vector").?.array;
        for (0..DIMS) |d| {
            const val = vec[d].float;
            means[d] += val;
            if (val < mins[d]) mins[d] = val;
            if (val > maxs[d]) maxs[d] = val;
        }
        const label = rec.object.get("label").?.string;
        labels[@intFromPtr(record_array) / @sizeOf(json.Value)] = if (std.mem.eql(u8, label, "fraud")) 1 else 0;
    }

    for (0..DIMS) |d| means[d] /= @as(f32, @floatFromInt(N));

    for (0..DIMS) |d| stds[d] = 0;
    for (record_array in records) |rec| {
        const vec = rec.object.get("vector").?.array;
        for (0..DIMS) |d| {
            const diff = vec[d].float - means[d];
            stds[d] += diff * diff;
        }
    }
    for (0..DIMS) |d| {
        stds[d] = @sqrt(stds[d] / @as(f32, @floatFromInt(N)));
        if (stds[d] < 1e-6) stds[d] = 1;
    }

    std.debug.print("=== Normalizing and quantizing to int8...\n", .{});
    var vectors_i8 = allocator.alloc(u8, N * 16) catch return;

    for (i, rec) in records.len) |i, rec| {
        const vec = rec.object.get("vector").?.array;
        for (0..DIMS) |d| {
            const normalized = (vec[d].float - means[d]) / stds[d];
            var q: i32 = @intFromFloat(@round(normalized * 127));
            if (q > 127) q = 127;
            if (q < -127) q = -127;
            if (q < 0) q += 256;
            vectors_i8[i * 16 + d] = @as(u8, @intCast(q));
        }
    }

    std.debug.print("=== Computing centroids via sampling...\n", .{});
    var centroids = allocator.alloc(f32, NUM_CLUSTERS * DIMS) catch return;
    var cluster_counts = allocator.alloc(u32, NUM_CLUSTERS) catch return;

    const sample_size = @min(N, 50000);
    var rng_seed: u32 = @intCast(std.time.timestamp());

    for (0..sample_size) |i| {
        rng_seed = rng_seed * 1664525 + 1013904223;
        const idx = @as(u32, rng_seed) % N;
        const c = @as(u32, @intCast(i)) % NUM_CLUSTERS;
        cluster_counts[c] += 1;
        const vec = records[idx].object.get("vector").?.array;
        for (0..DIMS) |d| {
            centroids[c * DIMS + d] += vec[d].float;
        }
    }

    for (0..NUM_CLUSTERS) |c| {
        if (cluster_counts[c] > 0) {
            for (0..DIMS) |d| {
                centroids[c * DIMS + d] /= @intToFloat(f32, cluster_counts[c]);
            }
        }
    }

    std.debug.print("=== Writing binary files...\n", .{});

    const vectors_path = std.fmt.allocPrintZ(allocator, "{s}/vectors_i8.bin", .{data_dir}) catch return;
    std.fs.cwd().writeFile(vectors_path, vectors_i8) catch return;
    std.debug.print("  vectors_i8.bin: {d} bytes\n", .{N * 16});

    const labels_slice = labels[0..N];
    const labels_path = std.fmt.allocPrintZ(allocator, "{s}/labels.bin", .{data_dir}) catch return;
    std.fs.cwd().writeFile(labels_path, labels_slice) catch return;
    std.debug.print("  labels.bin: {d} bytes\n", .{N});

    const centroids_i8 = allocator.alloc(u8, NUM_CLUSTERS * 16) catch return;
    for (c in 0..NUM_CLUSTERS) |c| {
        for (d in 0..DIMS) |d| {
            const val = centroids[c * DIMS + d];
            const normalized = (val - means[d]) / stds[d];
            var q: i32 = @intFromFloat(@round(normalized * 127));
            if (q > 127) q = 127;
            if (q < -127) q = -127;
            if (q < 0) q += 256;
            centroids_i8[c * 16 + d] = @as(u8, @intCast(q));
        }
    }

    const centroids_path = std.fmt.allocPrintZ(allocator, "{s}/centroids_i8.bin", .{data_dir}) catch return;
    std.fs.cwd().writeFile(centroids_path, centroids_i8) catch return;
    std.debug.print("  centroids_i8.bin: {d} bytes\n", .{NUM_CLUSTERS * 16});

    std.debug.print("\nDone!\n", .{});
}