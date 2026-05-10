const std = @import("std");
const http = @import("http.zig");

fn helloHandler(method: []const u8, path: []const u8, body: []const u8) http.Response {
    _ = method;
    _ = body;
    if (std.mem.eql(u8, path, "/health")) {
        return http.Response{
            .status = "200 OK",
            .content_type = "text/plain",
            .body = "OK",
        };
    }
    return http.Response{
        .status = "404 Not Found",
        .content_type = "text/plain",
        .body = "Not Found",
    };
}

pub fn main() !void {
    const instance_id = "1";
    try http.createSocketDir();

    const sock_fd = try http.createAndBindUdsSocket(instance_id);
    defer _ = std.os.linux.close(sock_fd);

    std.debug.print("fraud-api-{s} listening on /tmp/rinha/api-{s}.sock\n", .{ instance_id, instance_id });

    const router = http.Router{ .handler = helloHandler };

    while (true) {
        const client_fd = @as(c_int, @intCast(std.os.linux.accept(sock_fd, null, null)));
        if (client_fd < 0) continue;
        defer _ = std.os.linux.close(client_fd);

        http.handleConnection(client_fd, router) catch |err| {
            std.debug.print("connection error: {}\n", .{err});
        };
    }
}