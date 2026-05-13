const std = @import("std");
const linux = std.os.linux;
const payload = @import("payload.zig");
const dataset = @import("dataset.zig");
const scorer_mod = @import("scorer.zig");
const quantization = @import("quantization.zig");

const MAX_REQ = 64 * 1024;

fn statusLine(code: u16) []const u8 {
    return switch (code) {
        200 => "HTTP/1.1 200 OK\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        405 => "HTTP/1.1 405 Method Not Allowed\r\n",
        413 => "HTTP/1.1 413 Payload Too Large\r\n",
        else => "HTTP/1.1 503 Service Unavailable\r\n",
    };
}

fn toFd(res: usize) !linux.fd_t {
    return switch (linux.errno(res)) {
        .SUCCESS => @as(linux.fd_t, @intCast(res)),
        else => error.SyscallFailed,
    };
}

fn ensureOk(res: usize) !void {
    switch (linux.errno(res)) {
        .SUCCESS => return,
        else => return error.SyscallFailed,
    }
}

fn writeAll(fd: linux.fd_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = toFd(linux.write(fd, data.ptr + off, data.len - off)) catch return;
        if (n <= 0) return;
        off += @as(usize, @intCast(n));
    }
}

fn writeResponse(fd: linux.fd_t, code: u16, body: []const u8, content_type: []const u8) void {
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "{s}Content-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ statusLine(code), content_type, body.len }) catch return;
    writeAll(fd, head);
    writeAll(fd, body);
}

fn findHeaderEnd(buf: []const u8, n: usize) ?usize {
    if (n < 4) return null;
    var i: usize = 0;
    while (i + 3 < n) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n') return i + 4;
    }
    return null;
}

fn parseContentLength(headers: []const u8) usize {
    const key = "Content-Length:";
    var i: usize = 0;
    while (i + key.len <= headers.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(headers[i .. i + key.len], key)) continue;
        var j = i + key.len;
        while (j < headers.len and (headers[j] == ' ' or headers[j] == '\t')) : (j += 1) {}
        var v: usize = 0;
        while (j < headers.len and headers[j] >= '0' and headers[j] <= '9') : (j += 1) {
            v = v * 10 + (headers[j] - '0');
        }
        return v;
    }
    return 0;
}

fn handleConn(fd: linux.fd_t, scorer: *scorer_mod.Scorer) void {
    var buf: [MAX_REQ]u8 = undefined;
    var used: usize = 0;
    var header_end: ?usize = null;

    while (used < buf.len) {
        const n = toFd(linux.read(fd, buf[used..].ptr, buf.len - used)) catch return;
        if (n == 0) break;
        used += @as(usize, @intCast(n));
        if (header_end == null) header_end = findHeaderEnd(&buf, used);
        if (header_end != null) break;
    }

    const he = header_end orelse {
        writeResponse(fd, 404, "", "text/plain");
        return;
    };

    const req = buf[0..used];
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse {
        writeResponse(fd, 404, "", "text/plain");
        return;
    };
    const line = req[0..line_end];

    if (std.mem.startsWith(u8, line, "GET /ready ")) {
        writeResponse(fd, 200, "ok", "text/plain");
        return;
    }

    if (!std.mem.startsWith(u8, line, "POST /fraud-score ")) {
        const code: u16 = if (std.mem.startsWith(u8, line, "GET ")) 404 else 405;
        writeResponse(fd, code, "", "text/plain");
        return;
    }

    const cl = parseContentLength(req[0..he]);
    if (cl == 0 or cl + he > buf.len) {
        writeResponse(fd, 413, "", "text/plain");
        return;
    }

    while (used < he + cl and used < buf.len) {
        const n = toFd(linux.read(fd, buf[used..].ptr, buf.len - used)) catch {
            writeResponse(fd, 503, "", "text/plain");
            return;
        };
        if (n == 0) break;
        used += @as(usize, @intCast(n));
    }

    if (used < he + cl) {
        writeResponse(fd, 503, "", "text/plain");
        return;
    }

    const body = buf[he .. he + cl];
    const features = payload.parsePayload(body);
    const q = quantization.quantize(&features);
    const score = scorer.score(&q);
    const approved = score < 0.5;

    var out: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&out, "{{\"approved\":{s},\"fraud_score\":{d:.6}}}", .{ if (approved) "true" else "false", score }) catch {
        writeResponse(fd, 503, "", "text/plain");
        return;
    };
    writeResponse(fd, 200, json, "application/json");
}

pub fn main(init: std.process.Init.Minimal) !void {
    const env_instance = std.process.Environ.getPosix(init.environ, "INSTANCE_ID");
    const instance = if (env_instance) |v| std.mem.sliceTo(v, 0) else "1";
    var socket_path_buf: [128]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_path_buf, "/tmp/rinha/api-{s}.sock", .{instance});

    var data_dir_buf: [128]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&data_dir_buf, "/data/vector-index", .{});

    var ds = dataset.Dataset.init();
    try ds.load(data_dir);
    defer ds.deinit();
    var scorer = scorer_mod.Scorer.init(&ds);

    const fd = try toFd(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    defer _ = linux.close(fd);

    var addr = std.mem.zeroes(linux.sockaddr.un);
    addr.family = linux.AF.UNIX;
    if (socket_path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try ensureOk(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
    try ensureOk(linux.listen(fd, 1024));

    while (true) {
        const cfd = toFd(linux.accept4(fd, null, null, linux.SOCK.CLOEXEC)) catch continue;
        handleConn(cfd, &scorer);
        _ = linux.close(cfd);
    }
}
