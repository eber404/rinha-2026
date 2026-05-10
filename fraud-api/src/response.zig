const std = @import("std");

const HTTP_404 = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
const HTTP_405 = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 17\r\n\r\nMethod Not Allowed";

const JSON_TRUE_PREFIX = "{\"approved\":true,\"fraud_score\":";
const JSON_FALSE_PREFIX = "{\"approved\":false,\"fraud_score\":";
const JSON_SUFFIX = ",\"instance\":\"";
const JSON_END = "\"}";

pub fn formatFraudResponse(approved: bool, fraud_score: f32, instance: []const u8, buf: []u8) []u8 {
    const prefix = if (approved) JSON_TRUE_PREFIX else JSON_FALSE_PREFIX;
    const prefix_len = prefix.len;

    @memcpy(buf[0..prefix_len], prefix);

    const score_slice = std.fmt.bufPrint(buf[prefix_len..], "{d:.3}", .{fraud_score}) catch unreachable;
    const score_len = score_slice.len;

    const suffix_len = JSON_SUFFIX.len;
    @memcpy(buf[prefix_len + score_len .. prefix_len + score_len + suffix_len], JSON_SUFFIX);

    const instance_len = instance.len;
    @memcpy(buf[prefix_len + score_len + suffix_len .. prefix_len + score_len + suffix_len + instance_len], instance);

    const end_len = JSON_END.len;
    @memcpy(buf[prefix_len + score_len + suffix_len + instance_len .. prefix_len + score_len + suffix_len + instance_len + end_len], JSON_END);

    return buf[0 .. prefix_len + score_len + suffix_len + instance_len + end_len];
}

test "HTTP_404 format" {
    try std.testing.expect(std.mem.startsWith(u8, HTTP_404, "HTTP/1.1 404"));
    try std.testing.expect(std.mem.containsAtLeast(u8, HTTP_404, 1, "Content-Length: 9"));
    try std.testing.expect(std.mem.endsWith(u8, HTTP_404, "Not Found"));
}

test "HTTP_405 format" {
    try std.testing.expect(std.mem.startsWith(u8, HTTP_405, "HTTP/1.1 405"));
    try std.testing.expect(std.mem.containsAtLeast(u8, HTTP_405, 1, "Content-Length: 17"));
    try std.testing.expect(std.mem.endsWith(u8, HTTP_405, "Method Not Allowed"));
}

test "formatFraudResponse approved true" {
    var buf: [256]u8 = undefined;
    const result = formatFraudResponse(true, 0.6, "1", &buf);
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"approved\":true,\"fraud_score\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "0.600"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ",\"instance\":\"1\""));
    try std.testing.expect(std.mem.endsWith(u8, result, "}"));
}

test "formatFraudResponse approved false" {
    var buf: [256]u8 = undefined;
    const result = formatFraudResponse(false, 0.3, "1", &buf);
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"approved\":false,\"fraud_score\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "0.300"));
}

test "formatFraudResponse approved false high score" {
    var buf: [256]u8 = undefined;
    const result = formatFraudResponse(false, 0.9, "2", &buf);
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"approved\":false,\"fraud_score\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "0.900"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ",\"instance\":\"2\""));
}

test "formatFraudResponse score at threshold 0.6" {
    var buf: [256]u8 = undefined;
    const result = formatFraudResponse(false, 0.6, "1", &buf);
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"approved\":false,\"fraud_score\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "0.600"));
}

test "formatFraudResponse returns correct length" {
    var buf: [256]u8 = undefined;
    const result = formatFraudResponse(true, 0.123, "1", &buf);
    const expected = "{\"approved\":true,\"fraud_score\":0.123,\"instance\":\"1\"}";
    try std.testing.expectEqual(result.len, expected.len);
}
