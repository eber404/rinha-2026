const std = @import("std");

const static_404 = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nNot Found";
const static_405 = "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain\r\nContent-Length: 17\r\n\r\nMethod Not Allowed";

var ready_response_buf: [256]u8 = undefined;
var fraud_response_buf: [256]u8 = undefined;

pub fn route(method: []const u8, path: []const u8, body: []const u8, instance_id: []const u8) []const u8 {
    if (path.len == 12 and std.mem.eql(u8, path, "/fraud-score")) {
        if (method.len == 4 and std.mem.eql(u8, method, "POST")) {
            return handleFraudScore(body, instance_id);
        }
        return static_405;
    }
    if (path.len == 6 and std.mem.eql(u8, path, "/ready")) {
        if (method.len == 3 and std.mem.eql(u8, method, "GET")) {
            return buildReadyResponse(instance_id);
        }
        return static_404;
    }
    return static_404;
}

fn buildReadyResponse(instance: []const u8) []const u8 {
    const full = std.fmt.bufPrint(&ready_response_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{{\"ready\":true,\"instance\":\"{s}\"}}", .{instance}) catch unreachable;
    return full;
}

fn handleFraudScore(body: []const u8, instance_id: []const u8) []const u8 {
    _ = body;
    _ = instance_id;
    const response_body = "{\"score\":0.0,\"fraud\":false}";
    const full = std.fmt.bufPrint(&fraud_response_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ response_body.len, response_body }) catch unreachable;
    return full;
}

test "route POST /fraud-score" {
    const resp = route("POST", "/fraud-score", "", "1");
    try std.testing.expect(resp.len > 20);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
}

test "route GET /ready" {
    const resp = route("GET", "/ready", "", "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"ready\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"1\""));
}

test "route GET /fraud-score returns 405" {
    const resp = route("GET", "/fraud-score", "", "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405 Method Not Allowed"));
}

test "route POST /ready returns 404" {
    const resp = route("POST", "/ready", "", "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found"));
}

test "route unknown path 404" {
    const resp = route("GET", "/unknown", "", "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found"));
}

test "route static 404 response format" {
    const resp = static_404;
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "Content-Length: 9"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "Not Found"));
}

test "route static 405 response format" {
    const resp = static_405;
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "Content-Length: 17"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "Method Not Allowed"));
}

test "route GET /ready with instance 1" {
    const resp = route("GET", "/ready", "", "1");
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"1\""));
}

test "route GET /ready with instance 2" {
    const resp = route("GET", "/ready", "", "2");
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"2\""));
}

test "route GET /ready with instance 3" {
    const resp = route("GET", "/ready", "", "3");
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"3\""));
}

test "route POST /fraud-score has correct content-type" {
    const resp = route("POST", "/fraud-score", "", "1");
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "Content-Type: application/json"));
}

test "route returns slice that remains valid" {
    const resp = route("GET", "/ready", "", "1");
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(resp[0] == 'H');
}