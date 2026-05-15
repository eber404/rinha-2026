#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>

static constexpr int LISTEN_PORT = 9999;
static constexpr int BACKLOG = 4096;
static constexpr size_t BUF_SIZE = 65536;
static constexpr int MAX_CONNS = 512;

struct Conn {
    int client_fd = -1;
    int backend_fd = -1;
    bool connecting = false;
    bool client_eof = false;
    bool backend_eof = false;
    char c2b[BUF_SIZE];
    size_t c2b_len = 0;
    char b2c[BUF_SIZE];
    size_t b2c_len = 0;
};

static const char* backends[] = {
    "/tmp/rinha/api-1.sock",
    "/tmp/rinha/api-2.sock",
};
static int next_backend = 0;

static int set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int create_listen_socket() {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(LISTEN_PORT);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(fd, (sockaddr*)&addr, sizeof(addr)) < 0 || listen(fd, BACKLOG) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int connect_backend(bool& out_in_progress) {
    int n = sizeof(backends) / sizeof(backends[0]);
    for (int i = 0; i < n; ++i) {
        int idx = (next_backend + i) % n;
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0);
        if (fd < 0) continue;
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, backends[idx], sizeof(addr.sun_path) - 1);
        int r = connect(fd, (sockaddr*)&addr, sizeof(addr));
        if (r == 0) {
            out_in_progress = false;
            next_backend = (idx + 1) % n;
            return fd;
        } else if (errno == EINPROGRESS) {
            out_in_progress = true;
            next_backend = (idx + 1) % n;
            return fd;
        }
        close(fd);
    }
    out_in_progress = false;
    return -1;
}

static void close_conn(Conn& c) {
    if (c.client_fd >= 0) close(c.client_fd);
    if (c.backend_fd >= 0) close(c.backend_fd);
    c.client_fd = -1;
    c.backend_fd = -1;
    c.connecting = false;
    c.client_eof = false;
    c.backend_eof = false;
    c.c2b_len = 0;
    c.b2c_len = 0;
}

// Read from from_fd, write to to_fd. If write blocks, buffer in buf/len.
// Returns: 0 = ok, 1 = EOF, -1 = error.
static int forward(int from_fd, int to_fd, char* buf, size_t& len) {
    char temp[BUF_SIZE];
    ssize_t r = read(from_fd, temp, sizeof(temp));
    if (r < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }
    if (r == 0) return 1;

    if (len > 0) {
        ssize_t w = write(to_fd, buf, len);
        if (w < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (len + (size_t)r > BUF_SIZE) return -1;
                memcpy(buf + len, temp, r);
                len += r;
                return 0;
            }
            return -1;
        }
        if ((size_t)w < len) {
            memmove(buf, buf + w, len - w);
            len -= w;
            if (len + (size_t)r > BUF_SIZE) return -1;
            memcpy(buf + len, temp, r);
            len += r;
            return 0;
        }
        len = 0;
    }

    ssize_t w = write(to_fd, temp, r);
    if (w < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if ((size_t)r > BUF_SIZE) return -1;
            memcpy(buf, temp, r);
            len = r;
            return 0;
        }
        return -1;
    }
    if ((size_t)w < (size_t)r) {
        size_t rem = r - w;
        if (rem > BUF_SIZE) return -1;
        memcpy(buf, temp + w, rem);
        len = rem;
        return 0;
    }
    return 0;
}

// Drain buffered data to to_fd. Returns true on error.
static bool drain_buf(int to_fd, char* buf, size_t& len) {
    if (len == 0) return false;
    ssize_t w = write(to_fd, buf, len);
    if (w < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return false;
        return true;
    }
    if ((size_t)w < len) {
        memmove(buf, buf + w, len - w);
        len -= w;
    } else {
        len = 0;
    }
    return false;
}

int main() {
    signal(SIGPIPE, SIG_IGN);
    int listen_fd = create_listen_socket();
    if (listen_fd < 0) { perror("listen socket"); return 1; }

    Conn conns[MAX_CONNS]{};
    int num_conns = 0;

    while (true) {
        struct pollfd fds[MAX_CONNS * 2 + 1];
        int nfds = 0;
        fds[nfds++] = {listen_fd, POLLIN, 0};

        for (int i = 0; i < num_conns; ++i) {
            Conn& c = conns[i];
            short bev = 0;
            if (c.connecting) {
                bev = POLLOUT;
            } else {
                if (!c.backend_eof) bev |= POLLIN;
                if (c.c2b_len > 0) bev |= POLLOUT;
            }
            fds[nfds++] = {c.backend_fd, bev, 0};

            short cev = 0;
            if (!c.client_eof) cev |= POLLIN;
            if (c.b2c_len > 0) cev |= POLLOUT;
            fds[nfds++] = {c.client_fd, cev, 0};
        }

        int ready = poll(fds, nfds, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            perror("poll");
            continue;
        }

        if (fds[0].revents & POLLIN) {
            int client_fd = accept(listen_fd, nullptr, nullptr);
            if (client_fd >= 0) {
                set_nonblock(client_fd);
                bool in_progress = false;
                int backend_fd = connect_backend(in_progress);
                if (backend_fd < 0 || num_conns >= MAX_CONNS) {
                    close(client_fd);
                    if (backend_fd >= 0) close(backend_fd);
                } else {
                    Conn& c = conns[num_conns++];
                    c.client_fd = client_fd;
                    c.backend_fd = backend_fd;
                    c.connecting = in_progress;
                }
            }
        }

        int idx = 1;
        for (int i = 0; i < num_conns; ++i) {
            Conn& c = conns[i];
            bool close_it = false;
            short bev = fds[idx++].revents;
            short cev = fds[idx++].revents;

            if (c.connecting) {
                if (bev & (POLLOUT | POLLERR | POLLHUP)) {
                    int err = 0;
                    socklen_t len = sizeof(err);
                    getsockopt(c.backend_fd, SOL_SOCKET, SO_ERROR, &err, &len);
                    if (err != 0) close_it = true;
                    else c.connecting = false;
                }
            }

            if (!c.connecting && !close_it) {
                if (c.c2b_len > 0) {
                    if (drain_buf(c.backend_fd, c.c2b, c.c2b_len)) close_it = true;
                }
                if (!close_it && c.b2c_len > 0) {
                    if (drain_buf(c.client_fd, c.b2c, c.b2c_len)) close_it = true;
                }

                if (!close_it && !c.backend_eof && (bev & POLLIN)) {
                    int rc = forward(c.backend_fd, c.client_fd, c.b2c, c.b2c_len);
                    if (rc == 1) c.backend_eof = true;
                    else if (rc < 0) close_it = true;
                }
                if (!close_it && !c.client_eof && (cev & POLLIN)) {
                    int rc = forward(c.client_fd, c.backend_fd, c.c2b, c.c2b_len);
                    if (rc == 1) c.client_eof = true;
                    else if (rc < 0) close_it = true;
                }

                if (!close_it && !c.backend_eof && (bev & (POLLERR | POLLHUP))) {
                    c.backend_eof = true;
                }
                if (!close_it && !c.client_eof && (cev & (POLLERR | POLLHUP))) {
                    c.client_eof = true;
                }

                if (!close_it && c.backend_eof && c.c2b_len == 0 && c.b2c_len == 0) {
                    close_it = true;
                }
            }

            if (close_it) {
                close_conn(c);
            }
        }

        int j = 0;
        for (int i = 0; i < num_conns; ++i) {
            if (conns[i].client_fd >= 0) {
                if (i != j) conns[j] = conns[i];
                ++j;
            }
        }
        num_conns = j;
    }
}
