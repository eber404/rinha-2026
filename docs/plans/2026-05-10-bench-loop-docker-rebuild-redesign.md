# Bench-Loop Docker Rebuild Redesign

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:writing-plans to create implementation plan.

**Goal:** Step 2 detecta changes per-service via manifest mtime, rebuilda só o serviço que mudou, falha → systematic-debugging → retry.

**Architecture:**
Rebuild per-service baseado em manifest mtime. `docker compose build` com cache (incremental). Falha → systematic-debugging → fix → retry.

**Rebuild logic (per-service):**
```bash
if [ fraud-api/build.zig newer than last_docker_build ]; then
  docker compose -f docker-compose.test.yml build fraud-api-1 fraud-api-2
fi
if [ load-balancer/build.zig newer ]; then
  docker compose build load-balancer
fi
if [ preprocess/package.json newer ]; then
  docker compose build preprocess
fi
```

**Cache behavior:** `docker compose build` usa cache por padrão. Só layers após `COPY` que mudou rebuildam.

**Failure → systematic-debugging:** Build falha → diagnóstico → correção → retry build. Loop até passar ou intervenção.