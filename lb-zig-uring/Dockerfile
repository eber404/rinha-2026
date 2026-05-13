FROM alpine:3.20 AS builder
RUN apk add --no-cache curl xz
RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /src
COPY lb-zig-uring/src/main.zig ./src/main.zig
RUN mkdir -p /out && zig build-exe src/main.zig -O ReleaseFast -target x86_64-linux-musl -femit-bin=/out/lb-zig

FROM alpine:3.20
COPY --from=builder /out/lb-zig /usr/local/bin/lb-zig
EXPOSE 9999
CMD ["/usr/local/bin/lb-zig"]
