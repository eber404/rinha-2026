const std = @import("std");
const http = @import("../src/http.zig");

test "parse headers finds end" {
    const buf = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const end = http.parseHeaders(buf);
    try std.testing.expect(end != null);
}

test "parse request line" {
    const buf = "POST /test HTTP/1.1\r\n";
    const result = http.parseRequestLine(buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("POST", result.?.method);
    try std.testing.expectEqualStrings("/test", result.?.path);
}

test "find content length" {
    const buf = "GET / HTTP/1.1\r\nContent-Length: 1234\r\n\r\n";
    const len = http.findContentLength(buf);
    try std.testing.expect(len == 1234);
}

test "find content length zero" {
    const buf = "GET / HTTP/1.1\r\n\r\n";
    const len = http.findContentLength(buf);
    try std.testing.expect(len == null);
}