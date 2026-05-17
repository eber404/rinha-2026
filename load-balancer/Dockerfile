FROM gcc:13-bookworm AS builder
WORKDIR /build
COPY src/main.cpp .
RUN g++ -O3 -std=c++20 -static -pthread -o lb main.cpp

FROM gcr.io/distroless/cc-debian12
COPY --from=builder /build/lb /app/lb
EXPOSE 9999
ENTRYPOINT ["/app/lb"]
