# Bench-Loop: Docker Hot-Reload Dev Setup

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:writing-plans to create implementation plan.

**Goal:** Criar docker-compose.dev.yml com hot reload via watchexec, simplificar Step 2 da skill para "ensure containers running".

**Architecture:**
- docker-compose.dev.yml com volumes mountados + watchexec/bun --watch
- Step 2 da skill: `docker compose -f docker-compose.dev.yml up -d` (sem rebuild check)
- Hot reload propaga mudanças automaticamente durante development

**Services:**

| Service | Watch Method | Command |
|---------|-------------|---------|
| fraud-api-1, fraud-api-2 | watchexec `-r -w /app/src -e zig` | rebuild + restart |
| load-balancer | watchexec `-r -w /app/src -e zig` | rebuild + restart |
| preprocess | bun `--watch` | live reload |

**Bootstrap:** Entrypoint.sh builds binary once before watchexec starts.

**Changes needed:**
- Create: `docker-compose.dev.yml`
- Create: `fraud-api/watch-zig.sh`, `load-balancer/watch-zig.sh`
- Modify: `fraud-api/Dockerfile`, `load-balancer/Dockerfile` (add watchexec)
- Modify: `fraud-api/entrypoint.sh`, `load-balancer/entrypoint.sh` (PID file + bootstrap)
- Modify: bench-loop SKILL.md Step 2 (simplify to ensure running)