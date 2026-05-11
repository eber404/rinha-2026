const std = @import("std");
const linux = std.os.linux;

const PAGE_SIZE: usize = 4096;

const VECTORS_SIZE = 48000000;
const LABELS_SIZE = 3000000;
const CENTROIDS_SIZE = 4096;
const CLUSTER_OFFSETS_SIZE = 2048;
const SCALES_SIZE = 56;
const OFFSETS_SIZE = 56;

const PROT_READ: u32 = @as(u32, 1);
const MAP_FILE: u32 = @as(u32, 0);
const MAP_SHARED: u32 = @as(u32, 1);

const O_RDONLY_V: u32 = @as(u32, 0);
const O_WRONLY_V: u32 = @as(u32, 1);
const O_CREAT_V: u32 = @as(u32, 64);
const O_TRUNC_V: u32 = @as(u32, 512);

const Record = struct {
    start: u32,
    end: u32,
};

pub const Dataset = struct {
    vectors_fd: i32 = -1,
    labels_fd: i32 = -1,
    centroids_fd: i32 = -1,
    offsets_fd: i32 = -1,
    scales_fd: i32 = -1,
    cluster_offsets_fd: i32 = -1,

    vectors_mmap: []align(PAGE_SIZE) const u8 = &.{},
    labels_mmap: []align(PAGE_SIZE) const u8 = &.{},
    centroids_mmap: []align(PAGE_SIZE) const u8 = &.{},
    cluster_offsets_mmap: []align(PAGE_SIZE) const u8 = &.{},
    scales_mmap: []align(PAGE_SIZE) const u8 = &.{},
    offsets_mmap: []align(PAGE_SIZE) const u8 = &.{},

    pub fn init() Dataset {
        return Dataset{};
    }

    inline fn toO(v: u32) linux.O {
        return @enumFromInt(v);
    }

    inline fn toOLinux(v: u32) linux.O {
        return @as(linux.O, @bitCast(v));
    }

    fn mmapFile(fd: i32, file_size: u64) ?[]align(PAGE_SIZE) const u8 {
        if (fd < 0) return null;
        const prot: linux.PROT = @as(linux.PROT, @bitCast(PROT_READ));
        const flags: linux.MAP = @as(linux.MAP, @bitCast(MAP_FILE | MAP_SHARED));
        const addr = linux.mmap(null, file_size, prot, flags, fd, 0);
        if (@as(isize, @intCast(addr)) < 0) return null;
        return @as([*]align(PAGE_SIZE) const u8, @ptrFromInt(addr))[0..file_size];
    }

    pub fn load(d: *Dataset, data_dir: []const u8) error{OpenFailed}!void {
        var vectors_path: [256:0]u8 = undefined;
        const vectors_path_s = std.fmt.bufPrint(&vectors_path, "{s}/vectors_i8.bin", .{data_dir}) catch return error.OpenFailed;
        _ = vectors_path_s;
        var labels_path: [256:0]u8 = undefined;
        const labels_path_s = std.fmt.bufPrint(&labels_path, "{s}/labels.bin", .{data_dir}) catch return error.OpenFailed;
        _ = labels_path_s;
        var centroids_path: [256:0]u8 = undefined;
        const centroids_path_s = std.fmt.bufPrint(&centroids_path, "{s}/centroids_i8.bin", .{data_dir}) catch return error.OpenFailed;
        _ = centroids_path_s;
        var cluster_offsets_path: [256:0]u8 = undefined;
        const cluster_offsets_path_s = std.fmt.bufPrint(&cluster_offsets_path, "{s}/cluster_offsets.bin", .{data_dir}) catch return error.OpenFailed;
        _ = cluster_offsets_path_s;
        var scales_path: [256:0]u8 = undefined;
        const scales_path_s = std.fmt.bufPrint(&scales_path, "{s}/scales.bin", .{data_dir}) catch return error.OpenFailed;
        _ = scales_path_s;
        var offsets_path: [256:0]u8 = undefined;
        const offsets_path_s = std.fmt.bufPrint(&offsets_path, "{s}/offsets.bin", .{data_dir}) catch return error.OpenFailed;
        _ = offsets_path_s;

        d.vectors_fd = @as(i32, @intCast(linux.open(&vectors_path, @as(linux.O, @bitCast(O_RDONLY_V)), 0)));
        if (d.vectors_fd < 0) return error.OpenFailed;
        d.labels_fd = @as(i32, @intCast(linux.open(&labels_path, @as(linux.O, @bitCast(O_RDONLY_V)), 0)));
        if (d.labels_fd < 0) return error.OpenFailed;
        d.centroids_fd = @as(i32, @intCast(linux.open(&centroids_path, @as(linux.O, @bitCast(O_RDONLY_V)), 0)));
        if (d.centroids_fd < 0) return error.OpenFailed;
        d.cluster_offsets_fd = @as(i32, @intCast(linux.open(&cluster_offsets_path, @as(linux.O, @bitCast(O_RDONLY_V)), 0)));
        if (d.cluster_offsets_fd < 0) return error.OpenFailed;
        d.scales_fd = @as(i32, @intCast(linux.open(&scales_path, @as(linux.O, @bitCast(O_RDONLY_V)), 0)));
        if (d.scales_fd < 0) return error.OpenFailed;
        d.offsets_fd = @as(i32, @intCast(linux.open(&offsets_path, @as(linux.O, @bitCast(O_RDONLY_V)), 0)));
        if (d.offsets_fd < 0) return error.OpenFailed;

        errdefer _ = linux.close(d.vectors_fd);
        errdefer _ = linux.close(d.labels_fd);
        errdefer _ = linux.close(d.centroids_fd);
        errdefer _ = linux.close(d.cluster_offsets_fd);
        errdefer _ = linux.close(d.scales_fd);
        errdefer _ = linux.close(d.offsets_fd);

        d.vectors_mmap = mmapFile(d.vectors_fd, VECTORS_SIZE) orelse return error.OpenFailed;
        d.labels_mmap = mmapFile(d.labels_fd, LABELS_SIZE) orelse return error.OpenFailed;
        d.centroids_mmap = mmapFile(d.centroids_fd, CENTROIDS_SIZE) orelse return error.OpenFailed;
        d.cluster_offsets_mmap = mmapFile(d.cluster_offsets_fd, CLUSTER_OFFSETS_SIZE) orelse return error.OpenFailed;
        d.scales_mmap = mmapFile(d.scales_fd, SCALES_SIZE) orelse return error.OpenFailed;
        d.offsets_mmap = mmapFile(d.offsets_fd, OFFSETS_SIZE) orelse return error.OpenFailed;
    }

    pub fn deinit(d: *Dataset) void {
        if (d.vectors_mmap.len > 0) _ = linux.munmap(@ptrFromInt(@intFromPtr(d.vectors_mmap.ptr)), d.vectors_mmap.len);
        if (d.labels_mmap.len > 0) _ = linux.munmap(@ptrFromInt(@intFromPtr(d.labels_mmap.ptr)), d.labels_mmap.len);
        if (d.centroids_mmap.len > 0) _ = linux.munmap(@ptrFromInt(@intFromPtr(d.centroids_mmap.ptr)), d.centroids_mmap.len);
        if (d.cluster_offsets_mmap.len > 0) _ = linux.munmap(@ptrFromInt(@intFromPtr(d.cluster_offsets_mmap.ptr)), d.cluster_offsets_mmap.len);
        if (d.scales_mmap.len > 0) _ = linux.munmap(@ptrFromInt(@intFromPtr(d.scales_mmap.ptr)), d.scales_mmap.len);
        if (d.offsets_mmap.len > 0) _ = linux.munmap(@ptrFromInt(@intFromPtr(d.offsets_mmap.ptr)), d.offsets_mmap.len);

        if (d.vectors_fd >= 0) _ = linux.close(d.vectors_fd);
        if (d.labels_fd >= 0) _ = linux.close(d.labels_fd);
        if (d.centroids_fd >= 0) _ = linux.close(d.centroids_fd);
        if (d.cluster_offsets_fd >= 0) _ = linux.close(d.cluster_offsets_fd);
        if (d.scales_fd >= 0) _ = linux.close(d.scales_fd);
        if (d.offsets_fd >= 0) _ = linux.close(d.offsets_fd);

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
        const start = @as(u32, d.cluster_offsets_mmap[offset]) |
            @as(u32, d.cluster_offsets_mmap[offset + 1]) << 8 |
            @as(u32, d.cluster_offsets_mmap[offset + 2]) << 16 |
            @as(u32, d.cluster_offsets_mmap[offset + 3]) << 24;
        const end = @as(u32, d.cluster_offsets_mmap[offset + 4]) |
            @as(u32, d.cluster_offsets_mmap[offset + 5]) << 8 |
            @as(u32, d.cluster_offsets_mmap[offset + 6]) << 16 |
            @as(u32, d.cluster_offsets_mmap[offset + 7]) << 24;
        return .{ .start = start, .end = end };
    }

    pub fn scales(d: *const Dataset) [14]f32 {
        var result: [14]f32 = undefined;
        @memset(&result, 0);
        if (d.scales_mmap.len < 56) return result;
        for (0..14) |i| {
            const off = i * 4;
            const bits = @as(u32, d.scales_mmap[off]) |
                @as(u32, d.scales_mmap[off + 1]) << 8 |
                @as(u32, d.scales_mmap[off + 2]) << 16 |
                @as(u32, d.scales_mmap[off + 3]) << 24;
            result[i] = @bitCast(bits);
        }
        return result;
    }

    pub fn offsets(d: *const Dataset) [14]f32 {
        var result: [14]f32 = undefined;
        @memset(&result, 0);
        if (d.offsets_mmap.len < 56) return result;
        for (0..14) |i| {
            const off = i * 4;
            const bits = @as(u32, d.offsets_mmap[off]) |
                @as(u32, d.offsets_mmap[off + 1]) << 8 |
                @as(u32, d.offsets_mmap[off + 2]) << 16 |
                @as(u32, d.offsets_mmap[off + 3]) << 24;
            result[i] = @bitCast(bits);
        }
        return result;
    }
};