FROM debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends g++ make
WORKDIR /build
COPY src/main.cpp .
RUN g++ -O3 -std=c++20 -static -o lb main.cpp

FROM gcr.io/distroless/cc-debian12
COPY --from=builder /build/lb /app/lb
EXPOSE 9999
ENTRYPOINT ["/app/lb"]
