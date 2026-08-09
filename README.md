# Signalbox

Signalbox is deterministic interlocking for agent workflows. It discovers the real repository
scope, checks authority and evidence, runs the available analysis control plane, and emits one
compact next action. It uses Bash and JSON rules for control decisions; it does not ask a model
whether a mutation is safe.

## State machine

```text
discovered → scoped → locked → authenticated → analyzed → verified
                                                      ↓
remote_verified ← pushed ← committed ← confirmed ← planned
```

A failed gate enters a blocked state with evidence. Turnsignal can render the recommendation but
cannot clear a failed gate.

## Commands

```bash
signalbox doctor --json
signalbox analyze --target . --goal "Review this repository"
signalbox suite --target . --goal "Verify this release"
signalbox verify --run ~/.local/state/signalbox/runs/<run-id>
signalbox benchmark --iterations 30
```

Publication is deliberately two-step. Planning is read-only and produces a canonical SHA-256
digest. Apply revalidates every precondition and requires that exact digest:

```bash
signalbox publish plan \
  --target . \
  --remote elci-group/example \
  --message "feat: initial release" \
  --out /tmp/publish-plan.json

signalbox publish apply \
  --plan /tmp/publish-plan.json \
  --confirm <digest-from-plan>
```

Apply only targets an existing GitHub repository. It refuses stale plans, force pushes, unrelated
origins, broad staging, and changed remote state. A Locksmith lease is heartbeated during the
operation, and the remote commit is verified after push.

## Analysis model

`doctor` requires the complete toolchain. `analyze` runs Bash syntax and ShellCheck, repository and
delivery checks, adversarial-input scanning, least-privilege routing, intent fencing, divergent
review, and project-specific analyzers. Rust-only tools such as Amber, Traci, and Boar emit a typed
`not_applicable` result for a Bash project; they are never reported as having analyzed unsupported
source. Potentially stateful analyzers run against disposable snapshots.

Raw evidence lives under `${XDG_STATE_HOME:-~/.local/state}/signalbox`. Stable normalized baseline
summaries may be committed under `reports/`; credentials, raw logs, timestamps, and caches are not.

## Install

```bash
./install.sh
./install.sh --deps          # show the supported dependency plan
./install.sh --deps --yes    # explicitly execute it with apt-get
```

The normal installation places the CLI in `~/.local/bin`, runtime files in
`~/.local/share/signalbox`, and the Codex plugin in `~/plugins/signalbox`. It also adds Signalbox to
the personal Codex marketplace when the official plugin helper is available.

## Development

```bash
bash -n bin/signalbox lib/signalbox.sh install.sh scripts/bats-relocatable tests/test.sh bench/run.sh
shellcheck bin/signalbox lib/signalbox.sh install.sh scripts/bats-relocatable tests/test.sh bench/run.sh
bash tests/test.sh
bats tests/signalbox.bats
deliver --spec deliver.toml --strict
```

The benchmark combines Hyperfine timing with the 32-configuration GPT-5.6 guardrail benchmark and
writes machine-readable evidence to the selected output directory.

## Monitoring

Kaptaind monitors the repository with `deliver --spec deliver.toml --strict` as its mandatory
pre-commit gate. Automatic pushes remain disabled. Inspect it with:

```bash
kaptaind-cli -r /home/sal/signalbox status
```
