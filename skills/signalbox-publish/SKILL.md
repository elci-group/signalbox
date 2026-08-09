---
name: signalbox-publish
description: Create and apply digest-confirmed Signalbox publication plans for existing GitHub repositories. Use when initializing a standalone Git root, staging an exact file set, committing, or pushing while preventing parent-repository bleed, stale plans, force pushes, and remote-state races.
---

# Signalbox Publish

Create a read-only plan:

```bash
signalbox publish plan --target <path> --remote <owner/repo> --message "<message>" --out <plan.json>
```

Review its target, file list, remote, actions, and digest. Apply only after the user explicitly
confirms the exact digest:

```bash
signalbox publish apply --plan <plan.json> --confirm <sha256>
```

Never substitute a digest, create a missing remote, or weaken a stale-plan failure. The apply path
owns lease acquisition, heartbeat, exact staging, push, and remote verification.
