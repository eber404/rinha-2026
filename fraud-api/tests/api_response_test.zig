const std = @import("std");
const router = @import("router.zig");

test "fraud-score response has correct HTTP prefix" {
    const body = "{\"transaction\":{\"amount\":100,\"installments\":1},\"customer\":{\"avg_amount\":50,\"tx_count_24h\":5},\"merchant\":{\"mcc\":\"5411\"},\"terminal\":{\"km_from_home\":1,\"is_online\":true,\"card_present\":true}}";
    const resp = router.route("POST", "/fraud-score", body, "1");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(resp.len > 50);
}

test "fraud-score response Content-Length matches actual body" {
    const body = "{\"transaction\":{\"amount\":100,\"installments\":1},\"customer\":{\"avg_amount\":50,\"tx_count_24h\":5},\"merchant\":{\"mcc\":\"5411\"},\"terminal\":{\"km_from_home\":1,\"is_online\":true,\"card_present\":true}}";
    const resp = router.route("POST", "/fraud-score", body, "1");

    const cl_start = std.mem.indexOf(u8, resp, "Content-Length: ") orelse return error.NoContentLength;
    const cl_value_start = cl_start + 16;
    const cl_value_end = cl_value_start + (std.mem.indexOf(u8, resp[cl_value_start..], "\r\n") orelse return error.NoContentLengthEnd);
    const cl_str = resp[cl_value_start..cl_value_end];
    const content_length = std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidContentLength;

    const body_start = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoBodySeparator;
    const actual_body = resp[body_start + 4 ..];
    try std.testing.expectEqual(@as(usize, actual_body.len), content_length);
}

test "fraud-score response body is valid JSON with required fields" {
    const body = "{\"transaction\":{\"amount\":500,\"installments\":3},\"customer\":{\"avg_amount\":100,\"tx_count_24h\":10},\"merchant\":{\"mcc\":\"5411\"},\"terminal\":{\"km_from_home\":5,\"is_online\":true,\"card_present\":true}}";
    const resp = router.route("POST", "/fraud-score", body, "1");

    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"approved\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"fraud_score\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\""));
}

test "ready response with instance 10 works" {
    const resp = router.route("GET", "/ready", "", "10");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"10\""));
}

test "ready response with instance longer than 1 char" {
    const resp = router.route("GET", "/ready", "", "100");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"100\""));
}

test "response does not start with corrupted bytes" {
    const resp = router.route("GET", "/ready", "", "1");
    try std.testing.expect(resp.len >= 9);
    try std.testing.expectEqual(@as(u8, 'H'), resp[0]);
    try std.testing.expectEqual(@as(u8, 'T'), resp[1]);
    try std.testing.expectEqual(@as(u8, 'T'), resp[2]);
    try std.testing.expectEqual(@as(u8, 'P'), resp[3]);
    try std.testing.expectEqual(@as(u8, '/'), resp[4]);
    try std.testing.expectEqual(@as(u8, '1'), resp[5]);
    try std.testing.expectEqual(@as(u8, '.'), resp[6]);
    try std.testing.expectEqual(@as(u8, '1'), resp[7]);
    try std.testing.expectEqual(@as(u8, ' '), resp[8]);
}

test "fraud-score response does not start with corrupted bytes" {
    const body = "{\"transaction\":{\"amount\":100},\"customer\":{\"avg_amount\":50},\"merchant\":{\"mcc\":\"5411\"},\"terminal\":{\"km_from_home\":1,\"is_online\":true,\"card_present\":true}}";
    const resp = router.route("POST", "/fraud-score", body, "1");
    try std.testing.expect(resp.len >= 9);
    try std.testing.expectEqual(@as(u8, 'H'), resp[0]);
    try std.testing.expectEqual(@as(u8, 'T'), resp[1]);
    try std.testing.expectEqual(@as(u8, 'T'), resp[2]);
    try std.testing.expectEqual(@as(u8, 'P'), resp[3]);
    try std.testing.expectEqual(@as(u8, '/'), resp[4]);
    try std.testing.expectEqual(@as(u8, '1'), resp[5]);
    try std.testing.expectEqual(@as(u8, '.'), resp[6]);
    try std.testing.expectEqual(@as(u8, '1'), resp[7]);
    try std.testing.expectEqual(@as(u8, ' '), resp[8]);
}

test "fraud-score with high fraud score instance" {
    const body = "{\"transaction\":{\"amount\":5000,\"installments\":12},\"customer\":{\"avg_amount\":100,\"tx_count_24h\":1},\"merchant\":{\"mcc\":\"5411\"},\"terminal\":{\"km_from_home\":500,\"is_online\":false,\"card_present\":false},\"last_transaction\":{\"minutes\":2}}";
    const resp = router.route("POST", "/fraud-score", body, "2");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.containsAtLeast(u8, resp, 1, "\"instance\":\"2\""));
}
