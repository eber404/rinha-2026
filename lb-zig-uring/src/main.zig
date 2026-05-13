const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

fn toFd(res: usize) !linux.fd_t {
    return switch (linux.errno(res)) {
        .SUCCESS => @as(linux.fd_t, @intCast(res)),
        else => error.SyscallFailed,
    };
}

const MAX_CONN: usize = 131072;
const READ_BUF: usize = 8192;
const CQE_BATCH: usize = 256;

const Op = enum(u8) {
    accept,
    connect,
    recv_client,
    send_backend,
    recv_backend,
    send_client,
    close_client,
    close_backend,
};

const Endpoint = struct {
    fd: linux.fd_t = -1,
    read_open: bool = true,
    write_open: bool = true,
};

const Conn = struct {
    id: u32,
    used: bool = false,
    backend_connecting: bool = false,

    client: Endpoint = .{},
    backend: Endpoint = .{},

    to_backend: [READ_BUF]u8 = undefined,
    to_backend_len: usize = 0,
    to_backend_off: usize = 0,

    to_client: [READ_BUF]u8 = undefined,
    to_client_len: usize = 0,
    to_client_off: usize = 0,
};

const State = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    listener_fd: linux.fd_t,

    backend_paths: [2][]const u8,
    rr: u32 = 0,

    conns: []Conn,
    free_ids: []u32,
    free_top: usize = 0,

    fn init(allocator: std.mem.Allocator, listener_fd: linux.fd_t, backend_paths: [2][]const u8, entries: u16) !State {
        var ring = try linux.IoUring.init(entries, 0);
        errdefer ring.deinit();

        const conns = try allocator.alloc(Conn, MAX_CONN);
        errdefer allocator.free(conns);
        const free_ids = try allocator.alloc(u32, MAX_CONN);
        errdefer allocator.free(free_ids);

        var s = State{
            .allocator = allocator,
            .ring = ring,
            .listener_fd = listener_fd,
            .backend_paths = backend_paths,
            .conns = conns,
            .free_ids = free_ids,
        };

        for (0..MAX_CONN) |i| {
            s.conns[i] = Conn{ .id = @as(u32, @intCast(i)) };
            s.free_ids[i] = @as(u32, @intCast(MAX_CONN - 1 - i));
        }
        s.free_top = MAX_CONN;

        return s;
    }

    fn deinit(self: *State) void {
        self.ring.deinit();
        self.allocator.free(self.conns);
        self.allocator.free(self.free_ids);
    }

    fn packUserData(op: Op, conn_id: u32) u64 {
        return (@as(u64, @intFromEnum(op)) << 56) | @as(u64, conn_id);
    }

    fn unpackOp(user_data: u64) Op {
        return @enumFromInt(@as(u8, @truncate(user_data >> 56)));
    }

    fn unpackConnId(user_data: u64) u32 {
        return @as(u32, @truncate(user_data));
    }

    fn allocConn(self: *State) ?*Conn {
        if (self.free_top == 0) return null;
        self.free_top -= 1;
        const id = self.free_ids[self.free_top];
        const c = &self.conns[id];
        c.* = Conn{ .id = id, .used = true };
        return c;
    }

    fn freeConn(self: *State, c: *Conn) void {
        if (c.client.fd >= 0) _ = linux.close(c.client.fd);
        if (c.backend.fd >= 0) _ = linux.close(c.backend.fd);
        c.used = false;
        if (self.free_top < MAX_CONN) {
            self.free_ids[self.free_top] = c.id;
            self.free_top += 1;
        }
    }

    fn backendIndex(self: *State) usize {
        const v = self.rr;
        self.rr +%= 1;
        return @as(usize, @intCast(v % 2));
    }

    fn submitAccept(self: *State) !void {
        _ = try self.ring.accept(packUserData(.accept, 0), self.listener_fd, null, null, posix.SOCK.CLOEXEC);
    }

    fn submitRecvClient(self: *State, c: *Conn) !void {
        if (!c.client.read_open) return;
        if (c.to_backend_len != 0) return;
        _ = try self.ring.recv(packUserData(.recv_client, c.id), c.client.fd, .{ .buffer = c.to_backend[0..] }, 0);
    }

    fn submitSendBackend(self: *State, c: *Conn) !void {
        if (!c.backend.write_open) return;
        if (c.to_backend_len == 0) return;
        const buf = c.to_backend[c.to_backend_off .. c.to_backend_off + c.to_backend_len];
        _ = try self.ring.send(packUserData(.send_backend, c.id), c.backend.fd, buf, 0);
    }

    fn submitRecvBackend(self: *State, c: *Conn) !void {
        if (!c.backend.read_open) return;
        if (c.to_client_len != 0) return;
        _ = try self.ring.recv(packUserData(.recv_backend, c.id), c.backend.fd, .{ .buffer = c.to_client[0..] }, 0);
    }

    fn submitSendClient(self: *State, c: *Conn) !void {
        if (!c.client.write_open) return;
        if (c.to_client_len == 0) return;
        const buf = c.to_client[c.to_client_off .. c.to_client_off + c.to_client_len];
        _ = try self.ring.send(packUserData(.send_client, c.id), c.client.fd, buf, 0);
    }

    fn submitConnectBackend(self: *State, c: *Conn) !void {
        var addr = std.mem.zeroes(posix.sockaddr.un);
        addr.family = posix.AF.UNIX;
        const p = self.backend_paths[self.backendIndex()];
        if (p.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..p.len], p);

        _ = try self.ring.connect(
            packUserData(.connect, c.id),
            c.backend.fd,
            @ptrCast(&addr),
            @sizeOf(posix.sockaddr.un),
        );
    }

    fn halfCloseWrite(fd: linux.fd_t) void {
        _ = linux.shutdown(fd, linux.SHUT.WR);
    }

    fn processAccept(self: *State, res: i32) !void {
        defer self.submitAccept() catch {};
        if (res < 0) return;

        const cfd: linux.fd_t = @intCast(res);
        const c = self.allocConn() orelse {
            _ = linux.close(cfd);
            return;
        };
        c.client.fd = cfd;

        const bfd = try toFd(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
        c.backend.fd = bfd;
        c.backend_connecting = true;

        try self.submitConnectBackend(c);
    }

    fn processConnect(self: *State, c: *Conn, res: i32) !void {
        if (res < 0) {
            self.freeConn(c);
            return;
        }
        c.backend_connecting = false;
        try self.submitRecvClient(c);
        try self.submitRecvBackend(c);
    }

    fn processRecvClient(self: *State, c: *Conn, res: i32) !void {
        if (res == 0) {
            c.client.read_open = false;
            if (c.to_backend_len == 0 and c.backend.write_open) {
                halfCloseWrite(c.backend.fd);
                c.backend.write_open = false;
            }
            return;
        }
        if (res < 0) {
            self.freeConn(c);
            return;
        }

        c.to_backend_off = 0;
        c.to_backend_len = @as(usize, @intCast(res));
        try self.submitSendBackend(c);
    }

    fn processSendBackend(self: *State, c: *Conn, res: i32) !void {
        if (res < 0) {
            self.freeConn(c);
            return;
        }
        const n = @as(usize, @intCast(res));
        if (n >= c.to_backend_len) {
            c.to_backend_len = 0;
            c.to_backend_off = 0;
            if (!c.client.read_open and c.backend.write_open) {
                halfCloseWrite(c.backend.fd);
                c.backend.write_open = false;
            }
            try self.submitRecvClient(c);
            return;
        }
        c.to_backend_off += n;
        c.to_backend_len -= n;
        try self.submitSendBackend(c);
    }

    fn processRecvBackend(self: *State, c: *Conn, res: i32) !void {
        if (res == 0) {
            c.backend.read_open = false;
            if (c.to_client_len == 0 and c.client.write_open) {
                halfCloseWrite(c.client.fd);
                c.client.write_open = false;
            }
            if (!c.client.read_open and !c.backend.read_open and c.to_client_len == 0 and c.to_backend_len == 0) {
                self.freeConn(c);
            }
            return;
        }
        if (res < 0) {
            self.freeConn(c);
            return;
        }

        c.to_client_off = 0;
        c.to_client_len = @as(usize, @intCast(res));
        try self.submitSendClient(c);
    }

    fn processSendClient(self: *State, c: *Conn, res: i32) !void {
        if (res < 0) {
            self.freeConn(c);
            return;
        }
        const n = @as(usize, @intCast(res));
        if (n >= c.to_client_len) {
            c.to_client_len = 0;
            c.to_client_off = 0;
            if (!c.backend.read_open and c.client.write_open) {
                halfCloseWrite(c.client.fd);
                c.client.write_open = false;
            }
            if (!c.client.read_open and !c.backend.read_open and c.to_client_len == 0 and c.to_backend_len == 0) {
                self.freeConn(c);
                return;
            }
            try self.submitRecvBackend(c);
            return;
        }
        c.to_client_off += n;
        c.to_client_len -= n;
        try self.submitSendClient(c);
    }

    fn run(self: *State) !void {
        try self.submitAccept();
        _ = try self.ring.submit();

        var cqes: [CQE_BATCH]linux.io_uring_cqe = undefined;
        while (true) {
            const count = try self.ring.copy_cqes(&cqes, 1);
            if (count == 0) continue;

            for (cqes[0..count]) |cqe| {
                const op = unpackOp(cqe.user_data);
                const conn_id = unpackConnId(cqe.user_data);
                const res = cqe.res;

                switch (op) {
                    .accept => try self.processAccept(res),
                    .connect, .recv_client, .send_backend, .recv_backend, .send_client => {
                        if (conn_id >= MAX_CONN) continue;
                        const c = &self.conns[conn_id];
                        if (!c.used) continue;

                        switch (op) {
                            .connect => try self.processConnect(c, res),
                            .recv_client => try self.processRecvClient(c, res),
                            .send_backend => try self.processSendBackend(c, res),
                            .recv_backend => try self.processRecvBackend(c, res),
                            .send_client => try self.processSendClient(c, res),
                            else => {},
                        }
                    },
                    else => {},
                }
            }

            _ = try self.ring.submit();
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const port: u16 = 9999;
    const ring_entries: u16 = 4096;
    const b1 = "/tmp/rinha/api-1.sock";
    const b2 = "/tmp/rinha/api-2.sock";

    const listener_fd = try toFd(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    defer _ = linux.close(listener_fd);

    const one: i32 = 1;
    if (linux.errno(linux.setsockopt(listener_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one).ptr, @sizeOf(i32))) != .SUCCESS) return error.SyscallFailed;
    if (linux.errno(linux.setsockopt(listener_fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, std.mem.asBytes(&one).ptr, @sizeOf(i32))) != .SUCCESS) return error.SyscallFailed;

    var addr = std.mem.zeroInit(posix.sockaddr.in, .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
    });
    if (linux.errno(linux.bind(listener_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in))) != .SUCCESS) return error.SyscallFailed;
    if (linux.errno(linux.listen(listener_fd, 32768)) != .SUCCESS) return error.SyscallFailed;

    var state = try State.init(allocator, listener_fd, .{ b1, b2 }, ring_entries);
    defer state.deinit();

    try state.run();
}
