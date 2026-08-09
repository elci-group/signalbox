#!/usr/bin/env bash

SIGNALBOX_VERSION=0.1.0
SIGNALBOX_SCHEMA=1
SIGNALBOX_EXIT_FINDINGS=2
SIGNALBOX_EXIT_CONFIG=3
SIGNALBOX_EXIT_STALE=4
SIGNALBOX_EXIT_ACTION=5

sb_usage() {
  cat <<'USAGE'
Signalbox — deterministic agent workflow interlocking

Usage:
  signalbox doctor [--json]
  signalbox analyze --target PATH --goal TEXT [--claim FILE] [--trace FILE]
  signalbox suite --target PATH --goal TEXT [--claim FILE] [--trace FILE]
  signalbox verify --run RUN_DIR [--goal TEXT] [--claim FILE]
  signalbox publish plan --target PATH --remote OWNER/REPO --message TEXT --out FILE
  signalbox publish apply --plan FILE --confirm SHA256
  signalbox benchmark [--iterations N] [--output DIR]

Exit codes: 0 ready, 2 findings, 3 configuration, 4 stale plan, 5 action failed.
USAGE
}

sb_die() {
  local code=$1
  shift
  printf 'signalbox: %s\n' "$*" >&2
  return "$code"
}

sb_require_arg() {
  local flag=$1 value=${2:-}
  [[ -n $value ]] || sb_die "$SIGNALBOX_EXIT_CONFIG" "$flag requires a value"
}

sb_realpath() {
  realpath -e -- "$1" 2>/dev/null || return "$SIGNALBOX_EXIT_CONFIG"
}

sb_sha() {
  sha256sum | awk '{print $1}'
}

sb_now_ms() {
  date +%s%3N
}

sb_state_root() {
  printf '%s\n' "${SIGNALBOX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/signalbox}"
}

sb_tool_file() {
  printf '%s/config/tools.txt\n' "$SIGNALBOX_HOME"
}

sb_tool_version() {
  local tool=$1 output=''
  case $tool in
    bash) bash --version 2>/dev/null | sed -n '1p' ;;
    sha256sum|timeout|tar) "$tool" --version 2>/dev/null | sed -n '1p' ;;
    *) output=$(timeout 3 "$tool" --version 2>/dev/null | sed -n '1p' || true); printf '%s\n' "${output:-available}" ;;
  esac
}

sb_tool_healthy() {
  local tool=$1 output
  case $tool in
    bats) output=$(timeout 3 bats --version 2>/dev/null || true); [[ $output == Bats* ]] ;;
    shellcheck) output=$(timeout 3 shellcheck --version 2>/dev/null || true); [[ $output == *"ShellCheck"* ]] ;;
    hyperfine) output=$(timeout 3 hyperfine --version 2>/dev/null || true); [[ $output == hyperfine* ]] ;;
    turnsignal) output=$(timeout 3 turnsignal --version 2>/dev/null || true); [[ $output == turnsignal* ]] ;;
    *) return 0 ;;
  esac
}

