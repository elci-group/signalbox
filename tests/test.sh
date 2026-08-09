#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN=$ROOT/bin/signalbox
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

ok() { printf 'ok %d - %s\n' "$((PASS+FAIL+1))" "$1"; PASS=$((PASS+1)); }
not_ok() { printf 'not ok %d - %s\n' "$((PASS+FAIL+1))" "$1"; FAIL=$((FAIL+1)); }
assert() { local name=$1; shift; if "$@"; then ok "$name"; else not_ok "$name"; fi; }

assert 'version is stable' test "$(SIGNALBOX_HOME=$ROOT "$BIN" --version)" = 'signalbox 0.1.0'
assert 'help names publish plan' bash -c "SIGNALBOX_HOME='$ROOT' '$BIN' --help | grep -q 'publish plan'"

mkdir -p "$TMP/parent/child"
git -C "$TMP/parent" init -q -b main
printf '#!/usr/bin/env bash\necho safe\n' >"$TMP/parent/child/a.sh"
chmod +x "$TMP/parent/child/a.sh"

stub_dir=$TMP/stubs
mkdir -p "$stub_dir"
while IFS='|' read -r tool _ _; do
  [[ -z $tool || $tool == \#* || $tool == bash || $tool == jq || $tool == git || $tool == sha256sum || $tool == timeout || $tool == tar ]] && continue
  printf '#!/usr/bin/env bash\nprintf '\''{"ok":true}\n'\''\n' >"$stub_dir/$tool"
  chmod +x "$stub_dir/$tool"
done <"$ROOT/config/tools.txt"

report=$TMP/report.json
set +e
PATH="$stub_dir:$PATH" SIGNALBOX_HOME=$ROOT SIGNALBOX_STATE_DIR=$TMP/state "$BIN" analyze \
  --target "$TMP/parent/child" --goal 'Inspect this repository' >"$report"
rc=$?
set -e
assert 'parent repository bleed produces findings exit' test "$rc" -eq 2
assert 'parent repository bleed is identified' jq -e '.analyzers[] | select(.name == "repository_scope" and .status == "finding")' "$report"

mkdir -p "$TMP/project"
printf 'hello\n' >"$TMP/project/file.txt"
fingerprint_before=$(SIGNALBOX_HOME=$ROOT bash -c 'source "$SIGNALBOX_HOME/lib/signalbox.sh"; sb_fingerprint "$1"' _ "$TMP/project")
printf 'changed\n' >>"$TMP/project/file.txt"
fingerprint_after=$(SIGNALBOX_HOME=$ROOT bash -c 'source "$SIGNALBOX_HOME/lib/signalbox.sh"; sb_fingerprint "$1"' _ "$TMP/project")
assert 'fingerprints change with content' test "$fingerprint_before" != "$fingerprint_after"

base=$(jq -n '{kind:"signalbox_publish_plan",target:"/tmp/x"}')
digest=$(jq -cS . <<<"$base" | sha256sum | awk '{print $1}')
assert 'plan digest is canonical' test ${#digest} -eq 64

if ((FAIL)); then
  printf '1..%d\n%d tests failed\n' "$((PASS+FAIL))" "$FAIL"
  exit 1
fi
printf '1..%d\nAll %d tests passed\n' "$PASS" "$PASS"
