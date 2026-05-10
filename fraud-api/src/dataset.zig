const std = @import("std");

const Record = struct {
    start: u32,
    end: u32,
};

pub const Dataset = struct {
    vectors_fd: std.posix.fd_t = -1,
    labels_fd: std.posix.fd_t = -1,
    centroids_fd: std.posix.fd_t = -1,
    offsets_fd: std.posix.fd_t = -1,
    scales_fd: std.posix.fd_t = -1,
    cluster_offsets_fd: std.posix.fd_t = -1,

    vectors_mmap: []align(std.mem.page_size) const u8 = &.{},
    labels_mmap: []align(std.mem.page_size) const u8 = &.{},
    centroids_mmap: []align(std.mem.page_size) const u8 = &.{},
    cluster_offsets_mmap: []align(std.mem.page_size) const u8 = &.{},
    scales_mmap: []align(std.mem.page_size) const u8 = &.{},
    offsets_mmap: []align(std.mem.page_size) const u8 = &.{},

    pub fn init() Dataset {
        return Dataset{};
    }

    fn mmapFile(fd: std.posix.fd_t, file_size: u64) ?[]align(std.mem.page_size) const u8 {
        if (fd < 0) return null;
        const mmap_result = std.posix.mmap(null, file_size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0);
        return mmap_result catch null;
    }

    pub fn load(d: *Dataset, data_dir: []const u8) error{OpenFailed}!void {
        d.vectors_fd = std.posix.open(try std.fs.path.join(std.heap.page_allocator, data_dir, "/vectors_i8.bin"), .{ .ACCMODE = .RDONLY }) catch return error.OpenFailed;
        d.labels_fd = std.posix.open(try std.fs.path.join(std.heap.page_allocator, data_dir, "/labels.bin"), .{ .ACCMODE = .RDONLY }) catch return error.OpenFailed;
        d.centroids_fd = std.posix.open(try std.fs.path.join(std.heap.page_allocator, data_dir, "/centroids_i8.bin"), .{ .ACCMODE = .RDONLY }) catch return error.OpenFailed;
        d.cluster_offsets_fd = std.posix.open(try std.fs.path.join(std.heap.page_allocator, data_dir, "/cluster_offsets.bin"), .{ .ACCMODE = .RDONLY }) catch return error.OpenFailed;
        d.scales_fd = std.posix.open(try std.fs.path.join(std.heap.page_allocator, data_dir, "/scales.bin"), .{ .ACCMODE = .RDONLY }) catch return error.OpenFailed;
        d.offsets_fd = std.posix.open(try std.fs.path.join(std.heap.page_allocator, data_dir, "/offsets.bin"), .{ .ACCMODE = .RDONLY }) catch return error.OpenFailed;

        errdefer _ = std.posix.close(d.vectors_fd);
        errdefer _ = std.posix.close(d.labels_fd);
        errdefer _ = std.posix.close(d.centroids_fd);
        errdefer _ = std.posix.close(d.cluster_offsets_fd);
        errdefer _ = std.posix.close(d.scales_fd);
        errdefer _ = std.posix.close(d.offsets_fd);

        const vectors_stat = std.posix.fstat(d.vectors_fd) catch return error.OpenFailed;
        const labels_stat = std.posix.fstat(d.labels_fd) catch return error.OpenFailed;
        const centroids_stat = std.posix.fstat(d.centroids_fd) catch return error.OpenFailed;
        const cluster_offsets_stat = std.posix.fstat(d.cluster_offsets_fd) catch return error.OpenFailed;
        const scales_stat = std.posix.fstat(d.scales_fd) catch return error.OpenFailed;
        const offsets_stat = std.posix.fstat(d.offsets_fd) catch return error.OpenFailed;

        d.vectors_mmap = mmapFile(d.vectors_fd, vectors_stat.size) orelse return error.OpenFailed;
        d.labels_mmap = mmapFile(d.labels_fd, labels_stat.size) orelse return error.OpenFailed;
        d.centroids_mmap = mmapFile(d.centroids_fd, centroids_stat.size) orelse return error.OpenFailed;
        d.cluster_offsets_mmap = mmapFile(d.cluster_offsets_fd, cluster_offsets_stat.size) orelse return error.OpenFailed;
        d.scales_mmap = mmapFile(d.scales_fd, scales_stat.size) orelse return error.OpenFailed;
        d.offsets_mmap = mmapFile(d.offsets_fd, offsets_stat.size) orelse return error.OpenFailed;
    }

    pub fn deinit(d: *Dataset) void {
        if (d.vectors_mmap.len > 0) std.posix.munmap(d.vectors_mmap);
        if (d.labels_mmap.len > 0) std.posix.munmap(d.labels_mmap);
        if (d.centroids_mmap.len > 0) std.posix.munmap(d.centroids_mmap);
        if (d.cluster_offsets_mmap.len > 0) std.posix.munmap(d.cluster_offsets_mmap);
        if (d.scales_mmap.len > 0) std.posix.munmap(d.scales_mmap);
        if (d.offsets_mmap.len > 0) std.posix.munmap(d.offsets_mmap);

        if (d.vectors_fd >= 0) _ = std.posix.close(d.vectors_fd);
        if (d.labels_fd >= 0) _ = std.posix.close(d.labels_fd);
        if (d.centroids_fd >= 0) _ = std.posix.close(d.centroids_fd);
        if (d.cluster_offsets_fd >= 0) _ = std.posix.close(d.cluster_offsets_fd);
        if (d.scales_fd >= 0) _ = std.posix.close(d.scales_fd);
        if (d.offsets_fd >= 0) _ = std.posix.close(d.offsets_fd);

        d.* = Dataset{};
    }

    pub fn vectorAt(d: *const Dataset, idx: u32, dim: u8) i8 {
        if (d.vectors_mmap.len == 0) return 0;
        const offset = @as(u64, idx) * 16 + @as(u64, dim);
        if (offset >= d.vectors_mmap.len) return 0;
        return @as(i8, @bitCast(d.vectors_mmap[offset]));
    }

    pub fn labelAt(d: *const Dataset, idx: u32) u8 {
        if (d.labels_mmap.len == 0) return 0;
        const offset = @as(u64, idx);
        if (offset >= d.labels_mmap.len) return 0;
        return d.labels_mmap[offset];
    }

    pub fn centroidAt(d: *const Dataset, cluster: u32) [16]i8 {
        var result: [16]i8 = undefined;
        @memset(&result, 0);
        if (d.centroids_mmap.len == 0) return result;
        const offset = @as(u64, cluster) * 16;
        if (offset + 16 > d.centroids_mmap.len) return result;
        for (0..16) |i| {
            result[i] = @as(i8, @bitCast(d.centroids_mmap[offset + i]));
        }
        return result;
    }

    pub fn clusterRange(d: *const Dataset, cluster: u32) Record {
        if (d.cluster_offsets_mmap.len == 0) return .{ .start = 0, .end = 0 };
        const offset = @as(u64, cluster) * 8;
        if (offset + 8 > d.cluster_offsets_mmap.len) return .{ .start = 0, .end = 0 };
        const start = std.mem.readIntLittle(u32, d.cluster_offsets_mmap[offset..offset + 4]);
        const end = std.mem.readIntLittle(u32, d.cluster_offsets_mmap[offset + 4..offset + 8]);
        return .{ .start = start, .end = end };
    }

    pub fn scales(d: *const Dataset) [14]f32 {
        var result: [14]f32 = undefined;
        @memset(&result, 0);
        if (d.scales_mmap.len < 56) return result;
        for (0..14) |i| {
            result[i] = std.mem.readIntLittle(f32, d.scales_mmap[i * 4 ..][0..4]);
        }
        return result;
    }

    pub fn offsets(d: *const Dataset) [14]f32 {
        var result: [14]f32 = undefined;
        @memset(&result, 0);
        if (d.offsets_mmap.len < 56) return result;
        for (0..14) |i| {
            result[i] = std.mem.readIntLittle(f32, d.offsets_mmap[i * 4 ..][0..4]);
        }
        return result;
    }
};

