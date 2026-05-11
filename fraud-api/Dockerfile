FROM alpine:3.19 AS builder

RUN apk add --no-cache curl xz

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app
COPY src/main.zig src/http.zig src/router.zig src/payload.zig src/dataset.zig src/scorer.zig src/quantization.zig src/response.zig scripts/vector_indexer.zig scripts/pre-processing.sh ./

RUN chmod +x pre-processing.sh && ./pre-processing.sh || true

RUN zig build-exe main.zig -O ReleaseSmall -target aarch64-linux-musl -lc

FROM alpine:3.19

RUN apk add --no-cache watchexec curl

COPY --from=builder /app/main /app/main
COPY --from=builder /app/pre-processing.sh /app/pre-processing.sh

CMD ["watchexec", "-w", "/app/src", "-e", "zig", "--", "sh", "-c", "zig build-exe /app/src/main.zig -O ReleaseSmall -target aarch64-linux-musl -lc -femit-bin=/app/main && /app/main"]