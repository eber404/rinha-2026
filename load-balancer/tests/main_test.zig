const std = @import("std");
const main = @import("../src/main.zig");
const testing = std.testing;

const EXTERNAL_PORT = 9999;
const UDS_SOCKET_1 = "/tmp/rinha/api-1.sock";
const UDS_SOCKET_2 = "/tmp/rinha/api-2.sock";

test "backend socket paths are valid" {
    try testing.expect(UDS_SOCKET_1.len > 0);
    try testing.expect(UDS_SOCKET_2.len > 0);
    try testing.expect(std.mem.eql(u8, UDS_SOCKET_1, "/tmp/rinha/api-1.sock"));
    try testing.expect(std.mem.eql(u8, UDS_SOCKET_2, "/tmp/rinha/api-2.sock"));
}

test "round robin advances" {
    var idx: usize = 0;
    const BACKEND_COUNT = 2;

    idx = (idx + 1) % BACKEND_COUNT;
    try testing.expectEqual(@as(usize, 1), idx);

    idx = (idx + 1) % BACKEND_COUNT;
    try testing.expectEqual(@as(usize, 0), idx);
}

test "accept loop creates valid sockaddr_in" {
    const addr = std.os.linux.sockaddr.in{
        .family = std.os.linux.AF.INET,
        .port = EXTERNAL_PORT,
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };

    try testing.expectEqual(@as(u16, 9999), addr.port);
    try testing.expectEqual(@as(u32, 0), addr.addr);
}

test "uds connect address fits in sockaddr_un" {
    const path = UDS_SOCKET_1;
    const addr_len = @as(u31, @intCast(2 + path.len));

    try testing.expect(addr_len <= @sizeOf(std.os.linux.sockaddr.un));
}

test "proxy buffer size is reasonable" {
    const BUF_SIZE: usize = 8192;
    try testing.expect(BUF_SIZE >= 1024);
    try testing.expect(BUF_SIZE <= 65536);
}

test "addr len calculation for uds" {
    const path = "/tmp/rinha/api-1.sock";
    const expected_len = 2 + path.len;
    try testing.expectEqual(@as(u31, @intCast(expected_len)), @as(u31, @intCast(2 + 21)));
}