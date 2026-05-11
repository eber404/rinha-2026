FROM alpine:3.19 AS builder

RUN apk add --no-cache curl tar xz

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app
COPY src/main.zig .

RUN zig build-exe main.zig -O ReleaseSmall -target aarch64-linux-musl -lc

FROM alpine:3.19

RUN apk add --no-cache watchexec

COPY --from=builder /app/main /app/main

EXPOSE 9999

CMD ["watchexec", "-w", "/app/src", "-e", "zig", "--", "zig", "build-exe", "/app/src/main.zig", "-O", "ReleaseSmall", "-target", "aarch64-linux-musl", "-lc", "-femit-bin=/app/main", "&&", "/app/main"]