FROM ubuntu:24.04 AS zig-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /workspace
COPY fraud-engine/src/ ./fraud-engine/src/
RUN zig build-lib fraud-engine/src/ffi.zig -target aarch64-linux-musl -O ReleaseFast -femit-bin=/workspace/libzigscore.a

FROM golang:1.22-bookworm AS go-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY api/go.mod ./go.mod
COPY api/cmd ./cmd
COPY api/internal ./internal
COPY --from=zig-builder /workspace/libzigscore.a /app/internal/zigcore/libzigscore.a
RUN CGO_ENABLED=1 go build -o /app/server ./cmd/server

FROM debian:bookworm-slim

WORKDIR /app
COPY --from=go-builder /app/server /app/server
CMD ["/app/server"]