fn writeTestFiles(dir: []const u8) !void {
    const vec = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const labels = [_]u8{ 1, 0, 1 };
    const centroids = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const scales = [_]f32{ 0.01, 0.1, 0.05, 0.01, 0.05, 0.01, 0.1, 1.0, 1.0, 0.05, 0.1, 0.01, 0.05, 0.01 };
    const offsets = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    const vectors_file = try std.posix.open(try std.fs.path.join(std.heap.page_allocator, dir, "/vectors_i8.bin"), .{ .ACCMODE = .WRONLY, .CREAT = .EXCL }, 0o644);
    defer _ = std.posix.close(vectors_file);
    try std.posix.write(vectors_file, &vec);

    const labels_file = try std.posix.open(try std.fs.path.join(std.heap.page_allocator, dir, "/labels.bin"), .{ .ACCMODE = .WRONLY, .CREAT = .EXCL }, 0o644);
    defer _ = std.posix.close(labels_file);
    try std.posix.write(labels_file, &labels);

    const centroids_file = try std.posix.open(try std.fs.path.join(std.heap.page_allocator, dir, "/centroids_i8.bin"), .{ .ACCMODE = .WRONLY, .CREAT = .EXCL }, 0o644);
    defer _ = std.posix.close(centroids_file);
    try std.posix.write(centroids_file, &centroids);

    const cluster_offsets_file = try std.posix.open(try std.fs.path.join(std.heap.page_allocator, dir, "/cluster_offsets.bin"), .{ .ACCMODE = .WRONLY, .CREAT = .EXCL }, 0o644);
    defer _ = std.posix.close(cluster_offsets_file);
    var cluster_record = [_]u8{ 0, 0, 0, 0, 3, 0, 0, 0 };
    try std.posix.write(cluster_offsets_file, &cluster_record);

    const scales_file = try std.posix.open(try std.fs.path.join(std.heap.page_allocator, dir, "/scales.bin"), .{ .ACCMODE = .WRONLY, .CREAT = .EXCL }, 0o644);
    defer _ = std.posix.close(scales_file);
    for (scales) |s| {
        var buf: [4]u8 = undefined;
        std.mem.writeIntLittle(f32, &buf, s);
        try std.posix.write(scales_file, &buf);
    }

    const offsets_file = try std.posix.open(try std.fs.path.join(std.heap.page_allocator, dir, "/offsets.bin"), .{ .ACCMODE = .WRONLY, .CREAT = .EXCL }, 0o644);
    defer _ = std.posix.close(offsets_file);
    for (offsets) |o| {
        var buf: [4]u8 = undefined;
        std.mem.writeIntLittle(f32, &buf, o);
        try std.posix.write(offsets_file, &buf);
    }
}

