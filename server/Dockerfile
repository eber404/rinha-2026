FROM alpine:latest AS zig-builder

RUN apk add --no-cache curl xz
RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /workspace
COPY fraud-engine/src/ ./fraud-engine/src/
COPY fraud-api/src/ ./fraud-api/src/
RUN zig build-lib fraud-engine/src/ffi.zig -target x86_64-linux-musl -O ReleaseFast -femit-bin=/workspace/libzigscore.a

FROM golang:1.22-alpine AS go-builder

RUN apk add --no-cache build-base
WORKDIR /app
COPY server/go.mod ./go.mod
COPY server/cmd ./cmd
COPY server/internal ./internal
COPY --from=zig-builder /workspace/libzigscore.a /app/internal/zigcore/libzigscore.a
RUN CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -o /app/server ./cmd/server

FROM alpine:latest

WORKDIR /app
COPY --from=go-builder /app/server /app/server
CMD ["/app/server"]
