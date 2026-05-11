FROM alpine:latest AS builder

RUN apk add --no-cache curl xz

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app
COPY src/ ./src/
COPY build.zig ./build.zig
COPY build.zig.zon ./build.zig.zon
COPY tests/ ./tests/
COPY scripts/pre-processing.sh ./pre-processing.sh

RUN rm -rf .zig-cache && ZIG_TARGET=x86_64-linux-musl zig build && chown -R 1000:1000 zig-out

FROM alpine:latest

RUN apk add --no-cache curl xz

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app

COPY --from=builder /app/zig-out/bin/fraud_api /app/main
COPY --from=builder /app/pre-processing.sh ./pre-processing.sh
COPY --from=builder /app/src ./src
COPY --from=builder /app/build.zig ./build.zig
COPY --from=builder /app/build.zig.zon ./build.zig.zon
COPY --from=builder /app/tests ./tests

CMD ["/app/main"]