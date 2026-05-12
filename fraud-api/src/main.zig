const std = @import("std");
const http = @import("http.zig");
const router = @import("router.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

fn handleClient(client_fd: c_int, instance_id: []const u8) void {
    defer _ = std.os.linux.close(client_fd);
    const r = http.Router{ .handler = router.route, .instance_id = instance_id };
    http.handleConnection(client_fd, r) catch {};
}

pub fn main() void {
    const instance_id = if (getenv("INSTANCE_ID")) |val|
        std.mem.span(val)
    else
        "1";

    router.initScorer("/app/vector-index");

    http.createSocketDir() catch return;
    const sock_fd = http.createAndBindUdsSocket(instance_id) catch |err| {
        std.debug.print("failed to bind: {}\n", .{err});
        return;
    };
    defer _ = std.os.linux.close(sock_fd);

    std.debug.print("fraud-api-{s} listening on /tmp/rinha/api-{s}.sock\n", .{ instance_id, instance_id });

    while (true) {
        const client_fd = @as(c_int, @intCast(std.os.linux.accept(sock_fd, null, null)));
        if (client_fd < 0) {
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 100_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
            continue;
        }

        handleClient(client_fd, instance_id);
    }
}
