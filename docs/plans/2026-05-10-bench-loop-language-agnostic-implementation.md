# Language-Agnostic Build & Test — Bench-Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bench-loop compila tudo sequencialmente por manifest, testa tudo por manifest+fallback, falha em qualquer etapa = loop até passar.

**Architecture:**
Detecta manifestos (`build.zig`, `Makefile`, `package.json`, `Cargo.toml`, `go.mod`). Fase A: compila cada dir sequencialmente. Fase B: tenta test command do manifest; fallback: escaneia `*_test.*`. Fail → systematic-debugging → fix → retry. Não avança enquanto compile ou test falhar.

**Tech Stack:** Bash snippets em SKILL.md, não projeto.

---

### Task 1: Rewrite Phase A (Compile) in SKILL.md — Language-agnostic, manifest-driven

**Files:**
- Modify: `/Users/eber/.config/opencode/skills/bench-loop/SKILL.md` — Step 1 Phase A section (lines ~77-96)

**Step 1: Write the new Phase A block**

Replace current Zig/Bun-specific compile block with:

```markdown
**Phase A: Compile all compilable modules (manifest-driven).**

For each subdir with a known build manifest, run the appropriate build command.
Fail-and-retry: if non-zero exit, invoke systematic-debugging, apply fix, re-run Phase A.
Continue only when all compiles pass.

```bash
# Detect and compile each language's project
for subdir in fraud-api load-balancer preprocess; do
  if [ -f "$subdir/build.zig" ]; then
    (cd "$subdir" && zig build) || { save_error "compile" "$subdir"; return 1; }
  elif [ -f "$subdir/Makefile" ]; then
    (cd "$subdir" && make) || { save_error "compile" "$subdir"; return 1; }
  elif [ -f "$subdir/package.json" ]; then
    (cd "$subdir" && bun build 2>/dev/null || tsc --noEmit 2>/dev/null) || { save_error "compile" "$subdir"; return 1; }
  elif [ -f "$subdir/Cargo.toml" ]; then
    (cd "$subdir" && cargo build) || { save_error "compile" "$subdir"; return 1; }
  elif [ -f "$subdir/go.mod" ]; then
    (cd "$subdir" && go build ./...) || { save_error "compile" "$subdir"; return 1; }
  fi
done
```

If any compile fails → systematic-debugging → fix → re-run Phase A (loop until pass).
```

**Step 2: Verify syntax**

Read back the section, ensure no broken markdown, correct for each manifest type.

**Step 3: Commit plan changes (no code commit needed — skill is outside repo)**

---

### Task 2: Rewrite Phase B (Test) in SKILL.md — Language-agnostic, manifest + fallback

**Files:**
- Modify: `/Users/eber/.config/opencode/skills/bench-loop/SKILL.md` — Step 1 Phase B section (lines ~98-121)

**Step 1: Write the new Phase B block**

Replace current Zig/Bun-specific test block with:

```markdown
**Phase B: Run all unit tests (manifest + fallback scan).**

For each subdir that passed Phase A:
1. Try the manifest's test command (e.g., `bun test`, `cargo test`, `zig build test`)
2. If no test command or it fails → fallback scan for `*_test.*` files and run with appropriate runner

```bash
for subdir in fraud-api load-balancer preprocess; do
  if [ -f "$subdir/package.json" ]; then
    (cd "$subdir" && bun test 2>/dev/null || npm test 2>/dev/null) || { save_error "test" "$subdir"; fallback_scan "$subdir"; }
  elif [ -f "$subdir/Cargo.toml" ]; then
    (cd "$subdir" && cargo test 2>/dev/null) || { save_error "test" "$subdir"; fallback_scan "$subdir"; }
  elif [ -f "$subdir/build.zig" ]; then
    # Zig: run test files directly
    for f in "$subdir"/src/*_test.zig "$subdir"/*_test.zig; do
      [ -f "$f" ] && (cd "$subdir" && zig test "$f") || { save_error "test" "$f"; }
    done
  elif [ -f "$subdir/go.mod" ]; then
    (cd "$subdir" && go test ./...) || { save_error "test" "$subdir"; fallback_scan "$subdir"; }
  else
    fallback_scan "$subdir"
  fi
done

fallback_scan() {
  subdir="$1"
  for f in "$subdir"/src/*_test.* "$subdir"/*_test.*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.zig)    (cd "$subdir" && zig test "$f") || { save_error "test" "$f"; } ;;
      *.ts)     (cd "$subdir" && bun test "$f" 2>/dev/null || npx jest "$f") || { save_error "test" "$f"; } ;;
      *.rs)     (cd "$subdir" && cargo test --test "$(basename $f)" 2>/dev/null) || { save_error "test" "$f"; } ;;
      *.go)     (cd "$subdir" && go test "$f") || { save_error "test" "$f"; } ;;
    esac
  done
}
```

If any test fails → systematic-debugging → fix → re-run Phase B (loop until pass).
```

**Step 2: Verify syntax**

Read back, ensure correct fallback logic and error handling.

**Step 3: No commit needed — skill outside repo**

---

### Task 3: Update "Fail → Repeat Step 1" rule to reflect Phase A + B loop

**Files:**
- Modify: `/Users/eber/.config/opencode/skills/bench-loop/SKILL.md` — line ~121 (currently says "If any build or test fails → fix code → repeat Step 1")

**Step 1: Clarify loop behavior**

Replace generic rule with specific loop constraints:

```markdown
**Loop constraint:**
- Phase A fails → systematic-debugging → fix → re-run Phase A until all compiles pass
- Phase B fails → systematic-debugging → fix → re-run Phase B until all tests pass
- Advancement to Step 2 (Docker) ONLY when both Phase A AND Phase B pass
```

---

### Task 4: Add `save_error` helper stub in SKILL.md (explained as pseudocode)

**Files:**
- Modify: `/Users/eber/.config/opencode/skills/bench-loop/SKILL.md` — add after "Failed Attempt Hashing" section

**Step 1: Document `save_error` pseudocode**

```markdown
## Helper Functions (Pseudocode)

```js
// Save error for systematic-debugging and state persistence
function save_error(phase, target) {
  // phase: "compile" | "test"
  // target: subdir or file that failed
  // 1. Store error message + target for systematic-debugging invocation
  // 2. Update .bench-state with last_{phase}_error
  // 3. Return non-zero exit to trigger fail-and-retry loop
}
```
```

---

**Plan complete.** Skill changes are all in `~/.config/opencode/skills/bench-loop/SKILL.md` (outside git repo). No repo code affected.

**Execution options:**

1. **Subagent-Driven** — I dispatch fresh subagent per task, review between tasks
2. **Parallel Session** — Open new session with executing-plans

Which approach?