test "dataset init and deinit" {
    var d = Dataset.init();
    defer d.deinit();
    try std.testing.expect(d.vectors_fd == -1);
}

test "dataset empty access returns zero" {
    var d = Dataset.init();
    defer d.deinit();
    try std.testing.expectEqual(@as(i8, 0), d.vectorAt(0, 0));
    try std.testing.expectEqual(@as(u8, 0), d.labelAt(0));
    try std.testing.expectEqual(@as(u32, 0), d.clusterRange(0).start);
    try std.testing.expectEqual(@as(u32, 0), d.clusterRange(0).end);
}

test "dataset with real test files" {
    const tmp_dir = "/tmp/zig_dataset_test";
    try std.fs.cwd().makeDir(tmp_dir);
    defer _ = std.fs.cwd().deleteTree(tmp_dir);

    try writeTestFiles(tmp_dir);

    var d = Dataset.init();
    defer d.deinit();

    try d.load(tmp_dir);

    try std.testing.expectEqual(@as(i8, 1), d.vectorAt(0, 0));
    try std.testing.expectEqual(@as(i8, 16), d.vectorAt(0, 15));
    try std.testing.expectEqual(@as(u8, 1), d.labelAt(0));
    try std.testing.expectEqual(@as(u8, 0), d.labelAt(1));
    try std.testing.expectEqual(@as(u8, 1), d.labelAt(2));

    const range = d.clusterRange(0);
    try std.testing.expectEqual(@as(u32, 0), range.start);
    try std.testing.expectEqual(@as(u32, 3), range.end);

    const s = d.scales();
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), s[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), s[1], 0.001);

    const o = d.offsets();
    try std.testing.expectEqual(@as(f32, 0), o[0]);
}
