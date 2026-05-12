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

test "route returns 405 for GET on /fraud-score" {
    const resp = router.route("GET", "/fraud-score", "", "1");
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}

test "route returns 404 for empty path" {
    const resp = router.route("GET", "/", "", "1");
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404"));
}