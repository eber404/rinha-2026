const std = @import("std");
const router = @import("../src/router.zig");
const payload = @import("../src/payload.zig");

test "route POST /fraud-score" {
    const resp = router.route("POST", "/fraud-score", "", "1");
    try std.testing.expect(resp.len > 20);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
}

test "route GET /ready" {
    const resp = router.route("GET", "/ready", "", "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"ready\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"1\""));
}

test "route GET /ready has correct content-length" {
    const resp = router.route("GET", "/ready", "", "1");
    const header_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.TestUnexpectedResult;
    const body = resp[header_end + 4 ..];
    const key = "Content-Length: ";
    const key_pos = std.mem.indexOf(u8, resp, key) orelse return error.TestUnexpectedResult;
    const len_start = key_pos + key.len;
    const len_end = std.mem.indexOfPos(u8, resp, len_start, "\r\n") orelse return error.TestUnexpectedResult;
    const declared = try std.fmt.parseInt(usize, resp[len_start..len_end], 10);
    try std.testing.expectEqual(declared, body.len);
}

test "route GET /fraud-score returns 405" {
    const resp = router.route("GET", "/fraud-score", "", "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405 Method Not Allowed"));
}

test "route POST /ready returns 404" {
    const resp = router.route("POST", "/ready", "", "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found"));
}

test "route unknown path 404" {
    const resp = router.route("GET", "/unknown", "", "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found"));
}

test "route static 404 response format" {
    const resp = router.static_404;
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "Content-Length: 9"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "Not Found"));
}

test "route static 405 response format" {
    const resp = router.static_405;
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "Content-Length: 17"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "Method Not Allowed"));
}

test "route GET /ready with instance 1" {
    const resp = router.route("GET", "/ready", "", "1");
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"1\""));
}

test "route GET /ready with instance 2" {
    const resp = router.route("GET", "/ready", "", "2");
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"2\""));
}

test "route GET /ready with instance 3" {
    const resp = router.route("GET", "/ready", "", "3");
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"3\""));
}

test "route POST /fraud-score has correct content-type" {
    const resp = router.route("POST", "/fraud-score", "", "1");
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "Content-Type: application/json"));
}

test "route returns slice that remains valid" {
    const resp = router.route("GET", "/ready", "", "1");
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(resp[0] == 'H');
}

test "fraud-score uses parsed features" {
    const body = "{\"transaction\":{\"amount\":5000,\"installments\":12,\"requested_at\":\"2024-01-15T14:30:00Z\"},\"customer\":{\"avg_amount\":100,\"tx_count_24h\":1},\"merchant\":{\"mcc\":\"5411\",\"avg_amount\":300},\"terminal\":{\"km_from_home\":500,\"is_online\":false,\"card_present\":false,\"known_merchants\":0},\"last_transaction\":{\"minutes\":2,\"km_from_current\":200},\"requested_at\":\"2024-01-15T09:00:00Z\"}";
    const resp = router.route("POST", "/fraud-score", body, "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"approved\":"));
}

test "computeFraudScore high amount vs customer avg" {
    const f = payload.Features{
        .transaction_amount = 1000.0,
        .customer_avg_amount = 100.0,
        .transaction_installments = 1,
        .customer_tx_count_24h = 10,
        .terminal_km_from_home = 5.0,
        .terminal_is_online = true,
        .terminal_card_present = true,
        .merchant_mcc = 5411,
    };
    const score = router.computeFraudScore(f);
    try std.testing.expect(score > 0.0);
}

test "computeFraudScore low risk returns false" {
    const f = payload.Features{
        .transaction_amount = 50.0,
        .customer_avg_amount = 100.0,
        .transaction_installments = 1,
        .customer_tx_count_24h = 10,
        .terminal_km_from_home = 1.0,
        .terminal_is_online = true,
        .terminal_card_present = true,
        .merchant_mcc = 5411,
        .last_transaction_minutes = 60,
    };
    const score = router.computeFraudScore(f);
    try std.testing.expect(score < 0.3);
}

test "route high-risk sample returns approved false" {
    const body = "{\"id\":\"tx-3330991687\",\"transaction\":{\"amount\":9505.97,\"installments\":10,\"requested_at\":\"2026-03-14T05:15:12Z\"},\"customer\":{\"avg_amount\":81.28,\"tx_count_24h\":20,\"known_merchants\":[\"MERC-008\",\"MERC-007\",\"MERC-005\"]},\"merchant\":{\"id\":\"MERC-068\",\"mcc\":\"7802\",\"avg_amount\":54.86},\"terminal\":{\"is_online\":false,\"card_present\":true,\"km_from_home\":952.27},\"last_transaction\":null}";
    const rr = router.route("POST", "/fraud-score", body, "1");
    try std.testing.expect(std.mem.containsAtLeast(u8, rr, 1, "\"approved\":false"));
}
