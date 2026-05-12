const std = @import("std");
const router = @import("router");
const testing = std.testing;

test "initScorer does not panic" {
    router.initScorer("/app/vector-index");
    try testing.expect(true);
}

test "route returns 404 for unknown path" {
    const resp = router.route("GET", "/unknown", "", "1");
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404"));
}

test "route returns 405 for POST on /ready" {
    const resp = router.route("POST", "/ready", "", "1");
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}

test "route returns 200 for GET /ready" {
    const resp = router.route("GET", "/ready", "", "1");
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
}

test "ready content-length matches body" {
    const resp = router.route("GET", "/ready", "", "1");
    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.TestUnexpectedResult;
    const body = resp[header_end + 4 ..];
    const key = "Content-Length: ";
    const key_pos = std.mem.indexOf(u8, resp, key) orelse return error.TestUnexpectedResult;
    const len_start = key_pos + key.len;
    const len_end = std.mem.indexOfPos(u8, resp, len_start, "\r\n") orelse return error.TestUnexpectedResult;
    const declared = try std.fmt.parseInt(usize, resp[len_start..len_end], 10);
    try testing.expectEqual(declared, body.len);
}

test "route returns 405 for GET on /fraud-score" {
    const resp = router.route("GET", "/fraud-score", "", "1");
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}

test "route returns 404 for empty path" {
    const resp = router.route("GET", "/", "", "1");
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404"));
}
