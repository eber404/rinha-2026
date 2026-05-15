#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <thread>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static constexpr int LISTEN_PORT = 9999;
static constexpr int BACKLOG = 4096;
static constexpr size_t BUF_SIZE = 65536;

struct Backend {
    std::string name;
    std::string uds_path;
};

static int create_server_socket(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(fd, (sockaddr*)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    if (listen(fd, BACKLOG) < 0) { close(fd); return -1; }
    return fd;
}

static int connect_uds(const char* path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (sockaddr*)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    return fd;
}

static void copy_stream(int from_fd, int to_fd) {
    char buf[BUF_SIZE];
    ssize_t r;
    while ((r = read(from_fd, buf, sizeof(buf))) > 0) {
        char* p = buf;
        while (r > 0) {
            ssize_t w = write(to_fd, p, r);
            if (w < 0) return;
            p += w;
            r -= w;
        }
    }
}

static void relay(int client_fd, int backend_fd) {
    std::thread t1(copy_stream, client_fd, backend_fd);
    std::thread t2(copy_stream, backend_fd, client_fd);
    t1.join();
    t2.join();
}

int main(int argc, char** argv) {
    std::vector<Backend> backends = {
        {"api-1", "/tmp/rinha/api-1.sock"},
        {"api-2", "/tmp/rinha/api-2.sock"},
    };

    int listen_fd = create_server_socket(LISTEN_PORT);
    if (listen_fd < 0) {
        fprintf(stderr, "Failed to bind to port %d\n", LISTEN_PORT);
        return 1;
    }
    fprintf(stderr, "LB listening on :%d\n", LISTEN_PORT);

    signal(SIGPIPE, SIG_IGN);

    size_t next_backend = 0;
    while (true) {
        sockaddr_in client_addr{};
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(listen_fd, (sockaddr*)&client_addr, &client_len);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }

        // Round-robin backend selection with retry
        int backend_fd = -1;
        for (size_t i = 0; i < backends.size(); ++i) {
            size_t idx = (next_backend + i) % backends.size();
            backend_fd = connect_uds(backends[idx].uds_path.c_str());
            if (backend_fd >= 0) {
                next_backend = (idx + 1) % backends.size();
                break;
            }
        }
        if (backend_fd < 0) {
            fprintf(stderr, "No backend available\n");
            close(client_fd);
            continue;
        }

        relay(client_fd, backend_fd);
        close(client_fd);
        close(backend_fd);
    }
}
