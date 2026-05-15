FROM oven/bun:canary AS builder
RUN apt-get update -qq && apt-get install -y -qq g++ make
WORKDIR /build
COPY native/ ./native/
RUN mkdir -p native/build && g++ -O3 -std=c++20 -fPIC -shared -o native/build/knn.so native/knn.cpp native/binding.cpp

FROM oven/bun:canary
WORKDIR /app
COPY package.json tsconfig.json bun.lock ./
COPY src/ ./src/
COPY --from=builder /build/native/build/knn.so ./native/build/knn.so
RUN bun install
EXPOSE 9999
CMD ["bun", "run", "src/index.ts"]
