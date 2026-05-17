# KNN Divergence Results

Date: 2026-05-17
Scope: Offline measurement of runtime IVF/direct-rule decisions against exact KNN k=5 on legal reference artifacts.

## Commands

```bash
make test-divergence
make measure-divergence
make measure-divergence-ambiguous
mkdir -p artifacts && /tmp/measure_knn_divergence --data-dir vector-index --samples 500 --stride 15485863 --only-ambiguous --output artifacts/knn_divergence_ambiguous_500.jsonl
mkdir -p artifacts && /tmp/measure_knn_divergence --data-dir vector-index --samples 500 --stride 15485863 --output artifacts/knn_divergence_samples_500.jsonl
```

Artifacts written:

- `artifacts/knn_divergence_samples.jsonl`
- `artifacts/knn_divergence_ambiguous.jsonl`
- `artifacts/knn_divergence_ambiguous_500.jsonl`
- `artifacts/knn_divergence_samples_500.jsonl`

## Overall 200-Sample Snapshot

```txt
samples=200
direct_clear=193
direct_clear_exact_disagree=0
ambiguous=7
ivf_exact_score_disagree=4
ivf_exact_decision_disagree=2
runtime_exact_decision_disagree=3
boundary_04=4
boundary_06=1
```

Interpretation: direct clear rules were zero-disagreement in this sample. Overall divergence is concentrated in the small ambiguous slice.

## Overall 500-Sample Snapshot

```txt
samples=500
direct_clear=481
direct_clear_exact_disagree=0
ambiguous=19
ivf_exact_score_disagree=15
ivf_exact_decision_disagree=10
runtime_exact_decision_disagree=6
boundary_04=7
boundary_06=3
only_ambiguous=false
```

Interpretation: direct-rule disagreement still did not appear. Among 19 ambiguous samples, IVF/exact decision divergence appeared in 10 cases, and runtime boundary mapping disagreed with exact in 6 cases.

## Ambiguous-Only 200-Sample Snapshot

```txt
samples=200
direct_clear=0
direct_clear_exact_disagree=0
ambiguous=200
ivf_exact_score_disagree=148
ivf_exact_decision_disagree=101
runtime_exact_decision_disagree=86
boundary_04=51
boundary_06=62
only_ambiguous=true
```

Interpretation: ambiguous-path IVF is the dominant approximation gap. Boundary mapping improves some cases versus raw IVF (`101 -> 86` decision disagreements), but still leaves high divergence.

## Ambiguous-Only 500-Sample Snapshot

```txt
samples=500
direct_clear=0
direct_clear_exact_disagree=0
ambiguous=500
ivf_exact_score_disagree=363
ivf_exact_decision_disagree=245
runtime_exact_decision_disagree=237
boundary_04=147
boundary_06=147
only_ambiguous=true
```

Interpretation: on ambiguous legal-reference samples, raw IVF decision disagreement is roughly `49.0%` and runtime-mapped decision disagreement is roughly `47.4%` against exact KNN. The current `NPROBE=8` IVF fallback is not a faithful proxy for exact KNN in the ambiguous slice.

## Next Tuning Target

The next legal zero-detection attempt should target ambiguous fallback fidelity, not direct rules.

Recommended next experiments:

1. Add an offline sweep for `nprobe` over ambiguous-only samples (`8`, `16`, `32`, `64`, `128`) and measure `runtime_exact_decision_disagree` plus estimated candidate counts.
2. Build a boundary micro-index or second-stage exact search over only nearby clusters for ambiguous rows where `ivf_score` is `0.2`, `0.4`, `0.6`, or `0.8`.
3. Keep direct-rule mining conservative; this measurement found `direct_clear_exact_disagree=0` in both overall snapshots.

Do not use preview `test-data.json` payloads for lookup or calibration. All measurements above use legal reference artifacts only.
