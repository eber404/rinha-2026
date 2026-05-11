# Bench-Loop: TDD Integration for Bug Fixing

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:writing-plans to create implementation plan.

**Goal:** Após systematic-debugging identificar root cause, TDD valida o diagnóstico com failing test antes de implementar o fix — garantia que o bug foi realmente entendido.

**Architecture:**
systematic-debugging identifies root cause → TDD writes failing test to validate understanding → TDD implements minimal fix → return to Step 1. TDD language-agnóstico via manifest-driven (zig test / bun test / cargo test / go test).

**Flow:**
```
Step 5 (systematic-debugging):
  1. Root cause hypothesis
  2. TDD validates diagnosis (failing test)
  3. TDD implements minimal fix ← replaces "apply fix"
  4. Regression test → add to suite
  5. Verify fix → run tests → goto Step 1
```

**TDD invocation:**
After root cause hypothesis, before implementing fix — writes failing test matching the bug, runs it to confirm failure, then implements minimal code to pass. Language detection via manifest.