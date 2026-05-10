const std = @import("std");
const http = @import("http.zig");
const router = @import("router.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

pub fn main() void {
    const instance_id = if (getenv("INSTANCE_ID")) |val|
        std.mem.span(val)
    else
        "1";

    router.initScorer("/app/data");

    http.createSocketDir() catch return;
    const sock_fd = http.createAndBindUdsSocket(instance_id) catch |err| {
        std.debug.print("failed to bind: {}\n", .{err});
        return;
    };
    defer _ = std.os.linux.close(sock_fd);

    std.debug.print("fraud-api-{s} listening on /tmp/rinha/api-{s}.sock\n", .{ instance_id, instance_id });

    const r = http.Router{ .handler = router.route, .instance_id = instance_id };

    while (true) {
        const client_fd = @as(c_int, @intCast(std.os.linux.accept(sock_fd, null, null)));
        if (client_fd < 0) continue;

        http.handleConnection(client_fd, r) catch {};
        _ = std.os.linux.close(client_fd);
    }
}