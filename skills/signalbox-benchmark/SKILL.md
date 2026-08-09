---
name: signalbox-benchmark
description: Benchmark Signalbox orchestration latency, determinism, and the full GPT-5.6 guardrail combination matrix. Use after control-plane changes, before releases, or when measuring whether deterministic routing reduces context and safety failures without excessive overhead.
---

# Signalbox Benchmark

Run the reproducible benchmark:

```bash
signalbox benchmark --iterations 30 --output <directory>
```

Inspect `result.json`, the Hyperfine timings, and GPT-5.6 benchmark report. Compare normalized
results rather than timestamps. Treat new safety violations, false positives, or nondeterministic
outputs as release blockers.
