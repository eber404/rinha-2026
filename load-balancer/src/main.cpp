#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <thread>
#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>

static constexpr int LISTEN_PORT = 9999;
static constexpr int BACKLOG = 4096;
static constexpr size_t BUF_SIZE = 65536;

static const char* BACKENDS[] = {
    "/tmp/rinha/api-1.sock",
    "/tmp/rinha/api-2.sock",
};

static std::atomic<unsigned> NEXT_BACKEND{0};

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

static void relay(int from, int to) {
    char buf[BUF_SIZE];
    while (true) {
        ssize_t r = read(from, buf, sizeof(buf));
        if (r == 0) break;
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        char* p = buf;
        ssize_t remaining = r;
        while (remaining > 0) {
            ssize_t w = write(to, p, static_cast<size_t>(remaining));
            if (w < 0) {
                if (errno == EINTR) continue;
                shutdown(to, SHUT_WR);
                return;
            }
            p += w;
            remaining -= w;
        }
    }
    shutdown(to, SHUT_WR);
}

static void handle_client(int client_fd) {
    int backend_fd = connect_backend();
    if (backend_fd < 0) {
        close(client_fd);
        return;
    }

    std::thread c2b(relay, client_fd, backend_fd);
    std::thread b2c(relay, backend_fd, client_fd);
    c2b.join();
    b2c.join();
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
