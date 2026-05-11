const std = @import("std");
const response = @import("../src/response.zig");

test "HTTP_404 format" {
    try std.testing.expect(std.mem.startsWith(u8, response.HTTP_404, "HTTP/1.1 404"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response.HTTP_404, 1, "Content-Length: 9"));
    try std.testing.expect(std.mem.endsWith(u8, response.HTTP_404, "Not Found"));
}

test "HTTP_405 format" {
    try std.testing.expect(std.mem.startsWith(u8, response.HTTP_405, "HTTP/1.1 405"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response.HTTP_405, 1, "Content-Length: 17"));
    try std.testing.expect(std.mem.endsWith(u8, response.HTTP_405, "Method Not Allowed"));
}

test "formatFraudResponse approved true" {
    var buf: [256]u8 = undefined;
    const result = response.formatFraudResponse(true, 0.6, "1", &buf);
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"approved\":true,\"fraud_score\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "0.600"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ",\"instance\":\"1\""));
    try std.testing.expect(std.mem.endsWith(u8, result, "}"));
}

test "formatFraudResponse approved false" {
    var buf: [256]u8 = undefined;
    const result = response.formatFraudResponse(false, 0.3, "1", &buf);
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"approved\":false,\"fraud_score\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "0.300"));
}

test "formatFraudResponse approved false high score" {
    var buf: [256]u8 = undefined;
    const result = response.formatFraudResponse(false, 0.9, "2", &buf);
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"approved\":false,\"fraud_score\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "0.900"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, ",\"instance\":\"2\""));
}

test "formatFraudResponse score at threshold 0.6" {
    var buf: [256]u8 = undefined;
    const result = response.formatFraudResponse(false, 0.6, "1", &buf);
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"approved\":false,\"fraud_score\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "0.600"));
}

test "formatFraudResponse returns correct length" {
    var buf: [256]u8 = undefined;
    const result = response.formatFraudResponse(true, 0.123, "1", &buf);
    const expected = "{\"approved\":true,\"fraud_score\":0.123,\"instance\":\"1\"}";
    try std.testing.expectEqual(result.len, expected.len);
}