---
name: signalbox-audit
description: Run Signalbox's complete deterministic analyzer and guardrail suite over a repository and produce structured evidence. Use for release readiness, agent-control-plane audits, security reviews, architecture checks, or when a compact next action should replace repeated model deliberation.
---

# Signalbox Audit

Run the complete read-only suite:

```bash
signalbox suite --target <path> --goal "<goal>" [--claim <file>] [--trace <file>]
```

Use JSON results as the source of truth. Distinguish `not_applicable` from `pass`; never imply that
a language-specific analyzer inspected unsupported code. Inspect artifacts named by findings, then
act on the single `next_action` without bypassing failed gates.
