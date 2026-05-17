# Optimize Rinha 2026 Benchmark E2E

## What did the user originally ask for?

Execute and optimize the E2E benchmark for this repository until it meets strict performance and correctness targets.

## What are we trying to improve?

Current benchmark results:
- p99: 183.65ms
- failure_rate: 2.23%
- http_errors: 0
- final_score: 1077.53

Target benchmark results:
- p99: < 5ms
- failure_rate: 0%
- http_errors: 0

## Input shape

existing_plan

## Constraints

- Non-goals: changing business rules to "trick" the benchmark, removing required validations, hiding errors in logs, altering benchmark criteria, breaking Docker Compose or Makefile compatibility.
- Must preserve correctness: fraud detection logic must remain aligned with official rules.
- Must preserve architecture: C++ LB, Bun API, C++ addon.
- Benchmark must be the official Rinha test (`make benchmark`).
- Prioritize functional correctness first, then latency.

## Authority

approved

## Proof type

metric

## Completion proof

`make benchmark` produces results.json with:
- `http_errors` == 0
- `failure_rate` == "0%"
- `p99` < "5ms"

## Likely misfire

Optimizing only latency while ignoring the 2.23% failure rate (false positives/negatives from approximate KNN), or overfitting to the test dataset by changing detection rules.

## Blind spots

- The reduced dataset (10%) may be the cause of the 2.23% failure rate. Reverting to full dataset or tuning IVF nprobe may fix detection but hurt latency.
- Bun FFI overhead may be a latency bottleneck.
- Docker CPU limits (0.35 per API) may make sub-5ms p99 impossible without algorithmic improvements.
- The LB poll() loop may introduce latency under high concurrency.

## Existing plan facts

User-provided process:
1. Execute `make benchmark`.
2. Inspect generated files in `.benchmark`.
3. Identify bottlenecks, HTTP errors, rule failures, or p99 slowness.
4. Apply fixes to code, config, Docker, Makefile, or scripts.
5. Run `make benchmark` again.
6. Repeat until targets are reached or no more obvious safe improvements remain.

## Goal classification

specific

## Current tranche

Discover the highest-leverage optimizations, complete successive safe verified work packages, review only at risk or phase boundaries, and keep advancing until benchmark targets are reached or the marginal gain of the next optimization is too low.
