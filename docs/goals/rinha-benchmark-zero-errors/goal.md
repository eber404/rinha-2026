# Rinha 2026 Benchmark to Zero Detection Errors

## Objective

Drive this repository to a rules-compliant benchmark result where `http_errors = 0`, `false_positive_detections = 0`, `false_negative_detections = 0`, and `failure_rate = 0%`, validated by local `make benchmark` runs.

## Original Request

Read the official challenge docs in `.cache/rinha-oficial/docs/br`, understand the current architecture and fraud detection flow, run `make benchmark`, diagnose root causes for `http_errors`, `false_positive_detections`, `false_negative_detections`, and `failure_rate`, then iteratively fix implementation issues with justified incremental changes until all target metrics are zero without hacks or rule violations.

## Intake Summary

- Input shape: `existing_plan`
- Audience: Rinha 2026 solution maintainers and benchmark evaluators
- Authority: `requested`
- Proof type: `metric`
- Completion proof: A local `make benchmark` run reports `http_errors=0`, `false_positive_detections=0`, `false_negative_detections=0`, and `failure_rate=0%`
- Likely misfire: Improving metrics by bypassing official semantics instead of fixing root-cause correctness and reliability
- Blind spots considered: benchmark stochastic behavior under load, race conditions in request path, and possible divergence between official fraud rules and current implementation assumptions
- Existing plan facts: Read official docs first; map architecture and request flow; benchmark baseline; diagnose all four target metrics; apply incremental fixes; rerun benchmark after relevant changes; continue until all metrics are zero; provide final objective summary

## Goal Kind

`existing_plan`

## Current Tranche

Validate and operationalize the provided plan, gather baseline evidence, execute the largest safe reversible fix slices that improve correctness and reliability under benchmark load, verify each slice, and continue until the full requested benchmark outcome is achieved.

## Non-Negotiable Constraints

- No hacks, benchmark bypasses, or hardcoded benchmark-specific outputs.
- Do not alter official challenge rules or remove validations to mask issues.
- Keep behavior compliant with official challenge semantics.
- Keep changes incremental, justified, and verifiable.

## Stop Rule

Stop only when a final audit proves the full original outcome is complete.

Do not stop after planning, discovery, or Judge selection if a safe Worker task can be activated.

Do not stop after one verified Worker slice if additional safe local slices are required to reach all target metrics.

## Slice Sizing

Safe means bounded, explicit, verified, and reversible. It does not mean tiny.

A good task is the largest safe useful slice.

## Canonical Board

Machine truth lives at:

`docs/goals/rinha-benchmark-zero-errors/state.yaml`

If this charter and `state.yaml` disagree, `state.yaml` wins.

## Run Command

```text
/goal Follow docs/goals/rinha-benchmark-zero-errors/goal.md.
```