sb_doctor_json() {
  local rows='[]' missing=0 tool required scope path version status
  while IFS='|' read -r tool required scope; do
    [[ -z $tool || $tool == \#* ]] && continue
    path=$(command -v "$tool" 2>/dev/null || true)
    if [[ -n $path ]] && sb_tool_healthy "$tool"; then
      status=present
      version=$(sb_tool_version "$tool")
    elif [[ -n $path ]]; then
      status=broken
      version='health probe failed'
      [[ $required == required ]] && missing=$((missing + 1))
    else
      status=missing
      version=''
      [[ $required == required ]] && missing=$((missing + 1))
    fi
    rows=$(jq -c --arg name "$tool" --arg status "$status" --arg path "$path" \
      --arg version "$version" --arg scope "$scope" \
      '. + [{name:$name,status:$status,path:$path,version:$version,scope:$scope}]' <<<"$rows")
  done <"$(sb_tool_file)"
  jq -n --argjson schema "$SIGNALBOX_SCHEMA" --arg version "$SIGNALBOX_VERSION" \
    --argjson missing "$missing" --argjson tools "$rows" \
    '{schema_version:$schema,signalbox_version:$version,ready:($missing == 0),missing_count:$missing,tools:$tools}'
  ((missing == 0))
}

sb_cmd_doctor() {
  local json=false
  [[ ${1:-} == --json ]] && json=true && shift
  (($# == 0)) || sb_die "$SIGNALBOX_EXIT_CONFIG" "unexpected doctor arguments"
  local report rc=0
  report=$(sb_doctor_json) || rc=$SIGNALBOX_EXIT_CONFIG
  if $json; then
    jq . <<<"$report"
  else
    jq -r '"Signalbox doctor: " + (if .ready then "READY" else "MISSING " + (.missing_count|tostring) end), (.tools[] | "  \(.status)\t\(.name)\t\(.version)")' <<<"$report"
  fi
  return "$rc"
}

sb_fingerprint() {
  local target=$1
  (
    cd "$target" || exit
    find . -type f \
      ! -path './.git/*' ! -path './.signalbox/*' ! -path './target/*' \
      ! -path './node_modules/*' -print0 \
      | sort -z | xargs -0 -r sha256sum
  ) | sb_sha
}

sb_detect_language() {
  local target=$1 langs='[]'
  [[ -f $target/Cargo.toml ]] && langs=$(jq -c '. + ["rust"]' <<<"$langs")
  find "$target" -type f -name '*.sh' -print -quit 2>/dev/null | grep -q . && langs=$(jq -c '. + ["bash"]' <<<"$langs")
  find "$target" -type f \( -name '*.py' -o -name '*.js' -o -name '*.ts' \) -print -quit 2>/dev/null | grep -q . && langs=$(jq -c '. + ["polyglot"]' <<<"$langs")
  jq -c 'unique' <<<"$langs"
}

sb_snapshot() {
  local target=$1 destination=$2
  mkdir -p "$destination"
  (
    cd "$target" || exit
    tar --exclude=.git --exclude=.signalbox --exclude=target --exclude=node_modules \
      --exclude=.kaptaind --exclude=.fract --exclude=.traci --exclude=.toon -cf - .
  ) | tar -xf - -C "$destination"
  git -C "$destination" init -q -b main
  git -C "$destination" add -A
  git -C "$destination" -c user.name=Signalbox -c user.email=signalbox@localhost \
    commit -q -m snapshot --allow-empty
}

sb_trace_event() {
  local trace=$1 actor=$2 event_type=$3 payload=$4
  local line_count seed id timestamp
  line_count=$(wc -l <"$trace" 2>/dev/null || printf 0)
  seed=$(printf '%s:%s:%s' "$actor" "$event_type" "$line_count" | sha256sum | awk '{print $1}')
  id="${seed:0:8}-${seed:8:4}-${seed:12:4}-${seed:16:4}-${seed:20:12}"
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --arg id "$id" --arg actor "$actor" --arg timestamp "$timestamp" \
    --arg event_type "$event_type" --argjson payload "$payload" \
    '{id:$id,actor:$actor,timestamp:$timestamp,event_type:$event_type,payload:$payload}' >>"$trace"
}

sb_record() {
  local results=$1 name=$2 status=$3 exit_code=$4 duration=$5 summary=$6 artifact=${7:-}
  jq -nc --arg name "$name" --arg status "$status" --argjson exit_code "$exit_code" \
    --argjson duration_ms "$duration" --arg summary "$summary" --arg artifact "$artifact" \
    '{name:$name,status:$status,exit_code:$exit_code,duration_ms:$duration_ms,summary:$summary,artifact:(if $artifact == "" then null else $artifact end)}' >>"$results"
}

sb_run() {
  local results=$1 trace=$2 run_dir=$3 name=$4
  shift 4
  local artifact=$run_dir/$name.log start end rc=0 status summary payload
  start=$(sb_now_ms)
  sb_trace_event "$trace" agent tool_call "$(jq -nc --arg tool "$name" --arg command "$(printf '%q ' "$@")" '{tool:$tool,command:$command}')"
  timeout "${SIGNALBOX_TOOL_TIMEOUT:-60}" "$@" >"$artifact" 2>&1 || rc=$?
  end=$(sb_now_ms)
  if ((rc == 0)); then status=pass; else status=finding; fi
  summary=$(tail -c 400 "$artifact" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
  [[ -n $summary ]] || summary="completed with exit $rc"
  sb_record "$results" "$name" "$status" "$rc" "$((end-start))" "$summary" "$artifact"
  payload=$(jq -nc --arg tool "$name" --argjson exit_code "$rc" --arg output_sha "$(sb_sha <"$artifact")" \
    '{tool:$tool,exit_code:$exit_code,output_sha256:$output_sha}')
  sb_trace_event "$trace" tool tool_result "$payload"
  return 0
}

sb_run_in() {
  local results=$1 trace=$2 run_dir=$3 name=$4 cwd=$5
  shift 5
  # Expansion belongs to the isolated child shell.
  # shellcheck disable=SC2016
  sb_run "$results" "$trace" "$run_dir" "$name" bash -c \
    'cd -- "$1"; shift; exec "$@"' signalbox-run "$cwd" "$@"
}

sb_na() {
  sb_record "$1" "$2" not_applicable 0 0 "$3" ''
}

sb_missing() {
  sb_record "$1" "$2" error 127 0 "required command is missing" ''
}

sb_invoke_if_present() {
  local results=$1 trace=$2 run_dir=$3 name=$4 command=$5
  shift 5
  if command -v "$command" >/dev/null 2>&1; then
    sb_run "$results" "$trace" "$run_dir" "$name" "$command" "$@"
  else
    sb_missing "$results" "$name"
  fi
}

sb_cmd_analyze() {
  local target='' goal='' claim='' supplied_trace=''
  while (($#)); do
    case $1 in
      --target) sb_require_arg "$1" "${2:-}"; target=$2; shift 2 ;;
      --goal) sb_require_arg "$1" "${2:-}"; goal=$2; shift 2 ;;
      --claim) sb_require_arg "$1" "${2:-}"; claim=$2; shift 2 ;;
      --trace) sb_require_arg "$1" "${2:-}"; supplied_trace=$2; shift 2 ;;
      *) sb_die "$SIGNALBOX_EXIT_CONFIG" "unknown analyze option: $1"; return ;;
    esac
  done
  [[ -n $target && -n $goal ]] || sb_die "$SIGNALBOX_EXIT_CONFIG" "analyze requires --target and --goal"
  target=$(sb_realpath "$target") || sb_die "$SIGNALBOX_EXIT_CONFIG" "target does not exist"
  [[ -z $claim || -f $claim ]] || sb_die "$SIGNALBOX_EXIT_CONFIG" "claim file does not exist"
  [[ -z $supplied_trace || -f $supplied_trace ]] || sb_die "$SIGNALBOX_EXIT_CONFIG" "trace file does not exist"

  local fingerprint languages run_id run_dir results trace snapshot git_root status_hash
  fingerprint=$(sb_fingerprint "$target")
  languages=$(sb_detect_language "$target")
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-${fingerprint:0:12}"
  run_dir="$(sb_state_root)/runs/$run_id"
  mkdir -p "$run_dir" || {
    sb_die "$SIGNALBOX_EXIT_CONFIG" "cannot create state directory: $run_dir"
    return "$SIGNALBOX_EXIT_CONFIG"
  }
  results=$run_dir/results.jsonl
  trace=$run_dir/trace.jsonl
  : >"$results"; : >"$trace"
  [[ -z $supplied_trace ]] || jq -c '.[]' "$supplied_trace" >>"$trace"

  git_root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ $git_root == "$target" ]]; then
    sb_record "$results" repository_scope pass 0 0 "target is an independent Git root" ''
  elif [[ -n $git_root ]]; then
    sb_record "$results" repository_scope finding 2 0 "target resolves to parent Git root: $git_root" ''
  else
    sb_record "$results" repository_scope finding 2 0 "target is not initialized as a Git repository" ''
  fi
  status_hash=$(git -C "$target" status --porcelain 2>/dev/null | sb_sha || true)

  snapshot=$(mktemp -d)
  sb_snapshot "$target" "$snapshot"

  if jq -e 'index("bash") != null' <<<"$languages" >/dev/null; then
    mapfile -d '' bash_files < <(find "$snapshot" -type f -name '*.sh' -print0)
    if ((${#bash_files[@]})); then
      sb_run "$results" "$trace" "$run_dir" bash-syntax bash -n "${bash_files[@]}"
      sb_invoke_if_present "$results" "$trace" "$run_dir" shellcheck shellcheck -x "${bash_files[@]}"
    fi
  else
    sb_na "$results" bash-syntax "no Bash source files"
    sb_na "$results" shellcheck "no Bash source files"
  fi

  if [[ -f $snapshot/deliver.toml || -f $snapshot/deliver.json ]]; then
    local spec=$snapshot/deliver.toml
    [[ -f $spec ]] || spec=$snapshot/deliver.json
    if command -v deliver >/dev/null 2>&1; then
      sb_run_in "$results" "$trace" "$run_dir" deliver "$snapshot" deliver --spec "$spec" --base "$snapshot" --strict --format json
    else
      sb_missing "$results" deliver
    fi
  else
    sb_na "$results" deliver "no deliver specification"
  fi
  sb_invoke_if_present "$results" "$trace" "$run_dir" kaptaind kaptaind-cli -r "$snapshot" analyze
  sb_invoke_if_present "$results" "$trace" "$run_dir" bart bart --json -d 3 -n 0 "$snapshot"
  if jq -e 'index("rust") != null or index("polyglot") != null' <<<"$languages" >/dev/null; then
    if command -v deckhand >/dev/null 2>&1; then
      sb_run_in "$results" "$trace" "$run_dir" deckhand "$snapshot" deckhand --no-color --no-emoji --no-tts status --json
    else
      sb_missing "$results" deckhand
    fi
  else
    sb_na "$results" deckhand "target has no Deckhand-supported build system"
  fi

  if jq -e 'index("rust") != null' <<<"$languages" >/dev/null; then
    sb_invoke_if_present "$results" "$trace" "$run_dir" amber amber "$snapshot" --format json
    if command -v fract >/dev/null 2>&1; then
      sb_run_in "$results" "$trace" "$run_dir" fract "$snapshot" fract --no-color -f json index
    else
      sb_missing "$results" fract
    fi
    sb_invoke_if_present "$results" "$trace" "$run_dir" traci traci check "$snapshot/src" --format json --production-only
    if command -v boar >/dev/null 2>&1; then
      sb_run_in "$results" "$trace" "$run_dir" boar "$snapshot" boar doctor
    else
      sb_missing "$results" boar
    fi
  else
    sb_na "$results" amber "target is not a Cargo project"
    if jq -e 'index("polyglot") != null' <<<"$languages" >/dev/null; then
      if command -v fract >/dev/null 2>&1; then
        sb_run_in "$results" "$trace" "$run_dir" fract "$snapshot" fract --no-color -f json index
      else
        sb_missing "$results" fract
      fi
    else
      sb_na "$results" fract "target language is unsupported"
    fi
    sb_na "$results" traci "target is not a Rust project"
    sb_na "$results" boar "target is not a Rust project"
  fi

  sb_invoke_if_present "$results" "$trace" "$run_dir" jailbreak-sentinel jailbreak-sentinel --mode active --input "$goal"
  sb_invoke_if_present "$results" "$trace" "$run_dir" least-priv least-priv --task "$goal"
  local manifest=$run_dir/intent.json tool_call=$run_dir/tool-call.json
  jq -n --arg root "$target" --arg goal "Read and analyze the repository to: $goal" \
    '{allowed_paths:[$root],disallowed_commands:["rm -rf /","mkfs","git push --force"],required_confirmations:{mode:"prompt"},original_goal:$goal}' >"$manifest"
  jq -n --arg root "$target" '{id:"analysis-1",tool:"read_repository",arguments:{path:$root}}' >"$tool_call"
  sb_invoke_if_present "$results" "$trace" "$run_dir" intent-fence intent-fence --manifest "$manifest" --tool-call "$(<"$tool_call")"
  sb_invoke_if_present "$results" "$trace" "$run_dir" diverge diverge --question "Is this repository ready for the next state transition? Goal: $goal" --agents 4 --threshold 0.66

  if [[ -n ${SIGNALBOX_SESSION_LOG:-} && -f ${SIGNALBOX_SESSION_LOG} ]]; then
    sb_invoke_if_present "$results" "$trace" "$run_dir" tokaudit tokaudit "$SIGNALBOX_SESSION_LOG" --format json
  else
    sb_na "$results" tokaudit "no closed session log supplied in SIGNALBOX_SESSION_LOG"
  fi

  sb_invoke_if_present "$results" "$trace" "$run_dir" turnsignal turnsignal --mode injective \
    "Repository inspected and deterministic analysis completed for: $goal"

  rm -rf -- "$snapshot"

  local statuses verdict state next_action confidence evidence report
  statuses=$(jq -s '.' "$results")
  if jq -e 'any(.status == "error")' <<<"$statuses" >/dev/null; then
    verdict=blocked; state=configuration_blocked; next_action=install_or_repair_required_tools; confidence=0.99
  elif jq -e 'any(.status == "finding")' <<<"$statuses" >/dev/null; then
    verdict=needs_attention; state=analysis_complete_with_findings; next_action=resolve_highest_priority_finding; confidence=0.95
  else
    verdict=ready; state=analysis_complete; next_action=verify_claims; confidence=0.98
  fi
  evidence=$(jq -s '[.[] | select(.status != "pass" and .status != "not_applicable") | .summary][0:3]' "$results")
  report=$(jq -n --argjson schema "$SIGNALBOX_SCHEMA" --arg run_id "$run_id" --arg target "$target" \
    --arg goal "$goal" --arg fingerprint "$fingerprint" --arg status_hash "$status_hash" \
    --argjson languages "$languages" --arg verdict "$verdict" --arg state "$state" \
    --arg next "$next_action" --argjson confidence "$confidence" --arg run_dir "$run_dir" \
    --argjson analyzers "$statuses" --argjson evidence "$evidence" \
    '{schema_version:$schema,run_id:$run_id,target:$target,goal:$goal,input_fingerprint:$fingerprint,worktree_status_hash:$status_hash,languages:$languages,verdict:$verdict,state:$state,confidence:$confidence,next_action:$next,evidence:$evidence,analyzers:$analyzers,run_dir:$run_dir}')
  jq . <<<"$report" >"$run_dir/result.json"
  jq -s '.' "$trace" >"$run_dir/trace.json"
  [[ -z $claim ]] || cp "$claim" "$run_dir/claim.txt"
  jq . <<<"$report"
  case $verdict in ready) return 0;; needs_attention) return "$SIGNALBOX_EXIT_FINDINGS";; *) return "$SIGNALBOX_EXIT_CONFIG";; esac
}

