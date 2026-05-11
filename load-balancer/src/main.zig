const std = @import("std");
const linux = std.os.linux;

const AF_INET = 2;
const AF_UNIX = 1;
const SOL_SOCKET = 1;
const SO_REUSEADDR = 2;
const SOCK_STREAM = 1;

const BUFFER_SIZE = 16384;
const NUM_BACKENDS = 2;

const UDS_PATHS = [NUM_BACKENDS][]const u8{
    "/tmp/rinha/api-1.sock",
    "/tmp/rinha/api-2.sock",
};

var backend_idx: u32 = 0;

pub fn main() void {
    createSocketDir();
    const listen_fd = createListenSocket() catch |err| {
        std.debug.print("failed to listen: {}\n", .{err});
        return;
    };
    defer _ = linux.close(listen_fd);

    std.debug.print("LB listening on :9999\n", .{});

    while (true) {
        const client_fd = @as(c_int, @intCast(linux.accept(listen_fd, null, null)));
        if (client_fd < 0) continue;

        const idx = @atomicLoad(u32, &backend_idx, .monotonic);
        const bidx = idx % NUM_BACKENDS;
        _ = @atomicStore(u32, &backend_idx, idx + 1, .monotonic);

        const backend_fd = connectBackend(UDS_PATHS[bidx]);
        if (backend_fd) |bfd| {
            relayRequest(client_fd, bfd);
            _ = linux.close(bfd);
        } else {
            const err_resp = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n";
            _ = linux.write(client_fd, err_resp, err_resp.len);
        }

        _ = linux.close(client_fd);
    }
}

fn createSocketDir() void {
    _ = linux.mkdir("/tmp/rinha", 0o755);
}

fn createListenSocket() !c_int {
    const fd = @as(c_int, @intCast(linux.socket(AF_INET, SOCK_STREAM, 0)));
    if (fd < 0) return error.SocketFailed;

    var opt: c_int = 1;
    _ = linux.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, std.mem.asBytes(&opt), 4);

    var addr_bytes: [16]u8 = undefined;
    @memset(&addr_bytes, 0);
    const addr_ptr: [*]u16 = @ptrFromInt(@intFromPtr(&addr_bytes));
    addr_ptr[0] = AF_INET;
    addr_ptr[1] = @byteSwap(@as(u16, 9999));

    if (linux.bind(fd, @ptrFromInt(@intFromPtr(&addr_bytes)), 16) != 0) return error.BindFailed;
    if (linux.listen(fd, 128) != 0) return error.ListenFailed;

    return fd;
}

fn findDoubleCrlf(buf: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 < buf.len) {
        if (buf[i] == '\r' and buf[i+1] == '\n' and buf[i+2] == '\r' and buf[i+3] == '\n') {
            return i + 4;
        }
        i += 1;
    }
    return null;
}

fn findContentLength(buf: []const u8) usize {
    const target = "Content-Length: ";
    var i: usize = 0;
    while (i + target.len < buf.len) {
        var match = true;
        for (0..target.len) |j| {
            if (buf[i + j] != target[j]) {
                match = false;
                break;
            }
        }
        if (match) {
            var val: usize = 0;
            var pos = i + target.len;
            while (pos < buf.len and buf[pos] >= '0' and buf[pos] <= '9') {
                val = val * 10 + @as(usize, buf[pos] - '0');
                pos += 1;
            }
            return val;
        }
        i += 1;
    }
    return 0;
}

fn writeAll(fd: c_int, buf: [*]const u8, len: usize) bool {
    var written: usize = 0;
    while (written < len) {
        const w = linux.write(fd, buf + written, len - written);
        if (w <= 0) return false;
        written += @as(usize, @intCast(w));
    }
    return true;
}

fn relayRequest(client_fd: c_int, backend_fd: c_int) void {
    var recv_buf: [BUFFER_SIZE]u8 = undefined;
    var request_buf: [32768]u8 = undefined;
    var total_len: usize = 0;

    while (total_len < request_buf.len) {
        const n = linux.read(client_fd, @ptrFromInt(@intFromPtr(&recv_buf)), BUFFER_SIZE);
        if (n > 0) {
            const copy_len = @min(@as(usize, @intCast(n)), request_buf.len - total_len);
            @memcpy(request_buf[total_len..total_len + copy_len], recv_buf[0..copy_len]);
            total_len += copy_len;

            if (findDoubleCrlf(request_buf[0..total_len])) |header_end| {
                const cl = findContentLength(request_buf[0..total_len]);
                if (total_len - header_end >= cl) break;
            }
        }
        if (n <= 0) break;
    }

    if (total_len == 0) return;
    if (!writeAll(backend_fd, @ptrFromInt(@intFromPtr(&request_buf)), total_len)) return;

    while (true) {
        const n = linux.read(backend_fd, @ptrFromInt(@intFromPtr(&recv_buf)), BUFFER_SIZE);
        if (n > 0) {
            if (!writeAll(client_fd, @ptrFromInt(@intFromPtr(&recv_buf)), @as(usize, @intCast(n)))) break;
        }
        if (n < 0) {
            const err = linux.errno;
            if (err == 11) continue;
            break;
        }
        if (n == 0) break;
    }
}

fn connectBackend(path: []const u8) ?c_int {
    const fd = @as(c_int, @intCast(linux.socket(AF_UNIX, SOCK_STREAM, 0)));
    if (fd < 0) return null;

    var addr: [110]u8 = undefined;
    @memset(&addr, 0);
    addr[0] = AF_UNIX;
    @memcpy(addr[2..], path);

    const path_len = 2 + path.len + 1;
    const res = linux.connect(fd, @ptrFromInt(@intFromPtr(&addr)), @as(u32, @intCast(path_len)));
    if (res != 0) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}