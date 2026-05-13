#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/epoll.h>
#include <sys/wait.h>
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
enum { MAX_EVENTS = 2048, BUF_CAP = 64 * 1024, MAX_TRACK_FD = 262144 };

struct buffer {
    uint8_t data[BUF_CAP];
    size_t start;
    size_t end;
};

struct endpoint {
    int fd;
    bool rd_open;
    bool wr_open;
    bool want_read;
    bool want_write;
};

struct conn {
    struct endpoint client;
    struct endpoint backend;
    bool backend_connecting;
    struct buffer to_backend;
    struct buffer to_client;
};

static struct conn *fd_conn[MAX_TRACK_FD];
static uint8_t fd_side[MAX_TRACK_FD];

static int worker_count(void) {
    const char *s = getenv("LB_WORKERS");
    if (!s || !*s) return 1;
    int n = atoi(s);
    if (n < 1) return 1;
    if (n > 16) return 16;
    return n;
}

static inline size_t buffer_len(const struct buffer *b) { return b->end - b->start; }

static inline size_t buffer_space(const struct buffer *b) { return BUF_CAP - b->end; }

static void buffer_compact(struct buffer *b) {
    if (b->start == 0) return;
    if (b->start == b->end) {
        b->start = 0;
        b->end = 0;
        return;
    }
    memmove(b->data, b->data + b->start, b->end - b->start);
    b->end -= b->start;
    b->start = 0;
}

static int set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return -1;
    return 0;
}

static int set_fd_limits(int fd) {
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) != 0) return -1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) != 0) return -1;
    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) != 0) return -1;
    return 0;
}

static int ep_add(int epfd, int fd, uint32_t events) {
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = events;
    ev.data.fd = fd;
    return epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);
}

static int ep_mod(int epfd, int fd, uint32_t events) {
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = events;
    ev.data.fd = fd;
    return epoll_ctl(epfd, EPOLL_CTL_MOD, fd, &ev);
}

static void ep_del(int epfd, int fd) { (void)epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL); }

static uint32_t events_for_ep(const struct endpoint *ep) {
    uint32_t ev = EPOLLERR | EPOLLHUP | EPOLLRDHUP;
    if (ep->rd_open && ep->want_read) ev |= EPOLLIN;
    if (ep->wr_open && ep->want_write) ev |= EPOLLOUT;
    return ev;
}

static void apply_interest(int epfd, const struct endpoint *ep) {
    if (ep->fd >= 0) (void)ep_mod(epfd, ep->fd, events_for_ep(ep));
}

static void map_fd(int fd, struct conn *c, uint8_t side) {
    if (fd < 0 || fd >= MAX_TRACK_FD) return;
    fd_conn[fd] = c;
    fd_side[fd] = side;
}

static void unmap_fd(int fd) {
    if (fd < 0 || fd >= MAX_TRACK_FD) return;
    fd_conn[fd] = NULL;
    fd_side[fd] = 0;
}

static void shutdown_wr(struct endpoint *ep) {
    if (!ep->wr_open) return;
    shutdown(ep->fd, SHUT_WR);
    ep->wr_open = false;
    ep->want_write = false;
}

static int connect_backend_nonblock(bool *connecting) {
    unsigned i = atomic_fetch_add(&rr_idx, 1);
    const char *path = BACKENDS[i % 2];

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        *connecting = false;
        return fd;
    }
    if (errno == EINPROGRESS) {
        *connecting = true;
        return fd;
    }

    close(fd);
    return -1;
}

static void close_conn(int epfd, struct conn *c) {
    if (!c) return;

    ep_del(epfd, c->client.fd);
    ep_del(epfd, c->backend.fd);

    unmap_fd(c->client.fd);
    unmap_fd(c->backend.fd);

    if (c->client.fd >= 0) close(c->client.fd);
    if (c->backend.fd >= 0) close(c->backend.fd);
    free(c);
}

