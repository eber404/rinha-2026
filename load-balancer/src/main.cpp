#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <thread>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <poll.h>

static constexpr int LISTEN_PORT = 9999;
static constexpr int BACKLOG = 4096;
static constexpr size_t BUF_SIZE = 65536;

static const char* BACKENDS[] = {
    "/tmp/rinha/api-1.sock",
    "/tmp/rinha/api-2.sock",
};

static std::atomic<unsigned> NEXT_BACKEND{0};

static int set_nonblocking(int fd) {
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    return 0;
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
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0 || listen(fd, BACKLOG) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int connect_backend() {
    constexpr int n = sizeof(BACKENDS) / sizeof(BACKENDS[0]);
    const unsigned start = NEXT_BACKEND.fetch_add(1, std::memory_order_relaxed);
    for (int i = 0; i < n; ++i) {
        const int idx = static_cast<int>((start + i) % n);
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) continue;
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        std::strncpy(addr.sun_path, BACKENDS[idx], sizeof(addr.sun_path) - 1);
        if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) return fd;
        close(fd);
    }
    return -1;
}

static bool write_all_nonblocking(int to, const char* buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        const ssize_t w = send(to, buf + sent, len - sent, MSG_NOSIGNAL);
        if (w > 0) {
            sent += static_cast<size_t>(w);
            continue;
        }
        if (w == 0) return false;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            pollfd pfd{to, POLLOUT, 0};
            const int pr = poll(&pfd, 1, -1);
            if (pr <= 0) {
                if (pr < 0 && errno == EINTR) continue;
                return false;
            }
            continue;
        }
        return false;
    }
    return true;
}

static bool forward_once(int from, int to, bool& from_open) {
    char buf[BUF_SIZE];
    const ssize_t r = read(from, buf, sizeof(buf));
    if (r == 0) {
        from_open = false;
        shutdown(to, SHUT_WR);
        return true;
    }
    if (r < 0) {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) return true;
        from_open = false;
        shutdown(to, SHUT_WR);
        return true;
    }
    if (!write_all_nonblocking(to, buf, static_cast<size_t>(r))) {
        from_open = false;
        shutdown(to, SHUT_WR);
    }
    return true;
}

static void relay_bidirectional(int a, int b) {
    bool a_open = true;
    bool b_open = true;

    while (a_open || b_open) {
        pollfd pfds[2];
        nfds_t n = 0;
        if (a_open) pfds[n++] = pollfd{a, POLLIN, 0};
        if (b_open) pfds[n++] = pollfd{b, POLLIN, 0};
        if (n == 0) break;

        const int pr = poll(pfds, n, -1);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) continue;

        nfds_t idx = 0;
        if (a_open) {
            if (pfds[idx].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) {
                forward_once(a, b, a_open);
            }
            ++idx;
        }
        if (b_open) {
            if (pfds[idx].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) {
                forward_once(b, a, b_open);
            }
        }
    }
}

static void handle_client(int client_fd) {
    int backend_fd = connect_backend();
    if (backend_fd < 0) {
        close(client_fd);
        return;
    }

    if (set_nonblocking(client_fd) < 0 || set_nonblocking(backend_fd) < 0) {
        close(backend_fd);
        close(client_fd);
        return;
    }

    relay_bidirectional(client_fd, backend_fd);
    close(backend_fd);
    close(client_fd);
}

int main() {
    signal(SIGPIPE, SIG_IGN);
    std::fprintf(stderr, "LB starting on port %d\n", LISTEN_PORT);
    int listen_fd = create_listen_socket();
    if (listen_fd < 0) {
        perror("listen socket");
        return 1;
    }

    while (true) {
        int client_fd = accept(listen_fd, nullptr, nullptr);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }
        std::thread(handle_client, client_fd).detach();
    }
}
