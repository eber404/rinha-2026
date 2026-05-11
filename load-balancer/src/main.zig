const std = @import("std");
const linux = std.os.linux;

const AF_INET = 2;
const AF_UNIX = 1;
const SOL_SOCKET = 1;
const SO_REUSEADDR = 2;
const SOCK_STREAM = 1;

const BUFFER_SIZE = 4096;
const NUM_BACKENDS = 2;

const UDS_PATHS = [NUM_BACKENDS][]const u8{
    "/tmp/rinha/api-1.sock",
    "/tmp/rinha/api-2.sock",
};

var backend_idx: u32 = 0;

pub fn main() !void {
    try createSocketDir();
    const listen_fd = try createListenSocket();
    defer _ = linux.close(listen_fd);

    std.debug.print("LB listening on :9999\n", .{});

    while (true) {
        const client_fd = @as(c_int, @intCast(linux.accept(listen_fd, null, null)));
        if (client_fd < 0) continue;
        defer _ = linux.close(client_fd);

        const idx = @atomicLoad(u32, &backend_idx, .monotonic);
        const bidx = idx % NUM_BACKENDS;

        const backend_fd = connectBackend(UDS_PATHS[bidx]);
        if (backend_fd) |bfd| {
            defer _ = linux.close(bfd);
            proxyLoop(client_fd, bfd);
        } else {
            const alt_idx = (bidx + 1) % NUM_BACKENDS;
            const alt_fd = connectBackend(UDS_PATHS[alt_idx]);
            if (alt_fd) |afd| {
                defer _ = linux.close(afd);
                proxyLoop(client_fd, afd);
            }
        }

        _ = @atomicStore(u32, &backend_idx, idx + 1, .monotonic);
    }
}

fn createSocketDir() !void {
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

fn connectBackend(path: []const u8) ?c_int {
    const fd = @as(c_int, @intCast(linux.socket(AF_UNIX, SOCK_STREAM, 0)));
    if (fd < 0) return null;

    var addr: [108]u8 = undefined;
    @memset(&addr, 0);
    addr[0] = AF_UNIX;
    @memcpy(addr[2..][0..path.len], path);

    const res = linux.connect(fd, @ptrFromInt(@intFromPtr(&addr)), @sizeOf(@TypeOf(addr)));
    if (res != 0) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}