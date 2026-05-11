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
