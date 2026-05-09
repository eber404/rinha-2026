FROM oven/bun:1-debian AS builder

WORKDIR /app
COPY package.json ./
RUN bun install --frozen-lockfile

COPY src ./src
RUN bun build src/index.ts --target=bun --outdir=dist

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/dist /app

RUN mkdir -p /tmp/rinha

EXPOSE 9999

CMD ["./index"]