sb_cmd_verify() {
  local run='' goal='' claim=''
  while (($#)); do
    case $1 in
      --run) sb_require_arg "$1" "${2:-}"; run=$2; shift 2 ;;
      --goal) sb_require_arg "$1" "${2:-}"; goal=$2; shift 2 ;;
      --claim) sb_require_arg "$1" "${2:-}"; claim=$2; shift 2 ;;
      *) sb_die "$SIGNALBOX_EXIT_CONFIG" "unknown verify option: $1"; return ;;
    esac
  done
  [[ -d $run && -f $run/result.json && -f $run/trace.json ]] || sb_die "$SIGNALBOX_EXIT_CONFIG" "invalid run directory"
  [[ -n $goal ]] || goal=$(jq -r .goal "$run/result.json")
  if [[ -z $claim ]]; then claim=$run/claim.txt; fi
  if [[ ! -f $claim ]]; then
    jq -r '"Signalbox analyzed " + .target + " with verdict " + .verdict + "."' "$run/result.json" >"$run/claim.txt"
    claim=$run/claim.txt
  fi
  local verify_out=$run/verify-chain.json guard_out=$run/gpt56-guard.json config=$run/gpt56-config.json verify_rc=0 guard_rc=0 target
  target=$(jq -r .target "$run/result.json")
  jq -n --arg target "$target" \
    '{allowed_paths:[$target],disallowed_commands:["rm -rf /","mkfs","git push --force"],confirmation_threshold:{mode:"auto"},sentinel_mode:"active",verify_execute_tests:false,verify_fetch_urls:false,allowed_env_vars:["PATH","HOME","USER"],diverge_frames:["minimal_change_advocate"]}' >"$config"
  verify-chain --trace "$run/trace.json" --output "$claim" --working-dir "$target" >"$verify_out" 2>&1 || verify_rc=$?
  gpt56-guard --goal "$goal" --output "$(<"$claim")" --trace "$run/trace.json" --config "$config" --pretty >"$guard_out" 2>&1 || guard_rc=$?
  jq -n --argjson schema "$SIGNALBOX_SCHEMA" --arg run "$run" --argjson verify_exit "$verify_rc" \
    --argjson guard_exit "$guard_rc" --arg verify_artifact "$verify_out" --arg guard_artifact "$guard_out" \
    '{schema_version:$schema,run_dir:$run,verified:($verify_exit == 0 and $guard_exit == 0),verify_chain:{exit_code:$verify_exit,artifact:$verify_artifact},gpt56_guard:{exit_code:$guard_exit,artifact:$guard_artifact}}'
  ((verify_rc == 0 && guard_rc == 0))
}

