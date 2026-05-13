#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

static const char *BACKENDS[] = {
    "/tmp/rinha/api-1.sock",
    "/tmp/rinha/api-2.sock",
};

static atomic_uint rr_idx = 0;

static int set_fd_limits(int fd) {
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) != 0) return -1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) != 0) return -1;
    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) != 0) return -1;
    return 0;
}

static int connect_backend(void) {
    unsigned i = atomic_fetch_add(&rr_idx, 1);
    const char *path = BACKENDS[i % 2];

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int copy_half(int src, int dst) {
    char buf[8192];
    for (;;) {
        ssize_t n = read(src, buf, sizeof(buf));
        if (n == 0) {
            shutdown(dst, SHUT_WR);
            return 0;
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            shutdown(dst, SHUT_WR);
            return -1;
        }

        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(dst, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR) continue;
                shutdown(dst, SHUT_WR);
                return -1;
            }
            off += w;
        }
    }
}

struct copy_args {
    int src;
    int dst;
};

static void *copy_thread(void *arg) {
    struct copy_args *a = (struct copy_args *)arg;
    copy_half(a->src, a->dst);
    return NULL;
}

static void handle_client(int cfd) {
    int bfd = connect_backend();
    if (bfd < 0) {
        close(cfd);
        return;
    }

    pthread_t t1, t2;
    struct copy_args a1 = {.src = cfd, .dst = bfd};
    struct copy_args a2 = {.src = bfd, .dst = cfd};

    if (pthread_create(&t1, NULL, copy_thread, &a1) != 0) {
        close(cfd);
        close(bfd);
        return;
    }
    if (pthread_create(&t2, NULL, copy_thread, &a2) != 0) {
        shutdown(cfd, SHUT_RDWR);
        shutdown(bfd, SHUT_RDWR);
        pthread_join(t1, NULL);
        close(cfd);
        close(bfd);
        return;
    }

    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    close(cfd);
    close(bfd);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) {
        perror("socket");
        return 1;
    }
    if (set_fd_limits(lfd) != 0) {
        perror("setsockopt");
        close(lfd);
        return 1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(9999);

    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        close(lfd);
        return 1;
    }
    if (listen(lfd, 8192) != 0) {
        perror("listen");
        close(lfd);
        return 1;
    }

    for (;;) {
        int cfd = accept4(lfd, NULL, NULL, SOCK_CLOEXEC);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            continue;
        }
        handle_client(cfd);
    }
}
