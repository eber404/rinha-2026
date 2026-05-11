# Bench-Loop: Failed Attempt Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Modificar o bench-loop para só contar "failed attempt" quando o mesmo problema (tipo+erro raiz) acontecer N vezes seguidas, pedindo intervenção apenas neste cenário.

**Architecture:** 
- Persiste no `.bench-state`: tipo de falha, hash do root cause da última run, contador consecutive_failures.
- Incrementa consecutive_failures só quando problema idêntico ocorre em duas runs seguidas.
- Ao passar ou trocar de problema: zera o contador.
- Aciona intervenção humana se consecutive_failures chega ao limite (default 10).

**Tech Stack:**
- Bun/NodeJS/Bash scripts (bench-loop)
- JSON para `.bench-state`
- SHA-1 ou hash semelhante para root cause

---

### Task 1: Preparar função de hashing para root cause

**Files:**
- Editar: `.config/opencode/skills/bench-loop/SKILL.md` (pseudocódigo ES6/Bun ou shell)

**Passos:**
1. Especificar função/método para gerar hash curto (tipo+root cause).
2. Adicionar exemplo no design ou anotar dependência.

---

### Task 2: Atualizar JSON de estado (`.bench-state`)

**Files:**
- Editar: `.bench-state` (runtime), specs documentadas em SKILL.md

**Passos:**
1. Adicionar campos `last_failure_type`, `last_failure_hash`, `consecutive_failures` ao schema (na docs e validadores).
2. Ajustar persistência na etapa de falha do loop.

---

### Task 3: Implementar lógica de tracking no loop principal

**Files:**
- Editar: `.config/opencode/skills/bench-loop/SKILL.md` (ref. Step 5, Step 6 no documento atual)

**Passos:**
1. Modificar fluxo:
    - Se run PASS: zera consecutive_failures.
    - Se run FAIL: calcula hash(type+root), compara com anterior:
        - Igual: consecutive_failures++.
        - Diferente: consecutive_failures = 1.
    - Persistir.
2. Identificar como extrair "root cause" do systematic-debugging (primeira linha/detalhe-chave).

---

### Task 4: Acionar intervenção conforme limite

**Files:**
- Editar: `.config/opencode/skills/bench-loop/SKILL.md`

**Passos:**
1. Na checagem, se consecutive_failures ≥ max-attempts, dispara mensagem completa (tipo, root cause, count, caminho do artefato).
2. Atualizar docs para refletir nova regra.

---

### Task 5: Testar com falhas alternadas, falha recorrente, e correção

**Files:**
- Testar: logs, outputs dos runs demo, alterar manualmente root cause para simular alternância/recorrência

**Passos:**
1. Simular runs alternando erros e mantendo mesmo erro.
2. Checar .bench-state e logs.
3. Validar que só quando problema idêntico se repete 10x ocorre intervenção.
4. Documentar comportamento observado.

---

### Task 6: Commit e documentar mudanças

**Files:**
- Commit plan e código ajustado.

**Passos:**
1. `git add docs/plans/2026-05-10-bench-loop-failed-attempt-redesign.md .config/opencode/skills/bench-loop/SKILL.md`
2. `git commit -m "feat(bench-loop): failed attempt counter only increments on repeated identical problems"`
