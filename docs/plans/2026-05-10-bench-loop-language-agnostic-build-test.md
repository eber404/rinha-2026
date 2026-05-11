# Bench-Loop: Language-Agnostic Build & Test

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan.

**Goal:** Skill compila tudo, testa tudo, de forma agnóstica a linguagem. Falha em qualquer etapa = corrigir + repetir até passar.

**Architecture:**
Detecta diretórios com manifestos compiláveis. Fase A: compila cada um sequencialmente. Se falha, corrige e re-tenta até passar. Fase B: tenta comando de teste do manifest; se não existe ou falha, escaneia por arquivos `*_test.*` e roda com compilador/refator adequado. Loop não avança se compilação ou testes falham.

---

## Build Detection

Para cada subdir com manifest compilável (`build.zig`, `Makefile`, `package.json`, `Cargo.toml`, `go.mod`):

```bash
for subdir in fraud-api load-balancer preprocess; do
  if [ -f "$subdir/build.zig" ]; then
    (cd "$subdir" && zig build) || fail_and_retry
  elif [ -f "$subdir/Makefile" ]; then
    (cd "$subdir" && make) || fail_and_retry
  elif [ -f "$subdir/package.json" ]; then
    (cd "$subdir" && bun build 2>/dev/null || tsc --noEmit 2>/dev/null) || fail_and_retry
  elif [ -f "$subdir/Cargo.toml" ]; then
    (cd "$subdir" && cargo build) || fail_and_retry
  elif [ -f "$subdir/go.mod" ]; then
    (cd "$subdir" && go build ./...) || fail_and_retry
  fi
done
```

**Fail-and-retry:** Se comando retorna non-zero, guarda erro → invoca systematic-debugging → aplica fix → re-roda Fase A. Repetir até passar.

---

## Test Detection

Para cada subdir que passou na compilação:

```bash
# Try manifest test command first
if [ -f "$subdir/package.json" ]; then
  bun test 2>/dev/null || npm test 2>/dev/null || fallback_scan
elif [ -f "$subdir/Cargo.toml" ]; then
  cargo test 2>/dev/null || fallback_scan
elif [ -f "$subdir/build.zig" ]; then
  zig build 2>/dev/null || fallback_scan
fi

# Fallback: scan for *_test.* files
fallback_scan() {
  for f in "$subdir"/**/*_test.*; do
    [ -f "$f" ] && run_appropriate_test "$f"
  done
}

run_appropriate_test() {
  case "$f" in
    *.zig)    zig test "$f" ;;
    *.ts)     bun test "$f" 2>/dev/null || npx jest "$f" ;;
    *.rs)     cargo test --test "$f" ;;
    *.go)     go test "$f" ;;
    *)        echo "Unknown test file: $f" ;;
  esac
}
```

**Fail-and-retry:** Se qualquer teste falha, guarda erro → systematic-debugging → fix → re-roda Fase B. Repetir até todos passarem.

---

## Loop Constraint

```
Step 1 (Phase A + Phase B) pass → Step 2 (Docker)
Step 1 fail → loop in Step 1 until pass
No advancement to Docker/Benchmark if compile or test fails
```

---

## State Tracking

`.bench-state` updated after each run:
- `last_compile_error`, `last_test_error`: persisted per attempt
- `consecutive_failures`: resets on pass (compile or test)
- Failure hash tracking via problemHash(type, rootCause) for consecutive count