FROM ziglings/ziglang:latest AS builder

WORKDIR /workspace
COPY fraud-api/src/ ./fraud-api/src/
RUN mkdir -p /out && \
    zig build-exe fraud-api/src/main.zig -O ReleaseFast -target x86_64-linux-musl -femit-bin=/out/fraud-api

FROM alpine:3.21
WORKDIR /app
COPY --from=builder /out/fraud-api /app/fraud-api
CMD ["/app/fraud-api"]
