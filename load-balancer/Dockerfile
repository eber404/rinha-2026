FROM alpine:latest AS builder

RUN apk add --no-cache curl tar xz

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app
COPY src ./src
COPY build.zig ./build.zig
COPY build.zig.zon ./build.zig.zon
COPY tests ./tests

RUN rm -rf .zig-cache && zig build && chown -R 1000:1000 zig-out

FROM alpine:latest

RUN apk add --no-cache curl tar xz

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app

COPY --from=builder /app/zig-out/bin/load_balancer /app/main
COPY --from=builder /app/src ./src
COPY --from=builder /app/build.zig ./build.zig
COPY --from=builder /app/build.zig.zon ./build.zig.zon
COPY --from=builder /app/tests ./tests

EXPOSE 9999

CMD ["/app/main"]
