# Bench-Loop: Auto-Commit After Fix

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:writing-plans to create implementation plan.

**Goal:** Commitar e pushar após qualquer bug ser corrigido ou benchmark passar — garante que cada fix está versionado e no remote antes de continuar.

**Trigger:**
- Fix aplicado via systematic-debugging → commit + push
- Benchmark passa → commit + push

**Format:**
```
fix({dir}): {one-line description of what was fixed}
```

**Constraint:** Push falha = skill pausa, pede intervenção humana.