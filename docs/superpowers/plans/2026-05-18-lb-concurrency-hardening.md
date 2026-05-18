# LB Concurrency Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce load balancer thread/FD pressure by replacing per-direction relay threads with a single bidirectional pump while preserving pure transport behavior and benchmark stability.

**Architecture:** Keep round-robin backend selection and zero business logic unchanged. Replace `c2b`/`b2c` thread pair with one full-duplex relay loop using `poll()` over both sockets. Keep per-connection acceptance model to preserve concurrency under benchmark load.

**Tech Stack:** C++20, Linux sockets (`poll`, `shutdown`, `accept`), std::thread, mutex/condition_variable, docker-compose benchmark.

---

### Task 1: Introduce single-thread bidirectional relay

**Files:**
- Modify: `load-balancer/src/main.cpp`

- [ ] Replace the dual-thread relay model with one `relay_bidirectional(client_fd, backend_fd)` function that forwards both directions in a single loop using `poll()`.
- [ ] Keep half-close semantics: on EOF/error from one side, `shutdown(peer, SHUT_WR)` and continue draining other side until both close.
- [ ] Keep buffer writes robust to partial writes and EINTR.

### Task 2: Evaluate bounded queue + worker pool (rejected)

**Files:**
- Modify: `load-balancer/src/main.cpp`

- [x] Prototype fixed-size worker pool and bounded accepted-fd queue.
- [x] Validate under benchmark and record impact.
- [x] Revert prototype due severe `http_errors`/`p99` regression in this environment.

### Task 3: Keep backend selection logic and improve robustness

**Files:**
- Modify: `load-balancer/src/main.cpp`

- [ ] Preserve existing round-robin `connect_backend()` semantics.
- [ ] Ensure SIGPIPE remains ignored.
- [ ] Ensure all fds are closed in all failure paths.

### Task 4: Build and verify

**Files:**
- Modify: `Makefile` (only if needed; expected no change)

- [ ] Build LB: `make lb`
- [ ] Rebuild and run stack cleanly: `docker compose down -v && docker compose up --build -d`
- [ ] Confirm readiness: `curl -s http://localhost:9999/ready` returns `OK`
- [ ] Run benchmark: `make benchmark`
- [ ] Record `p99`, `http_errors`, `failure_rate`, `final_score` in final report.

### Execution notes

- Worker-pool prototype caused major benchmark degradation (`p99` ~2002ms, `http_errors` > 12k) and was intentionally not kept.
- Single-thread bidirectional relay with detached per-connection handling restored stable results (`p99` ~1.51ms, `http_errors` 0).

### Task 5: Commit and push

**Files:**
- Modify: `load-balancer/src/main.cpp`
- Modify: `docs/superpowers/plans/2026-05-18-lb-concurrency-hardening.md`

- [ ] Commit with focused message for LB concurrency hardening.
- [ ] Push `chore/bun`.
