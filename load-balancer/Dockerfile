FROM alpine:3.19 AS builder

RUN apk add --no-cache zig

WORKDIR /app
COPY src ./src
COPY build.zig build.zig.zon ./

RUN zig build-exe src/main.zig -O ReleaseSmall

FROM scratch

COPY --from=builder /app/main /load-balancer

EXPOSE 9999

ENTRYPOINT ["/load-balancer"]