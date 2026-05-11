# Docker Hot-Reload — Bench-Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Criar docker-compose.dev.yml com hot reload via watchexec, simplificar Step 2 da skill para "ensure containers running".

**Tech Stack:** Docker, watchexec, Zig, Bun.

---

### Task 1: Create fraud-api/watch-zig.sh

**Files:**
- Create: `fraud-api/watch-zig.sh`

```bash
#!/bin/sh
echo $$ > /tmp/main.pid
watchexec -r -w /app/src -e zig -- \
  "zig build-exe main.zig -O ReleaseSmall -target aarch64-linux-musl -lc && kill -HUP $(cat /tmp/main.pid)"
```

---

### Task 2: Create load-balancer/watch-zig.sh

**Files:**
- Create: `load-balancer/watch-zig.sh`

```bash
#!/bin/sh
echo $$ > /tmp/main.pid
watchexec -r -w /app/src -e zig -- \
  "zig build-exe main.zig -O ReleaseSmall -target aarch64-linux-musl -lc && kill -HUP $(cat /tmp/main.pid)"
```

---

### Task 3: Modify fraud-api/Dockerfile — add watchexec

**Files:**
- Modify: `fraud-api/Dockerfile`

Add after `RUN apk add --no-cache curl xz`:
```
RUN apk add --no-cache watchexec
```

Change CMD to:
```
CMD ["sh", "/app/watch-zig.sh"]
```

Also ensure `watch-zig.sh` is copied from builder context.

---

### Task 4: Modify load-balancer/Dockerfile — add watchexec

**Files:**
- Modify: `load-balancer/Dockerfile`

Add after `RUN apk add --no-cache curl tar xz`:
```
RUN apk add --no-cache watchexec
```

Change CMD to:
```
CMD ["sh", "/app/watch-zig.sh"]
```

---

### Task 5: Create docker-compose.dev.yml

**Files:**
- Create: `docker-compose.dev.yml`

```yaml
services:
  fraud-api-1:
    build:
      context: ./fraud-api
      dockerfile: Dockerfile
    container_name: fraud-api-1
    environment:
      - INSTANCE_ID=1
      - UDS_PATH=/tmp/rinha/api-1.sock
      - DATA_DIR=/app/data
    volumes:
      - ./fraud-api/src:/app/src
      - rinha-sockets:/tmp/rinha
    networks:
      - rinha-net
    restart: on-failure
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: '128MB'

  fraud-api-2:
    build:
      context: ./fraud-api
      dockerfile: Dockerfile
    container_name: fraud-api-2
    environment:
      - INSTANCE_ID=2
      - UDS_PATH=/tmp/rinha/api-2.sock
      - DATA_DIR=/app/data
    volumes:
      - ./fraud-api/src:/app/src
      - rinha-sockets:/tmp/rinha
    networks:
      - rinha-net
    restart: on-failure
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: '128MB'

  load-balancer:
    build:
      context: ./load-balancer
      dockerfile: Dockerfile
    container_name: load-balancer
    ports:
      - "9999:9999"
    volumes:
      - ./load-balancer/src:/app/src
      - rinha-sockets:/tmp/rinha
    networks:
      - rinha-net
    restart: on-failure
    depends_on:
      - fraud-api-1
      - fraud-api-2
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: '94MB'

  preprocess:
    build:
      context: ./preprocess
      dockerfile: Dockerfile
    container_name: preprocess
    volumes:
      - ./preprocess/src:/app/src
    networks:
      - rinha-net
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: '256MB'

networks:
  rinha-net:
    driver: bridge

volumes:
  rinha-sockets:
```

---

### Task 6: Simplify bench-loop SKILL.md Step 2

**Files:**
- Modify: `/Users/eber/.config/opencode/skills/bench-loop/SKILL.md` — Step 2

Replace Step 2 content with:

```markdown
### Step 2 — Ensure Dev Containers Running (hot reload)

Use docker-compose.dev.yml which has hot reload enabled (watchexec + bun --watch).
No rebuild check needed — hot reload propagates code changes automatically.

```bash
# Start or ensure dev containers are running
docker compose -f docker-compose.dev.yml up -d

# If containers not running, this starts them
# Hot reload handles code changes — no manual rebuild needed
```

**If containers fail to start:** systematic-debugging → fix → retry.

**Advancement:** Proceed to Step 3 (Benchmark) after containers are up.
```

---

### Task 7: Commit all changes

```bash
git add docker-compose.dev.yml fraud-api/watch-zig.sh load-balancer/watch-zig.sh fraud-api/Dockerfile load-balancer/Dockerfile
git commit -m "feat: add docker hot-reload dev setup with watchexec"
```

---

**Plan complete.** Skill changes are all in `~/.config/opencode/skills/bench-loop/SKILL.md` (outside git repo). No repo code affected.

**Execution options:**

1. **Subagent-Driven** — I dispatch fresh subagent per task, review between tasks, fast iteration
2. **Parallel Session** — Open new session with executing-plans, batch execution with checkpoints

Which approach?