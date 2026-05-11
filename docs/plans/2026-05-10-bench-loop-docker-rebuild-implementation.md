# Docker Rebuild Redesign — Bench-Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Step 2 detecta changes per-service via manifest mtime, rebuilda só o serviço que mudou, falha → systematic-debugging → retry.

**Architecture:**
Rebuild per-service baseado em manifest mtime. `docker compose build` com cache (incremental). Falha → systematic-debugging → fix → retry.

**Tech Stack:** Bash snippets em SKILL.md.

---

### Task 1: Rewrite Step 2 (Docker Rebuild Check) in SKILL.md — per-service manifest-driven

**Files:**
- Modify: `/Users/eber/.config/opencode/skills/bench-loop/SKILL.md` — Step 2 section (lines ~159-171)

**Step 1: Read current Step 2**

**Step 2: Replace old Step 2 block**

Replace current content with:

```markdown
### Step 2 — Docker Rebuild Check (per-service, manifest-driven)

Detect which services need rebuild by comparing manifest mtimes vs last Docker build time.
Rebuild per-service using `docker compose build <service>`.
State: `last_docker_build` timestamp in `.bench-state`.

```bash
# Load last build time from .bench-state (default to 0 if not set)
LAST_BUILD="${LAST_DOCKER_BUILD:-0}"

# Per-service check and rebuild
if [ -f "fraud-api/build.zig" ] && [ "fraud-api/build.zig" -nt "@LAST_BUILD" ]; then
  echo "fraud-api source changed — rebuilding..."
  docker compose -f docker-compose.test.yml build fraud-api-1 fraud-api-2 \
    || { save_error "docker" "fraud-api"; return 1; }
fi

if [ -f "load-balancer/build.zig" ] && [ "load-balancer/build.zig" -nt "@LAST_BUILD" ]; then
  echo "load-balancer source changed — rebuilding..."
  docker compose -f docker-compose.test.yml build load-balancer \
    || { save_error "docker" "load-balancer"; return 1; }
fi

if [ -f "preprocess/package.json" ] && [ "preprocess/package.json" -nt "@LAST_BUILD" ]; then
  echo "preprocess source changed — rebuilding..."
  docker compose -f docker-compose.test.yml build preprocess \
    || { save_error "docker" "preprocess"; return 1; }
fi

# Update last build timestamp in .bench-state
update_last_docker_build
```

**If build fails:** systematic-debugging → fix → retry Docker build (loop until pass or intervention).

**If no manifest newer than last build:** skip rebuild, proceed to Step 3.
```

**Step 3: Verify edit looks correct**

**Step 4: Report back — no git commit needed (skill outside repo)**