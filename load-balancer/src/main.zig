const std = @import("std");
const linux = std.os.linux;

const BACKEND_HOSTS = [_][]const u8{
    "fraud-api-1:8080",
    "fraud-api-2:8080",
};
const NUM_BACKENDS = BACKEND_HOSTS.len;

const AF_INET = 2;
const SOL_SOCKET = 1;
const SO_REUSEADDR = 2;
const SOCK_STREAM = 1;

const BUFFER_SIZE = 8192;

pub fn main() !void {
    const listen_fd = @as(c_int, @intCast(linux.socket(AF_INET, SOCK_STREAM, 0)));
    if (listen_fd < 0) return error.SocketFailed;
    defer _ = linux.close(listen_fd);

    var opt: c_int = 1;
    _ = linux.setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, std.mem.asBytes(&opt), 4);

    var addr_bytes: [16]u8 = undefined;
    @memset(&addr_bytes, 0);
    const addr_ptr: [*]u16 = @ptrFromInt(@intFromPtr(&addr_bytes));
    addr_ptr[0] = AF_INET;
    addr_ptr[1] = @byteSwap(@as(u16, 9999));

    if (linux.bind(listen_fd, @ptrFromInt(@intFromPtr(&addr_bytes)), 16) != 0) return error.BindFailed;
    if (linux.listen(listen_fd, 128) != 0) return error.ListenFailed;

    var backend_idx: usize = 0;

    while (true) {
        const client_fd = @as(c_int, @intCast(linux.accept(listen_fd, null, null)));
        if (client_fd < 0) continue;

        const bidx = backend_idx;
        backend_idx = (backend_idx + 1) % NUM_BACKENDS;

        const backend_fd = connectBackend(BACKEND_HOSTS[bidx]) orelse {
            _ = linux.close(client_fd);
            continue;
        };

        proxyLoop(client_fd, backend_fd);

        _ = linux.close(backend_fd);
        _ = linux.close(client_fd);
    }
}

fn proxyLoop(client_fd: c_int, backend_fd: c_int) void {
    var buf: [BUFFER_SIZE]u8 = undefined;
    const buf_ptr: [*]u8 = @ptrFromInt(@intFromPtr(&buf));

    while (true) {
        const r = linux.read(client_fd, buf_ptr, BUFFER_SIZE);
        if (r > 0) {
            const w = linux.write(backend_fd, buf_ptr, @as(usize, @intCast(r)));
            if (w <= 0) break;
        } else {
            break;
        }

        const r2 = linux.read(backend_fd, buf_ptr, BUFFER_SIZE);
        if (r2 > 0) {
            const w2 = linux.write(client_fd, buf_ptr, @as(usize, @intCast(r2)));
            if (w2 <= 0) break;
        } else {
            break;
        }
    }
}

fn connectBackend(host_port: []const u8) ?c_int {
    const colon_idx = std.mem.indexOfScalar(u8, host_port, ':') orelse return null;
    const ip_str = host_port[0..colon_idx];
    const port_str = host_port[colon_idx + 1..];

    var ip: [4]u8 = undefined;
    var ip_idx: usize = 0;
    var start: usize = 0;

    var i: usize = 0;
    while (i < ip_str.len) : (i += 1) {
        if (ip_str[i] == '.') {
            ip[ip_idx] = @as(u8, @intCast(parseU8(ip_str[start..i])));
            ip_idx += 1;
            start = i + 1;
        }
    }
    ip[ip_idx] = @as(u8, @intCast(parseU8(ip_str[start..])));

    const port = @as(u16, @intCast(parseU16(port_str)));

    const fd = @as(c_int, @intCast(linux.socket(AF_INET, SOCK_STREAM, 0)));
    if (fd < 0) return null;

    var addr_bytes: [16]u8 = undefined;
    @memset(&addr_bytes, 0);
    const addr_ptr: [*]u16 = @ptrFromInt(@intFromPtr(&addr_bytes));
    addr_ptr[0] = AF_INET;
    addr_ptr[1] = @byteSwap(port);
    @memcpy(addr_bytes[4..8], &ip);

    if (linux.connect(fd, @ptrFromInt(@intFromPtr(&addr_bytes)), 16) != 0) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

fn parseU8(s: []const u8) u8 {
    var val: u8 = 0;
    for (s) |c| {
        val = val * 10 + (c - '0');
    }
    return val;
}

fn parseU16(s: []const u8) u16 {
    var val: u16 = 0;
    for (s) |c| {
        val = val * 10 + (c - '0');
    }
    return val;
}