sb_cmd_suite() {
  local temp rc=0 verify_rc=0
  temp=$(mktemp)
  sb_cmd_analyze "$@" >"$temp" || rc=$?
  if ! jq -e . "$temp" >/dev/null 2>&1; then
    rm -f "$temp"
    ((rc != 0)) || rc=$SIGNALBOX_EXIT_CONFIG
    return "$rc"
  fi
  local run
  run=$(jq -r .run_dir "$temp")
  local verified
  verified=$(sb_cmd_verify --run "$run") || verify_rc=$?
  jq -n --slurpfile analysis "$temp" --argjson verification "$verified" \
    '{analysis:$analysis[0],verification:$verification,ready:($analysis[0].verdict == "ready" and $verification.verified)}'
  rm -f "$temp"
  ((rc == 0 && verify_rc == 0))
}

sb_remote_sha() {
  git ls-remote "git@github.com:$1.git" refs/heads/main 2>/dev/null | awk '{print $1}'
}

sb_cmd_publish_plan() {
  local target='' remote='' message='' out=''
  while (($#)); do
    case $1 in
      --target) sb_require_arg "$1" "${2:-}"; target=$2; shift 2 ;;
      --remote) sb_require_arg "$1" "${2:-}"; remote=$2; shift 2 ;;
      --message) sb_require_arg "$1" "${2:-}"; message=$2; shift 2 ;;
      --out) sb_require_arg "$1" "${2:-}"; out=$2; shift 2 ;;
      *) sb_die "$SIGNALBOX_EXIT_CONFIG" "unknown publish plan option: $1"; return ;;
    esac
  done
  [[ -n $target && -n $remote && -n $message && -n $out ]] || sb_die "$SIGNALBOX_EXIT_CONFIG" "publish plan requires target, remote, message, and out"
  [[ $remote =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || sb_die "$SIGNALBOX_EXIT_CONFIG" "invalid OWNER/REPO"
  target=$(sb_realpath "$target") || sb_die "$SIGNALBOX_EXIT_CONFIG" "target does not exist"
  gh repo view "$remote" --json nameWithOwner,isEmpty >/dev/null || sb_die "$SIGNALBOX_EXIT_CONFIG" "existing GitHub repository is required"
  local root head fingerprint remote_sha files base digest
  root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)
  [[ $root == "$target" ]] || root=''
  head=$(git -C "$target" rev-parse HEAD 2>/dev/null || true)
  fingerprint=$(sb_fingerprint "$target")
  remote_sha=$(sb_remote_sha "$remote")
  files=$(cd "$target" && find . -type f ! -path './.git/*' ! -path './.signalbox/*' \
    ! -path './target/*' ! -path './node_modules/*' -printf '%P\n' | LC_ALL=C sort | jq -Rsc 'split("\n")[:-1]')
  base=$(jq -n --argjson schema "$SIGNALBOX_SCHEMA" --arg target "$target" --arg remote "$remote" \
    --arg message "$message" --arg root "$root" --arg head "$head" --arg fingerprint "$fingerprint" \
    --arg remote_sha "$remote_sha" --argjson files "$files" \
    '{schema_version:$schema,kind:"signalbox_publish_plan",target:$target,remote:$remote,branch:"main",message:$message,preconditions:{git_root:$root,head:$head,input_fingerprint:$fingerprint,remote_sha:$remote_sha},files:$files,actions:["initialize_if_needed","attach_existing_remote","stage_exact_files","commit","push","verify_remote"]}')
  digest=$(jq -cS . <<<"$base" | sb_sha)
  jq --arg digest "$digest" '. + {digest:$digest}' <<<"$base" >"$out"
  jq . "$out"
}

