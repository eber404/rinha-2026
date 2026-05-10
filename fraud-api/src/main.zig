const std = @import("std");
const http = @import("http.zig");
const router = @import("router.zig");

pub fn main() void {
    var instance_id: []const u8 = "1";
    const env_value = std.process.getEnvVarOwned(std.heap.page_allocator, "INSTANCE_ID") catch null;
    if (env_value) |value| {
        instance_id = value;
    }

    if (!std.mem.eql(u8, instance_id, "1") and !std.mem.eql(u8, instance_id, "2")) {
        std.debug.print("invalid INSTANCE_ID '{s}', fallback to 1\n", .{instance_id});
        instance_id = "1";
    }

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
        defer _ = std.os.linux.close(client_fd);

        http.handleConnection(client_fd, r) catch {};
    }
}
