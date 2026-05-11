# Auto-Commit After Fix — Bench-Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Adicionar commit+push após qualquer fix ou benchmark passar — garante que cada correção está versionada e no remote antes de continuar.

**Architecture:**
Trigger: fix via systematic-debugging OU benchmark passou → `git add . && git commit -m "fix({dir}): {desc}" && git push`. Push falha = skill pausa e pide intervenção.

**Tech Stack:** Bash snippets em SKILL.md.

---

### Task 1: Add Auto-Commit Step to SKILL.md

**Files:**
- Modify: `/Users/eber/.config/opencode/skills/bench-loop/SKILL.md` — add new step after Step 5 (Correction), or integrate into Step 5/6

**Step 1: Read SKILL.md around Step 5/6 and Intervention section (lines ~260-290)**

**Step 2: Add "After Fix Applied" commit+push block**

In Step 5 (or new Step 6), after the systematic-debugging fix is applied, add:

```markdown
### Step 5.5 — Auto-Commit After Fix

After any fix is applied (via systematic-debugging) AND after benchmark passes:

```bash
git add .
git commit -m "fix({dir}): {one-line description of what was fixed}"
git push || { echo "Push failed — human intervention required"; exit 1; }
```

Where `{dir}` is the subdir that changed (e.g., `fraud-api`, `load-balancer`, `preprocess`).
If push fails → skill stops and requests human intervention before continuing.

**After benchmark passes:**
Also run the same commit+push sequence to record the successful state.
```

**Step 3: Verify edit looks correct**

**Step 4: Report back — no git commit needed (skill outside repo)**

---

**Plan complete.** Execution: Subagent-Driven or Parallel Session.