static int backend_connect_done(struct conn *c) {
    int err = 0;
    socklen_t len = sizeof(err);
    if (getsockopt(c->backend.fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0) return -1;
    if (err != 0) {
        errno = err;
        return -1;
    }
    c->backend_connecting = false;
    return 0;
}

static int read_into(struct endpoint *src, struct buffer *dst, struct endpoint *peer) {
    for (;;) {
        if (buffer_space(dst) == 0) buffer_compact(dst);
        if (buffer_space(dst) == 0) {
            src->want_read = false;
            return 0;
        }

        ssize_t n = read(src->fd, dst->data + dst->end, buffer_space(dst));
        if (n > 0) {
            dst->end += (size_t)n;
            peer->want_write = true;
            continue;
        }

        if (n == 0) {
            src->rd_open = false;
            src->want_read = false;
            if (buffer_len(dst) == 0) shutdown_wr(peer);
            return 0;
        }

        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }
}

static int flush_from(struct endpoint *dst, struct buffer *srcbuf, struct endpoint *src) {
    while (buffer_len(srcbuf) > 0) {
        ssize_t n = write(dst->fd, srcbuf->data + srcbuf->start, buffer_len(srcbuf));
        if (n > 0) {
            srcbuf->start += (size_t)n;
            continue;
        }

        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        return -1;
    }

    if (srcbuf->start == srcbuf->end) {
        srcbuf->start = 0;
        srcbuf->end = 0;
        dst->want_write = false;
        if (!src->rd_open) shutdown_wr(dst);
    } else {
        dst->want_write = true;
    }

    if (src->rd_open && !src->want_read && buffer_space(srcbuf) > 0) src->want_read = true;
    return 0;
}

static void sync_interest(struct conn *c) {
    if (c->client.rd_open && buffer_space(&c->to_backend) == 0) c->client.want_read = false;
    if (c->backend.rd_open && buffer_space(&c->to_client) == 0) c->backend.want_read = false;

    if (c->client.rd_open && buffer_space(&c->to_backend) > 0) c->client.want_read = true;
    if (!c->backend_connecting && c->backend.rd_open && buffer_space(&c->to_client) > 0) c->backend.want_read = true;

    c->client.want_write = c->client.wr_open && buffer_len(&c->to_client) > 0;
    c->backend.want_write = c->backend.wr_open && (c->backend_connecting || buffer_len(&c->to_backend) > 0);
}

static bool done_conn(const struct conn *c) {
    return !c->client.rd_open && !c->backend.rd_open && buffer_len(&c->to_client) == 0 && buffer_len(&c->to_backend) == 0;
}

static struct conn *new_conn(int cfd) {
    if (cfd < 0 || cfd >= MAX_TRACK_FD) {
        close(cfd);
        return NULL;
    }

    if (set_nonblock(cfd) != 0) {
        close(cfd);
        return NULL;
    }

    int one = 1;
    (void)setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    bool connecting = false;
    int bfd = connect_backend_nonblock(&connecting);
    if (bfd < 0 || bfd >= MAX_TRACK_FD) {
        close(cfd);
        if (bfd >= 0) close(bfd);
        return NULL;
    }

    struct conn *c = calloc(1, sizeof(*c));
    if (!c) {
        close(cfd);
        close(bfd);
        return NULL;
    }

    c->client.fd = cfd;
    c->client.rd_open = true;
    c->client.wr_open = true;
    c->client.want_read = true;

    c->backend.fd = bfd;
    c->backend.rd_open = true;
    c->backend.wr_open = true;
    c->backend_connecting = connecting;

    sync_interest(c);
    return c;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    int lfd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
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
    if (listen(lfd, 32768) != 0) {
        perror("listen");
        close(lfd);
        return 1;
    }

    int workers = worker_count();
    for (int i = 1; i < workers; i++) {
        pid_t p = fork();
        if (p == 0) break;
        if (p < 0) break;
    }

    int epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0) {
        perror("epoll_create1");
        close(lfd);
        return 1;
    }
    if (ep_add(epfd, lfd, EPOLLIN) != 0) {
        perror("epoll add lfd");
        close(epfd);
        close(lfd);
        return 1;
    }

    struct epoll_event events[MAX_EVENTS];
    for (;;) {
        int n = epoll_wait(epfd, events, MAX_EVENTS, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }

        for (int i = 0; i < n; i++) {
            int fd = events[i].data.fd;
            uint32_t ev = events[i].events;

            if (fd == lfd) {
                for (;;) {
                    int cfd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (cfd < 0) {
                        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) break;
                        break;
                    }

                    struct conn *c = new_conn(cfd);
                    if (!c) continue;

                    map_fd(c->client.fd, c, 0);
                    map_fd(c->backend.fd, c, 1);

                    if (ep_add(epfd, c->client.fd, events_for_ep(&c->client)) != 0 ||
                        ep_add(epfd, c->backend.fd, events_for_ep(&c->backend)) != 0) {
                        close_conn(epfd, c);
                        continue;
                    }
                }
                continue;
            }

            if (fd < 0 || fd >= MAX_TRACK_FD) continue;
            struct conn *c = fd_conn[fd];
            if (!c) continue;

            bool side_backend = fd_side[fd] == 1;
            struct endpoint *ep = side_backend ? &c->backend : &c->client;
            struct endpoint *peer = side_backend ? &c->client : &c->backend;

            if (side_backend && c->backend_connecting && (ev & (EPOLLOUT | EPOLLERR | EPOLLHUP))) {
                if (backend_connect_done(c) != 0) {
                    close_conn(epfd, c);
                    continue;
                }
                sync_interest(c);
            }

            if ((ev & EPOLLIN) && ep->rd_open) {
                int rc;
                if (side_backend) {
                    if (c->backend_connecting) {
                        rc = 0;
                    } else {
                        rc = read_into(&c->backend, &c->to_client, &c->client);
                    }
                } else {
                    rc = read_into(&c->client, &c->to_backend, &c->backend);
                }
                if (rc != 0) {
                    close_conn(epfd, c);
                    continue;
                }
            }

            if ((ev & EPOLLOUT) && ep->wr_open) {
                int rc;
                if (side_backend) {
                    if (c->backend_connecting) {
                        rc = 0;
                    } else {
                        rc = flush_from(&c->backend, &c->to_backend, &c->client);
                    }
                } else {
                    rc = flush_from(&c->client, &c->to_client, &c->backend);
                }
                if (rc != 0) {
                    close_conn(epfd, c);
                    continue;
                }
            }

            sync_interest(c);
            apply_interest(epfd, &c->client);
            apply_interest(epfd, &c->backend);

            if (done_conn(c)) close_conn(epfd, c);
        }
    }

    close(epfd);
    close(lfd);
    return 1;
}
