# Ambiguous Head Baseline and Dataset Notes

Date: 2026-05-17
Status: Baseline captured for Task 1
Scope: Native ambiguous diagnostics + ambiguous dataset export + baseline benchmark

## Baseline benchmark metrics

Command:

```bash
make benchmark
```

Observed baseline:

- `p99`: `1.77ms`
- `http_errors`: `0`
- `false_positive_detections`: `581`
- `false_negative_detections`: `646`
- `failure_rate`: `2.27%`
- `weighted_errors_E`: `2519`
- `final_score`: `3063.08`

Error concentration is still entirely in fraud classification quality (FP/FN), not transport stability (`http_errors=0`).

## Ambiguous dataset export

Command:

```bash
python3 scripts/export_ambiguous_dataset.py
```

Generated artifact:

- `vector-index/ambiguous_samples.jsonl`

Schema per line:

- `id` (dataset row id)
- `label` (0=legit, 1=fraud)
- `features` (normalized vector length 14)
- `ivf_score_proxy` (cluster-level fraud ratio proxy)

Observed export totals:

- `rows_total`: `3000000`
- `ambiguous_exported`: `106848` (`3.56%` of dataset)
- `ambiguous_label_0`: `52685`
- `ambiguous_label_1`: `54163`

## Ambiguous error-distribution notes

- Ambiguous subset is near-balanced by class (`49.31%` legit / `50.69%` fraud), so a fixed threshold around the decision boundary is likely to be sensitive to small calibration shifts.
- Temporary runtime counters were added in `fraud-api/native/knn.cpp` for:
  - `amb_ivf_lt_04`
  - `amb_ivf_04_06`
  - `amb_ivf_gt_06`
- Export-side proxy binning currently concentrates in `<0.4`; this confirms the proxy is conservative/noisy and should be treated only as feature signal for offline head training, not as a calibrated probability.

## Task-1 safety checks

- `make test-native`: PASS
- `make benchmark`: PASS (with baseline error profile above)

## Task-4 rollout parity checks

Commands:

```bash
FRAUD_AMBIGUOUS_HEAD=off make benchmark
FRAUD_AMBIGUOUS_HEAD=on make benchmark
```

Observed parity results:

- `http_errors`: `0` in both runs
- `failure_rate`: `2.27%` in both runs
- `false_positive_detections`: `581` in both runs
- `false_negative_detections`: `646` in both runs
- `p99`: `1.81ms` (off) vs `1.79ms` (on)
- `final_score`: `3054.13` (off) vs `3058.65` (on)

Conclusion: rollout flag preserves correctness profile; enabled mode has equivalent errors and marginally better latency/score in this sample.

## Task-5 tuning loop (closed)

Iterations executed on `ambiguous_head` (offline train + benchmark):

1. **Weighted-error objective (fp*1 + fn*3), runtime-calibrated threshold**
   - Benchmark outcome: `failure_rate` regressed from `2.27%` to `2.31%`
   - FP increased materially while FN dropped sharply.

2. **Failure-count-oriented threshold candidate**
   - Benchmark outcome: `failure_rate` regressed to `2.36%`
   - Better weighted error than baseline but worse raw failure count.

3. **Re-validate best-known baseline with head disabled by default**
   - Benchmark outcome restored: `failure_rate=2.27%`, `http_errors=0`, `p99~1.80ms`

Stop rule applied: zero-error target not achieved after closed iterations; best-known production-safe configuration keeps ambiguous head **disabled by default** and preserves baseline behavior.
