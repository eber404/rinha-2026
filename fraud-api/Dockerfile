FROM oven/bun:1-debian

WORKDIR /app
COPY package.json ./
RUN bun install --frozen-lockfile

COPY src ./src

CMD ["bun", "src/index.ts"]