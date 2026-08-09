---
name: signalbox-preflight
description: Inspect exact Git scope, mandatory dependencies, ownership, authentication, worktree state, and remote readiness with Signalbox. Use before repository initialization, commits, pushes, releases, or any agent workflow that may be operating inside an unintended parent repository.
---

# Signalbox Preflight

Run read-only checks first:

```bash
signalbox doctor --json
signalbox analyze --target <path> --goal "<requested outcome>"
```

Treat `repository_scope` findings as blockers before staging files. Report the resolved root,
missing tools, current verdict, evidence, and `next_action`. Do not initialize, stage, or push while
performing preflight.
