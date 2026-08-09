#!/usr/bin/env bats

setup() {
  export ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SIGNALBOX_HOME=$ROOT
  export SIGNALBOX_STATE_DIR=$BATS_TEST_TMPDIR/state
}

@test "version reports the release" {
  run "$ROOT/bin/signalbox" --version
  [ "$status" -eq 0 ]
  [ "$output" = "signalbox 0.1.0" ]
}

@test "unknown commands are configuration errors" {
  run "$ROOT/bin/signalbox" no-such-command
  [ "$status" -eq 3 ]
}

@test "publish apply rejects a bad digest before mutation" {
  plan=$BATS_TEST_TMPDIR/plan.json
  jq -n '{digest:"expected"}' >"$plan"
  run "$ROOT/bin/signalbox" publish apply --plan "$plan" --confirm wrong
  [ "$status" -eq 4 ]
}