sb_release_lock() {
  [[ -z ${SB_LOCK_RESOURCE:-} ]] || locksmith release "$SB_LOCK_RESOURCE" >/dev/null 2>&1 || true
  [[ -z ${SB_HEARTBEAT_PID:-} ]] || kill "$SB_HEARTBEAT_PID" >/dev/null 2>&1 || true
}

sb_cmd_publish_apply() {
  local plan='' confirm=''
  while (($#)); do
    case $1 in
      --plan) sb_require_arg "$1" "${2:-}"; plan=$2; shift 2 ;;
      --confirm) sb_require_arg "$1" "${2:-}"; confirm=$2; shift 2 ;;
      *) sb_die "$SIGNALBOX_EXIT_CONFIG" "unknown publish apply option: $1"; return ;;
    esac
  done
  [[ -f $plan ]] || sb_die "$SIGNALBOX_EXIT_CONFIG" "plan file does not exist"
  local stored calculated target remote fingerprint root current_head expected_head expected_remote current_remote message
  stored=$(jq -r .digest "$plan")
  calculated=$(jq 'del(.digest)' "$plan" | jq -cS . | sb_sha)
  [[ $confirm == "$stored" && $stored == "$calculated" ]] || sb_die "$SIGNALBOX_EXIT_STALE" "confirmation digest mismatch"
  target=$(jq -r .target "$plan"); remote=$(jq -r .remote "$plan"); message=$(jq -r .message "$plan")
  fingerprint=$(sb_fingerprint "$target")
  [[ $fingerprint == "$(jq -r .preconditions.input_fingerprint "$plan")" ]] || sb_die "$SIGNALBOX_EXIT_STALE" "target changed after planning"
  root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)
  [[ $root == "$target" ]] || root=''
  [[ $root == "$(jq -r .preconditions.git_root "$plan")" ]] || sb_die "$SIGNALBOX_EXIT_STALE" "Git root changed after planning"
  current_head=$(git -C "$target" rev-parse HEAD 2>/dev/null || true); expected_head=$(jq -r .preconditions.head "$plan")
  [[ $current_head == "$expected_head" ]] || sb_die "$SIGNALBOX_EXIT_STALE" "HEAD changed after planning"
  current_remote=$(sb_remote_sha "$remote"); expected_remote=$(jq -r .preconditions.remote_sha "$plan")
  [[ $current_remote == "$expected_remote" ]] || sb_die "$SIGNALBOX_EXIT_STALE" "remote changed after planning"

  SB_LOCK_RESOURCE="repo:$remote"
  locksmith acquire "$SB_LOCK_RESOURCE" --lease 20m --wait --wait-timeout 60 >/dev/null || sb_die "$SIGNALBOX_EXIT_ACTION" "could not acquire publication lease"
  (while sleep 30; do locksmith heartbeat "$SB_LOCK_RESOURCE" >/dev/null 2>&1 || exit; done) &
  SB_HEARTBEAT_PID=$!
  trap sb_release_lock EXIT INT TERM
  if [[ -z $root ]]; then git -C "$target" init -b main; fi
  if git -C "$target" remote get-url origin >/dev/null 2>&1; then
    [[ $(git -C "$target" remote get-url origin) == "git@github.com:$remote.git" ]] || sb_die "$SIGNALBOX_EXIT_STALE" "origin points elsewhere"
  else
    git -C "$target" remote add origin "git@github.com:$remote.git"
  fi
  mapfile -t files < <(jq -r '.files[]' "$plan")
  git -C "$target" add -- "${files[@]}"
  git -C "$target" diff --cached --check
  git -C "$target" commit -m "$message"
  git -C "$target" push -u origin main
  local local_sha remote_after
  local_sha=$(git -C "$target" rev-parse HEAD); remote_after=$(sb_remote_sha "$remote")
  [[ $local_sha == "$remote_after" ]] || sb_die "$SIGNALBOX_EXIT_ACTION" "remote verification failed"
  sb_release_lock; trap - EXIT INT TERM
  jq -n --arg remote "$remote" --arg branch main --arg commit "$local_sha" '{published:true,remote:$remote,branch:$branch,commit:$commit,verified:true}'
}

