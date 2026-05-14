FROM debian:bookworm-slim

WORKDIR /app
COPY fraud-api-go/main /app/main
COPY fraud-api/vector-index /data/vector-index

ENV GOMAXPROCS=1
ENV INSTANCE_ID=1
ENV API_WORKERS=1

CMD ["/app/main"]