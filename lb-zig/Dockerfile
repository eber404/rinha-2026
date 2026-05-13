FROM ziglings/ziglang:latest AS builder

WORKDIR /src
COPY lb-zig/src ./src
RUN mkdir -p /out && zig build-exe src/main.zig -O ReleaseFast -target x86_64-linux-musl -femit-bin=/out/lb-zig

FROM alpine:3.21
COPY --from=builder /out/lb-zig /usr/local/bin/lb-zig
EXPOSE 9999
CMD ["/usr/local/bin/lb-zig"]
