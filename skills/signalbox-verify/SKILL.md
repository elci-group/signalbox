---
name: signalbox-verify
description: Verify completion claims against Signalbox traces, analyzer evidence, repository artifacts, Verify Chain, and GPT-5.6 Guard. Use before claiming that code is fixed, checks passed, a release is ready, or a publication succeeded.
---

# Signalbox Verify

Verify an existing analysis run:

```bash
signalbox verify --run <run-directory> [--goal "<goal>"] [--claim <claim-file>]
```

Require both Verify Chain and GPT-5.6 Guard to succeed. Report their exit codes and evidence
artifacts. Do not convert an unsupported check, missing artifact, or blocked guardrail into success.
