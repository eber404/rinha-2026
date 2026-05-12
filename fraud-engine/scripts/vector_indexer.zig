const std = @import("std");
const json = std.json;

const DIMS: usize = 14;
const PADDED_DIMS: usize = 16;
const NUM_CLUSTERS: usize = 256;

fn valueToF32(v: json.Value) f32 {
    return switch (v) {
        .float => |x| @as(f32, @floatCast(x)),
        .integer => |x| @as(f32, @floatFromInt(x)),
        else => 0.0,
    };
}

fn quantizeSignedToByte(v: f32) u8 {
    var q: i32 = @intFromFloat(@round(v * 127.0));
    if (q > 127) q = 127;
    if (q < -128) q = -128;
    const signed: i8 = @intCast(q);
    return @bitCast(signed);
}

fn writeU32Le(buf: []u8, value: u32) void {
    buf[0] = @as(u8, @intCast(value & 0xff));
    buf[1] = @as(u8, @intCast((value >> 8) & 0xff));
    buf[2] = @as(u8, @intCast((value >> 16) & 0xff));
    buf[3] = @as(u8, @intCast((value >> 24) & 0xff));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const data_dir = "./fraud-engine/vector-index";

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fmt.allocPrint(allocator, "{s}/references.json", .{data_dir});
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1_000_000_000)) catch |err| {
        std.debug.print("read references failed: {}\n", .{err});
        return err;
    };

    const parsed = json.parseFromSlice([]json.Value, allocator, content, .{}) catch |err| {
        std.debug.print("parse references failed: {}\n", .{err});
        return err;
    };
    defer parsed.deinit();

    const records = parsed.value;
    const n = records.len;
    if (n == 0) return;

    var labels = try allocator.alloc(u8, n);

    for (records, 0..) |rec, i| {
        const label = rec.object.get("label").?.string;
        labels[i] = if (std.mem.eql(u8, label, "fraud")) 1 else 0;
    }

    var vectors_tmp = try allocator.alloc(u8, n * PADDED_DIMS);
    @memset(vectors_tmp, 0);

    for (records, 0..) |rec, i| {
        const vec = rec.object.get("vector").?.array.items;
        const base = i * PADDED_DIMS;
        for (0..DIMS) |d| {
            vectors_tmp[base + d] = quantizeSignedToByte(valueToF32(vec[d]));
        }
    }

    var centroids_f32 = try allocator.alloc(f32, NUM_CLUSTERS * DIMS);
    var centroid_counts = try allocator.alloc(u32, NUM_CLUSTERS);
    @memset(centroids_f32, 0.0);
    @memset(centroid_counts, 0);

    const sample_size = @min(n, 50_000);
    var seed: u32 = 0x12345678;
    for (0..sample_size) |i| {
        seed = seed * 1664525 + 1013904223;
        const idx = @as(usize, seed) % n;
        const c = i % NUM_CLUSTERS;
        centroid_counts[c] += 1;

        const vec = records[idx].object.get("vector").?.array.items;
        const centroid_base = c * DIMS;
        for (0..DIMS) |d| {
            centroids_f32[centroid_base + d] += valueToF32(vec[d]);
        }
    }

    for (0..NUM_CLUSTERS) |c| {
        if (centroid_counts[c] == 0) continue;
        const count_f: f32 = @floatFromInt(centroid_counts[c]);
        const centroid_base = c * DIMS;
        for (0..DIMS) |d| {
            centroids_f32[centroid_base + d] /= count_f;
        }
    }

    var centroids_i8 = try allocator.alloc(u8, NUM_CLUSTERS * PADDED_DIMS);
    @memset(centroids_i8, 0);
    for (0..NUM_CLUSTERS) |c| {
        const centroid_base = c * DIMS;
        const out_base = c * PADDED_DIMS;
        for (0..DIMS) |d| {
            centroids_i8[out_base + d] = quantizeSignedToByte(centroids_f32[centroid_base + d]);
        }
    }

    var assign = try allocator.alloc(u16, n);
    var cluster_counts = try allocator.alloc(u32, NUM_CLUSTERS);
    @memset(cluster_counts, 0);

    for (0..n) |i| {
        const vbase = i * PADDED_DIMS;
        var best_cluster: usize = 0;
        var best_dist: i64 = std.math.maxInt(i64);

        for (0..NUM_CLUSTERS) |c| {
            const cbase = c * PADDED_DIMS;
            var dist: i64 = 0;
            for (0..PADDED_DIMS) |d| {
                const v: i16 = @as(i8, @bitCast(vectors_tmp[vbase + d]));
                const k: i16 = @as(i8, @bitCast(centroids_i8[cbase + d]));
                const diff = @as(i32, v) - @as(i32, k);
                dist += @as(i64, diff * diff);
            }

            if (dist < best_dist) {
                best_dist = dist;
                best_cluster = c;
            }
        }

        assign[i] = @intCast(best_cluster);
        cluster_counts[best_cluster] += 1;
    }

    var cluster_offsets = try allocator.alloc(u32, NUM_CLUSTERS + 1);
    cluster_offsets[0] = 0;
    for (0..NUM_CLUSTERS) |c| {
        cluster_offsets[c + 1] = cluster_offsets[c] + cluster_counts[c];
    }

    var write_pos = try allocator.alloc(u32, NUM_CLUSTERS);
    @memcpy(write_pos, cluster_offsets[0..NUM_CLUSTERS]);

    var vectors_out = try allocator.alloc(u8, n * PADDED_DIMS);
    var labels_out = try allocator.alloc(u8, n);

    for (0..n) |i| {
        const c = assign[i];
        const pos = write_pos[c];
        write_pos[c] += 1;

        const src_base = i * PADDED_DIMS;
        const dst_base = @as(usize, pos) * PADDED_DIMS;
        @memcpy(vectors_out[dst_base .. dst_base + PADDED_DIMS], vectors_tmp[src_base .. src_base + PADDED_DIMS]);
        labels_out[pos] = labels[i];
    }

    const vectors_path = try std.fmt.allocPrint(allocator, "{s}/vectors_i8.bin", .{data_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = vectors_path, .data = vectors_out });

    const labels_path = try std.fmt.allocPrint(allocator, "{s}/labels.bin", .{data_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = labels_path, .data = labels_out });

    const centroids_path = try std.fmt.allocPrint(allocator, "{s}/centroids_i8.bin", .{data_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = centroids_path, .data = centroids_i8 });

    var cluster_offsets_bin = try allocator.alloc(u8, NUM_CLUSTERS * 8);
    for (0..NUM_CLUSTERS) |c| {
        const base = c * 8;
        writeU32Le(cluster_offsets_bin[base .. base + 4], cluster_offsets[c]);
        writeU32Le(cluster_offsets_bin[base + 4 .. base + 8], cluster_offsets[c + 1]);
    }

    const cluster_offsets_path = try std.fmt.allocPrint(allocator, "{s}/cluster_offsets.bin", .{data_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cluster_offsets_path, .data = cluster_offsets_bin });

    var scales_bin = try allocator.alloc(u8, DIMS * 4);
    var offsets_bin = try allocator.alloc(u8, DIMS * 4);
    for (0..DIMS) |d| {
        const sbits: u32 = @bitCast(@as(f32, 1.0));
        const obits: u32 = @bitCast(@as(f32, 0.0));
        writeU32Le(scales_bin[d * 4 .. d * 4 + 4], sbits);
        writeU32Le(offsets_bin[d * 4 .. d * 4 + 4], obits);
    }

    const scales_path = try std.fmt.allocPrint(allocator, "{s}/scales.bin", .{data_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = scales_path, .data = scales_bin });

    const offsets_path = try std.fmt.allocPrint(allocator, "{s}/offsets.bin", .{data_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = offsets_path, .data = offsets_bin });

    std.debug.print("index generated: n={d}, clusters={d}\n", .{ n, NUM_CLUSTERS });
}
