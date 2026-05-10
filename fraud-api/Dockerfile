FROM alpine:3.19 AS builder

RUN apk add --no-cache curl xz

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app
COPY src/main.zig src/http.zig src/router.zig src/payload.zig src/dataset.zig src/scorer.zig src/quantization.zig src/response.zig ./

RUN zig build-exe main.zig -O ReleaseSmall -target aarch64-linux-musl -lc

FROM alpine:3.19

RUN mkdir -p /tmp/rinha

COPY --from=builder /app/main /app/main
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]