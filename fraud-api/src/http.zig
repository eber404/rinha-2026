const std = @import("std");
const linux = std.os.linux;

const AF_UNIX = 1;
const SOCK_STREAM = 1;

const BUFFER_SIZE = 8192;
const MAX_HEADERS_SIZE = 4096;

const PrecomputedResponse = struct {
    status: []const u8,
    headers: []const u8,
    body: []const u8,

    fn new(status: []const u8, content_type: []const u8, body: []const u8) PrecomputedResponse {
        var headers_buf: [256]u8 = undefined;
        const headers = std.fmt.bufPrint(&headers_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ status, content_type, body.len }) catch unreachable;
        return .{
            .status = status,
            .headers = headers,
            .body = body,
        };
    }
};

pub const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,

    fn toPrecomputed(self: Response) PrecomputedResponse {
        return PrecomputedResponse.new(self.status, self.content_type, self.body);
    }
};

const Handler = *const fn (method: []const u8, path: []const u8, body: []const u8, instance_id: []const u8) []const u8;

pub const Router = struct {
    handler: Handler,
    instance_id: []const u8,

    pub fn route(r: Router, method: []const u8, path: []const u8, body: []const u8) []const u8 {
        return r.handler(method, path, body, r.instance_id);
    }
};

fn parseHeaders(buf: []const u8) ?usize {
    var i: usize = 0;
    while (i < buf.len) {
        if (i + 2 <= buf.len and buf[i] == '\r' and buf[i + 1] == '\n') {
            return i;
        }
        i += 1;
    }
    return null;
}

fn findContentLength(buf: []const u8) ?usize {
    var i: usize = 0;
    while (i + 16 < buf.len) {
        const is_content_length =
            (buf[i] | 0x20) == 'c' and
            (buf[i + 1] | 0x20) == 'o' and
            (buf[i + 2] | 0x20) == 'n' and
            (buf[i + 3] | 0x20) == 't' and
            (buf[i + 4] | 0x20) == 'e' and
            (buf[i + 5] | 0x20) == 'n' and
            (buf[i + 6] | 0x20) == 't' and
            buf[i + 7] == '-' and
            (buf[i + 8] | 0x20) == 'l' and
            (buf[i + 9] | 0x20) == 'e' and
            (buf[i + 10] | 0x20) == 'n' and
            (buf[i + 11] | 0x20) == 'g' and
            (buf[i + 12] | 0x20) == 't' and
            (buf[i + 13] | 0x20) == 'h' and
            buf[i + 14] == ':';

        if (is_content_length) {
            var pos = i + 15;
            while (pos < buf.len and buf[pos] == ' ') pos += 1;
            var val: usize = 0;
            while (pos < buf.len and buf[pos] >= '0' and buf[pos] <= '9') {
                val = val * 10 + @as(usize, buf[pos] - '0');
                pos += 1;
            }
            return val;
        }
        i += 1;
    }
    return null;
}

fn parseRequestLine(buf: []const u8) ?struct { method: []const u8, path: []const u8 } {
    var i: usize = 0;
    while (i < buf.len and buf[i] != ' ') i += 1;
    if (i >= buf.len) return null;
    const method = buf[0..i];

    var j = i + 1;
    while (j < buf.len and buf[j] != ' ') j += 1;
    if (j >= buf.len) return null;
    const path = buf[i + 1 .. j];

    return .{ .method = method, .path = path };
}

pub fn createSocketDir() !void {
    _ = linux.mkdir("/tmp/rinha", 0o755);
}

pub fn createAndBindUdsSocket(instance_id: []const u8) !c_int {
    const sock_path: [:0]const u8 = if (std.mem.eql(u8, instance_id, "1"))
        "/tmp/rinha/api-1.sock"
    else
        "/tmp/rinha/api-2.sock";

    const fd = @as(c_int, @intCast(linux.socket(AF_UNIX, SOCK_STREAM, 0)));
    if (fd < 0) return error.SocketFailed;

    _ = linux.unlink(sock_path);

    var addr: [110]u8 = undefined;
    @memset(&addr, 0);
    addr[0] = AF_UNIX;
    @memcpy(addr[2..][0..sock_path.len], sock_path);

    if (linux.bind(fd, @ptrFromInt(@intFromPtr(&addr)), 110) != 0) {
        _ = linux.close(fd);
        return error.BindFailed;
    }

    _ = linux.chmod(sock_path, 0o777);

    if (linux.listen(fd, 4096) != 0) {
        _ = linux.close(fd);
        return error.ListenFailed;
    }

    return fd;
}

pub fn readUntil(rfd: c_int, buf: []u8, target: u8) ![]const u8 {
    var total: usize = 0;
    while (true) {
        const n = linux.read(rfd, @ptrFromInt(@intFromPtr(&buf[total])), buf.len - total);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.UnexpectedEOF;
        total += @as(usize, @intCast(n));
        var i: usize = 0;
        while (i < total) : (i += 1) {
            if (buf[i] == target) return buf[0..total];
        }
        if (total >= buf.len) return error.BufferFull;
    }
}

pub fn readExact(rfd: c_int, buf: []u8, len: usize) !void {
    var total: usize = 0;
    while (total < len) {
        const n = linux.read(rfd, @ptrFromInt(@intFromPtr(&buf[total])), len - total);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.UnexpectedEOF;
        total += @as(usize, @intCast(n));
    }
}

pub fn handleConnection(rfd: c_int, router: Router) !void {
    var buf: [BUFFER_SIZE]u8 = undefined;

    var total: usize = 0;
    while (true) {
        const n = linux.read(rfd, @ptrFromInt(@intFromPtr(&buf[total])), buf.len - total);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return;
        total += @as(usize, @intCast(n));

        var i: usize = 0;
        while (i + 3 < total) : (i += 1) {
            if (buf[i] == '\r' and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n') {
                const headers = buf[0..total];
                const content_length = findContentLength(headers) orelse 0;
                const parsed = parseRequestLine(headers) orelse return;

                const header_end_pos = i + 4;
                const body_start = header_end_pos;
                const bytes_in_buf = total - header_end_pos;

                if (bytes_in_buf < content_length) {
                    const needed = content_length - bytes_in_buf;
                    const available = buf.len - total;
                    if (needed > available) return error.BufferFull;
                    try readExact(rfd, buf[total..buf.len], needed);
                    total += needed;
                }

                const resp = router.route(parsed.method, parsed.path, buf[body_start..body_start + content_length]);
                _ = linux.write(rfd, resp.ptr, resp.len);
                return;
            }
        }

        if (total >= buf.len) return error.BufferFull;
    }
}
