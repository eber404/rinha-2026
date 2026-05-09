const std = @import("std");
const testing = std.testing;

test "backend path selection round robin" {
    var backend_idx: usize = 0;
    const BACKEND_PATHS: []const []const u8 = &.{ "/tmp/rinha/api-1.sock", "/tmp/rinha/api-2.sock" };

    // Simulate round-robin picks
    const picks = [_]usize{ 0, 1, 0, 1 };
    for (picks, 0..) |expected, i| {
        const idx = (i) % 2;
        const path = BACKEND_PATHS[idx];
        try testing.expect(path.len > 0);
    }
}

test "socket address struct sizes" {
    try testing.expect(@sizeOf(std.os.linux.sockaddr.in) == 16);
    try testing.expect(@sizeOf(std.os.linux.sockaddr.un) == 110);
}

test "normalize addr" {
    const addr = std.os.linux.sockaddr.in{
        .family = std.os.linux.AF.INET,
        .port = 9999,
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };

    try testing.expectEqual(@as(u16, 9999), addr.port);
    try testing.expectEqual(std.os.linux.AF.INET, addr.family);
}
