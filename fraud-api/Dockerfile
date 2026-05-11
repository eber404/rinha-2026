FROM alpine:latest AS builder

RUN apk add --no-cache curl xz

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app
COPY src/* scripts/* ./

RUN chmod +x pre-processing.sh && ./pre-processing.sh || true

RUN zig build-exe main.zig -O ReleaseSmall -target aarch64-linux-musl -lc

FROM alpine:latest

RUN apk add --no-cache curl xz

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app

COPY --from=builder /app/main /app/main
COPY --from=builder /app/pre-processing.sh /app/pre-processing.sh

CMD ["/app/main"]