sb_cmd_benchmark() {
  local iterations=30 output=''
  while (($#)); do
    case $1 in
      --iterations) sb_require_arg "$1" "${2:-}"; iterations=$2; shift 2 ;;
      --output) sb_require_arg "$1" "${2:-}"; output=$2; shift 2 ;;
      *) sb_die "$SIGNALBOX_EXIT_CONFIG" "unknown benchmark option: $1"; return ;;
    esac
  done
  [[ $iterations =~ ^[1-9][0-9]*$ ]] || sb_die "$SIGNALBOX_EXIT_CONFIG" "iterations must be positive"
  [[ -n $output ]] || output="$(sb_state_root)/benchmarks/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$output"
  local export=$output/hyperfine.json guard_json=$output/gpt56-benchmark.json guard_md=$output/gpt56-benchmark.md
  hyperfine --warmup 3 --runs "$iterations" --export-json "$export" \
    "SIGNALBOX_HOME='$SIGNALBOX_HOME' '$SIGNALBOX_HOME/bin/signalbox' doctor --json >/dev/null" >/dev/null
  gpt56-benchmark --output "$guard_json" --report "$guard_md" --pretty >/dev/null
  jq -n --argjson schema "$SIGNALBOX_SCHEMA" --arg output "$output" \
    --slurpfile hyperfine "$export" --slurpfile guard "$guard_json" \
    '{schema_version:$schema,output_dir:$output,doctor:{mean_seconds:$hyperfine[0].results[0].mean,median_seconds:$hyperfine[0].results[0].median,max_seconds:$hyperfine[0].results[0].max},guardrail_benchmark:$guard[0]}' | tee "$output/result.json"
}

signalbox_main() {
  local command=${1:-help}
  (($# == 0)) || shift
  case $command in
    help|-h|--help) sb_usage ;;
    version|-V|--version) printf 'signalbox %s\n' "$SIGNALBOX_VERSION" ;;
    doctor) sb_cmd_doctor "$@" ;;
    analyze) sb_cmd_analyze "$@" ;;
    suite) sb_cmd_suite "$@" ;;
    verify) sb_cmd_verify "$@" ;;
    benchmark) sb_cmd_benchmark "$@" ;;
    publish)
      local sub=${1:-}; (($# == 0)) || shift
      case $sub in plan) sb_cmd_publish_plan "$@";; apply) sb_cmd_publish_apply "$@";; *) sb_die "$SIGNALBOX_EXIT_CONFIG" "publish requires plan or apply";; esac
      ;;
    *) sb_die "$SIGNALBOX_EXIT_CONFIG" "unknown command: $command" ;;
  esac
}
