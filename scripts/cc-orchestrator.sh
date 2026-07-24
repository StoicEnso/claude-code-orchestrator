#!/bin/bash
# Claude Code Orchestrator
# High-level task management layer on top of run-task.sh
#
# Commands:
#   dispatch  — Submit a task, get a handle back immediately
#   poll      — Check current task status + progress
#   watch     — Tail live progress from the raw stream log
#   result    — Get the final result (json or text)
#   resume    — Send a correction/continuation to a task
#   batch     — Dispatch multiple tasks from a JSONL manifest
#   list      — Show all tracked tasks
#   cancel    — Kill a running task
#   costs     — Show cost summary across all tasks
#   cleanup   — Archive completed tasks, remove old data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_TOOL="$SCRIPT_DIR/cc-state.py"
REGISTRY_DIR="${CC_REGISTRY_DIR:-/tmp/claude-subagent-registry}"
RESULTS_DIR="${CC_RESULTS_DIR:-/tmp/claude-subagent-results}"
LOGS_DIR="${CC_LOGS_DIR:-/tmp/claude-subagent-logs}"
COST_LOG="${CC_COST_LOG:-/tmp/claude-subagent-costs.jsonl}"
HOOKS_DIR="${CC_HOOKS_DIR:-/tmp/claude-subagent-hooks}"

mkdir -p "$REGISTRY_DIR" "$RESULTS_DIR" "$LOGS_DIR" "$HOOKS_DIR"

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

gen_task_id() {
  local label="${1:-task}"
  local clean_label
  clean_label=$(echo "$label" | tr ' /' '-' | tr -cd 'a-zA-Z0-9-' | head -c 30)
  echo "${clean_label}-$(date +%s)-$$"
}

effective_budget() {
  local budget="${1:-none}"
  local multiplier="${CLAUDE_DELEGATE_BUDGET_MULTIPLIER:-1}"
  python3 - "$budget" "$multiplier" <<'PY'
from decimal import Decimal, InvalidOperation, ROUND_UP
import sys

budget = (sys.argv[1] or 'none').strip()
multiplier = (sys.argv[2] or '1').strip()
unlimited = {'', 'none', 'unlimited', 'unbounded', 'no-cap', 'nocap', 'off', 'false', '0', '0.0', '0.00'}
if budget.lower().replace('_', '-') in unlimited:
    print(budget or 'none')
    raise SystemExit(0)
try:
    b = Decimal(budget)
    m = Decimal(multiplier)
except (InvalidOperation, ValueError):
    print(budget)
    raise SystemExit(0)
if m <= 0 or m == 1:
    print(budget)
    raise SystemExit(0)
print(format((b * m).quantize(Decimal('0.01'), rounding=ROUND_UP), 'f'))
PY
}

validate_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "{\"error\": \"$2 must be a non-negative integer\"}" >&2; exit 1; }
}

validate_continuation_mode() {
  case "$1" in
    continue|switch|blocked|complete) ;;
    *) echo '{"error": "continuation-mode must be continue, switch, blocked, or complete"}' >&2; exit 1 ;;
  esac
}

refresh_from_output_if_ready() {
  local task_id="$1"
  local reg_file="$REGISTRY_DIR/${task_id}.json"
  local out_file="$LOGS_DIR/${task_id}.out"
  local stream_file="$LOGS_DIR/${task_id}.stream"
  local status
  status=$(python3 -c "import json; print(json.load(open('$reg_file')).get('status',''))" 2>/dev/null || true)
  if [ "$status" = "running" ] && [ -f "$out_file" ]; then
    python3 "$STATE_TOOL" terminal --registry "$reg_file" --result-file "$out_file" >/dev/null
  elif [ "$status" = "running" ] && [ -f "$stream_file" ]; then
    python3 "$STATE_TOOL" progress --registry "$reg_file" --stream-file "$stream_file" >/dev/null
  fi
  python3 "$STATE_TOOL" status --registry "$reg_file"
}

run_notify_hook() {
  local task_id="$1"
  local reg_file="$REGISTRY_DIR/${task_id}.json"
  [ -f "$reg_file" ] || return 0

  local notify_cmd
  notify_cmd=$(python3 -c "import json; print(json.load(open('$reg_file')).get('notify_cmd',''))" 2>/dev/null || true)
  [ -n "$notify_cmd" ] || return 0

  local claim_out="$HOOKS_DIR/${task_id}.callback-claim.json"
  if ! python3 "$STATE_TOOL" callback-claim --registry "$reg_file" \
      --lease-seconds "${CC_CALLBACK_LEASE_SECS:-900}" \
      --max-attempts "${CC_CALLBACK_MAX_ATTEMPTS:-3}" \
      --owner "terminal-hook:$$" > "$claim_out" 2>/dev/null; then
    return 0
  fi

  local status result_preview cost expected_file expected_canonical expected_exists expected_bytes verified next_action continuation_mode session_id
  readarray -t fields < <(python3 - "$reg_file" <<'PYSTATE'
import json,sys
with open(sys.argv[1],encoding='utf-8') as handle: reg=json.load(handle)
for value in (
    reg.get('status',''), reg.get('result_preview',''), reg.get('cost_usd',0),
    reg.get('expected_file',''), reg.get('expected_file_canonical',''),
    reg.get('expected_file_exists',False), reg.get('expected_file_bytes',0),
    reg.get('verified',False), reg.get('next_action',''),
    reg.get('continuation_mode',''), reg.get('session_id','')
): print(str(value).replace('\n',' '))
PYSTATE
)
  status="${fields[0]:-}"; result_preview="${fields[1]:-}"; cost="${fields[2]:-0}"
  expected_file="${fields[3]:-}"; expected_canonical="${fields[4]:-}"
  expected_exists="${fields[5]:-False}"; expected_bytes="${fields[6]:-0}"
  verified="${fields[7]:-False}"; next_action="${fields[8]:-}"
  continuation_mode="${fields[9]:-}"; session_id="${fields[10]:-}"

  local out_file="$HOOKS_DIR/${task_id}.notify.out"
  local err_file="$HOOKS_DIR/${task_id}.notify.err"
  local rc=0
  CC_NOTIFY_TASK_ID="$task_id" \
  CC_NOTIFY_REGISTRY_FILE="$reg_file" \
  CC_NOTIFY_STATUS="$status" \
  CC_NOTIFY_COST_USD="$cost" \
  CC_NOTIFY_RESULT_PREVIEW="$result_preview" \
  CC_NOTIFY_EXPECTED_FILE="$expected_file" \
  CC_NOTIFY_EXPECTED_FILE_CANONICAL="$expected_canonical" \
  CC_NOTIFY_EXPECTED_FILE_EXISTS="$expected_exists" \
  CC_NOTIFY_EXPECTED_FILE_BYTES="$expected_bytes" \
  CC_NOTIFY_VERIFIED="$verified" \
  CC_NOTIFY_NEXT_ACTION="$next_action" \
  CC_NOTIFY_CONTINUATION_MODE="$continuation_mode" \
  CC_NOTIFY_SESSION_ID="$session_id" \
  bash -lc "$notify_cmd" > "$out_file" 2> "$err_file" || rc=$?

  if [ "$rc" -eq 0 ]; then
    python3 "$STATE_TOOL" callback-finish --registry "$reg_file" --state sent --receipt-file "$out_file" >/dev/null
    : > "$HOOKS_DIR/${task_id}.callback-sent"
  else
    python3 "$STATE_TOOL" callback-finish --registry "$reg_file" --state failed --receipt-file "$out_file" --error "notify command exited $rc" >/dev/null
  fi
}

finish_task_from_output() {
  local task_id="$1"
  local exit_code="$2"
  local reg_file="$REGISTRY_DIR/${task_id}.json"
  local out_file="$LOGS_DIR/${task_id}.out"

  if [ -f "$out_file" ]; then
    python3 "$STATE_TOOL" terminal --registry "$reg_file" --result-file "$out_file" --exit-code "$exit_code" >/dev/null
  else
    local final_status="done"
    [ "$exit_code" -eq 0 ] || final_status="failed"
    python3 "$STATE_TOOL" terminal --registry "$reg_file" --status "$final_status" --exit-code "$exit_code" >/dev/null
  fi
  python3 - "$reg_file" "$COST_LOG" <<'PYLOG'
import json,sys,time
reg_file,cost_log=sys.argv[1:3]
with open(reg_file,encoding='utf-8') as handle: entry=json.load(handle)
with open(cost_log,'a',encoding='utf-8') as handle:
    handle.write(json.dumps({
        'task_id':entry.get('task_id',''), 'label':entry.get('label',''),
        'model':entry.get('model',''), 'cost_usd':entry.get('cost_usd',0),
        'status':entry.get('status',''), 'ts':time.strftime('%Y-%m-%dT%H:%M:%S%z')
    })+'\n')
PYLOG
  run_notify_hook "$task_id"
}

cmd_dispatch() {
  local workdir="${1:-.}"
  local budget="${2:-none}"
  local model="${3:-sonnet}"
  local label="${4:-task}"
  local task="${5:-}"
  shift 5 || true

  local timeout_secs="0" notify_cmd="" expected_file="" expect_min_bytes="0"
  local next_action="Review the terminal result and confirm the next action."
  local continuation_mode="continue" batch_id=""
  local owner_agent_id="" owner_session_key="" delivery_channel="" delivery_target="" delivery_account=""
  local -a allowed_root_args=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout) timeout_secs="${2:-0}"; shift 2 ;;
      --notify-cmd) notify_cmd="${2:-}"; shift 2 ;;
      --batch-id) batch_id="${2:-}"; shift 2 ;;
      --expect-file) expected_file="${2:-}"; shift 2 ;;
      --expect-min-bytes) expect_min_bytes="${2:-0}"; shift 2 ;;
      --allowed-root) allowed_root_args+=(--allowed-root "${2:-}"); shift 2 ;;
      --next-action) next_action="${2:-}"; shift 2 ;;
      --continuation-mode) continuation_mode="${2:-}"; shift 2 ;;
      --owner-agent-id) owner_agent_id="${2:-}"; shift 2 ;;
      --owner-session-key) owner_session_key="${2:-}"; shift 2 ;;
      --delivery-channel) delivery_channel="${2:-}"; shift 2 ;;
      --delivery-target) delivery_target="${2:-}"; shift 2 ;;
      --delivery-account) delivery_account="${2:-}"; shift 2 ;;
      *) echo "{\"error\": \"Unknown option: $1\"}" >&2; exit 1 ;;
    esac
  done

  [ -n "$task" ] || { echo '{"error": "No task provided"}' >&2; exit 1; }
  [ -n "${next_action//[[:space:]]/}" ] || { echo '{"error": "next-action must not be blank"}' >&2; exit 1; }
  validate_nonnegative_integer "$timeout_secs" timeout
  validate_nonnegative_integer "$expect_min_bytes" expect-min-bytes
  validate_continuation_mode "$continuation_mode"
  if [ -n "$owner_agent_id$owner_session_key$delivery_channel$delivery_target$delivery_account" ]; then
    [ -n "$owner_agent_id" ] && [ -n "$owner_session_key" ] && [ -n "$delivery_channel" ] && [ -n "$delivery_target" ] && [ -n "$delivery_account" ] || {
      echo '{"error": "owner routing fields must be supplied together"}' >&2; exit 1;
    }
  fi

  local task_id reg_file
  task_id=$(gen_task_id "$label")
  reg_file="$REGISTRY_DIR/$task_id.json"
  budget=$(effective_budget "$budget")
  python3 "$STATE_TOOL" init --registry "$reg_file" --task-id "$task_id" \
    --label "$label" --workdir "$workdir" --model "$model" --budget "$budget" \
    --timeout-secs "$timeout_secs" --notify-cmd "$notify_cmd" --batch-id "$batch_id" \
    --expected-file "$expected_file" --expect-min-bytes "$expect_min_bytes" \
    "${allowed_root_args[@]}" --next-action "$next_action" --continuation-mode "$continuation_mode" \
    --owner-agent-id "$owner_agent_id" --owner-session-key "$owner_session_key" \
    --delivery-channel "$delivery_channel" --delivery-target "$delivery_target" --delivery-account "$delivery_account" >/dev/null

  (
    local exit_code=0
    CC_TASK_ID="$task_id" \
    CC_TIMEOUT="$timeout_secs" \
    CC_STREAM_FILE="$LOGS_DIR/${task_id}.stream" \
    CC_STDERR_FILE="$LOGS_DIR/${task_id}.stderr" \
    bash "$SCRIPT_DIR/run-task.sh" run "$workdir" "$budget" "$model" "$task" > "$LOGS_DIR/${task_id}.out" || exit_code=$?
    finish_task_from_output "$task_id" "$exit_code"
  ) > "$LOGS_DIR/${task_id}.wrapper.out" 2> "$LOGS_DIR/${task_id}.wrapper.stderr" &

  local bg_pid=$!
  python3 "$STATE_TOOL" patch-pid --registry "$reg_file" --pid "$bg_pid" >/dev/null
  disown "$bg_pid" 2>/dev/null || true

  python3 - "$reg_file" "$bg_pid" <<'PYOUT'
import json,sys
with open(sys.argv[1],encoding='utf-8') as handle: reg=json.load(handle)
print(json.dumps({
  'task_id':reg['task_id'], 'pid':int(sys.argv[2]), 'status':'dispatched',
  'label':reg['label'], 'model':reg['model'], 'budget':reg['budget'],
  'timeout_secs':reg['timeout_secs'], 'expected_file':reg.get('expected_file',''),
  'expected_file_canonical':reg.get('expected_file_canonical',''),
  'next_action':reg.get('next_action',''), 'continuation_mode':reg.get('continuation_mode','')
}))
PYOUT
}

cmd_poll() {
  local task_id="${1:-}"
  [ -n "$task_id" ] || { echo '{"error": "No task_id"}' >&2; exit 1; }
  local reg_file="$REGISTRY_DIR/${task_id}.json"
  [ -f "$reg_file" ] || { echo "{\"error\": \"Task not found: $task_id\"}"; exit 1; }

  refresh_from_output_if_ready "$task_id" >/dev/null
  local status pid
  readarray -t state_fields < <(python3 - "$reg_file" <<'PYSTATE'
import json,sys
with open(sys.argv[1],encoding='utf-8') as handle: reg=json.load(handle)
print(reg.get('status','')); print(reg.get('pid',''))
PYSTATE
)
  status="${state_fields[0]:-}"; pid="${state_fields[1]:-}"
  if [ "$status" = "running" ] && [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    python3 "$STATE_TOOL" terminal --registry "$reg_file" --status failed \
      --result-preview "worker_pid_dead_before_result" >/dev/null
    run_notify_hook "$task_id"
  fi

  python3 - "$reg_file" <<'PYOUT'
import json,os,sys
with open(sys.argv[1],encoding='utf-8') as handle: data=json.load(handle)
pid=data.get('pid','')
if pid and data.get('status')=='running':
    try: os.kill(int(pid),0); data['alive']=True
    except Exception: data['alive']=False
print(json.dumps(data,indent=2))
PYOUT
}

cmd_watch() {
  local task_id="${1:-}"
  if [ -z "$task_id" ]; then echo '{"error": "No task_id"}' >&2; exit 1; fi
  local stream_file="$LOGS_DIR/${task_id}.stream"
  if [ ! -f "$stream_file" ]; then
    echo "No stream file yet for $task_id"
    exit 1
  fi

  tail -n +1 -f "$stream_file" | python3 -c '
import json, sys
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        event = json.loads(raw)
    except Exception:
        continue
    t = event.get("type")
    if t == "system" and event.get("subtype") == "init":
        print(f"[init] session={event.get('"'"'session_id'"'"','"'"''"'"')} model={event.get('"'"'model'"'"','"'"''"'"')}", flush=True)
    elif t == "assistant":
        msg = event.get("message", {})
        texts = [b.get("text","").strip() for b in (msg.get("content") or []) if b.get("type") == "text" and b.get("text","").strip()]
        if texts:
            print(f"[assistant] {'"'"' '"'"'.join(texts)}", flush=True)
        else:
            print("[assistant] (non-text event)", flush=True)
    elif t == "result":
        print(f"[result] subtype={event.get('"'"'subtype'"'"','"'"''"'"')} cost=${event.get('"'"'total_cost_usd'"'"',0):.4f} turns={event.get('"'"'num_turns'"'"',0)} duration_ms={event.get('"'"'duration_ms'"'"',0)}", flush=True)
    else:
        print(f"[{t}]", flush=True)
'
}

cmd_result() {
  local mode="json"
  if [ "${1:-}" = "--text" ]; then
    mode="text"
    shift
  elif [ "${1:-}" = "--raw" ]; then
    mode="raw"
    shift
  fi

  local task_id="${1:-}"
  if [ -z "$task_id" ]; then echo '{"error": "No task_id"}' >&2; exit 1; fi

  local out_file="$LOGS_DIR/${task_id}.out"
  local stream_file="$LOGS_DIR/${task_id}.stream"

  case "$mode" in
    json)
      [ -f "$out_file" ] && cat "$out_file" || echo "{\"error\": \"No output file for task $task_id\"}"
      ;;
    text)
      if [ -f "$out_file" ]; then
        python3 - "$out_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    d = json.load(f)
print(d.get('result', ''))
PY
      else
        echo "No output file for task $task_id"
        exit 1
      fi
      ;;
    raw)
      [ -f "$stream_file" ] && cat "$stream_file" || echo "{\"error\": \"No stream file for task $task_id\"}"
      ;;
  esac
}

cmd_resume() {
  local task_id="${1:-}" budget="${2:-none}" follow_up="${3:-}"
  shift 3 || true
  local timeout_secs="0" notify_cmd="" expected_file="" expect_min_bytes="0"
  local next_action="Review the resumed terminal result and confirm the next action."
  local continuation_mode="continue"
  local owner_agent_id="" owner_session_key="" delivery_channel="" delivery_target="" delivery_account=""
  local -a allowed_root_args=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout) timeout_secs="${2:-0}"; shift 2 ;;
      --notify-cmd) notify_cmd="${2:-}"; shift 2 ;;
      --expect-file) expected_file="${2:-}"; shift 2 ;;
      --expect-min-bytes) expect_min_bytes="${2:-0}"; shift 2 ;;
      --allowed-root) allowed_root_args+=(--allowed-root "${2:-}"); shift 2 ;;
      --next-action) next_action="${2:-}"; shift 2 ;;
      --continuation-mode) continuation_mode="${2:-}"; shift 2 ;;
      --owner-agent-id) owner_agent_id="${2:-}"; shift 2 ;;
      --owner-session-key) owner_session_key="${2:-}"; shift 2 ;;
      --delivery-channel) delivery_channel="${2:-}"; shift 2 ;;
      --delivery-target) delivery_target="${2:-}"; shift 2 ;;
      --delivery-account) delivery_account="${2:-}"; shift 2 ;;
      *) echo "{\"error\": \"Unknown option: $1\"}" >&2; exit 1 ;;
    esac
  done
  [ -n "$task_id" ] && [ -n "$follow_up" ] || { echo '{"error": "Need task_id and follow-up prompt"}' >&2; exit 1; }
  validate_nonnegative_integer "$timeout_secs" timeout
  validate_nonnegative_integer "$expect_min_bytes" expect-min-bytes
  validate_continuation_mode "$continuation_mode"
  [ -n "${next_action//[[:space:]]/}" ] || { echo '{"error": "next-action must not be blank"}' >&2; exit 1; }

  local reg_file="$REGISTRY_DIR/${task_id}.json"
  [ -f "$reg_file" ] || { echo "{\"error\": \"Task not found: $task_id\"}"; exit 1; }
  local session_id label workdir model batch_id attempts=0
  while [ "$attempts" -lt 10 ]; do
    refresh_from_output_if_ready "$task_id" >/dev/null 2>&1 || true
    readarray -t parent_fields < <(python3 - "$reg_file" <<'PYPARENT'
import json,sys
with open(sys.argv[1],encoding='utf-8') as handle: reg=json.load(handle)
owner=reg.get('owner',{}); delivery=owner.get('delivery',{})
for value in (reg.get('session_id',''),reg.get('label','resume'),reg.get('workdir',''),reg.get('model',''),reg.get('batch_id',''),owner.get('agent_id',''),owner.get('session_key',''),delivery.get('channel',''),delivery.get('target',''),delivery.get('account','')): print(value)
PYPARENT
)
    session_id="${parent_fields[0]:-}"; label="${parent_fields[1]:-resume}"; workdir="${parent_fields[2]:-}"
    model="${parent_fields[3]:-}"; batch_id="${parent_fields[4]:-}"
    [ -n "$owner_agent_id" ] || owner_agent_id="${parent_fields[5]:-}"
    [ -n "$owner_session_key" ] || owner_session_key="${parent_fields[6]:-}"
    [ -n "$delivery_channel" ] || delivery_channel="${parent_fields[7]:-}"
    [ -n "$delivery_target" ] || delivery_target="${parent_fields[8]:-}"
    [ -n "$delivery_account" ] || delivery_account="${parent_fields[9]:-}"
    [ -n "$session_id" ] && break
    attempts=$((attempts + 1)); sleep 1
  done
  [ -n "$session_id" ] || { echo "{\"error\": \"No session_id found for task $task_id after waiting — cannot resume\"}"; exit 1; }
  if [ -n "$owner_agent_id$owner_session_key$delivery_channel$delivery_target$delivery_account" ]; then
    [ -n "$owner_agent_id" ] && [ -n "$owner_session_key" ] && [ -n "$delivery_channel" ] && [ -n "$delivery_target" ] && [ -n "$delivery_account" ] || {
      echo '{"error": "owner routing fields must be supplied together"}' >&2; exit 1;
    }
  fi

  local resume_id="${task_id}-r$(date +%s)"
  local resume_reg="$REGISTRY_DIR/${resume_id}.json"
  budget=$(effective_budget "$budget")
  python3 "$STATE_TOOL" init --registry "$resume_reg" --task-id "$resume_id" --session-id "$session_id" \
    --label "${label}-resume" --workdir "$workdir" --model "$model" --budget "$budget" \
    --timeout-secs "$timeout_secs" --notify-cmd "$notify_cmd" --batch-id "$batch_id" --resumed-from "$task_id" \
    --expected-file "$expected_file" --expect-min-bytes "$expect_min_bytes" "${allowed_root_args[@]}" \
    --next-action "$next_action" --continuation-mode "$continuation_mode" \
    --owner-agent-id "$owner_agent_id" --owner-session-key "$owner_session_key" \
    --delivery-channel "$delivery_channel" --delivery-target "$delivery_target" --delivery-account "$delivery_account" >/dev/null

  (
    local exit_code=0
    CC_TASK_ID="$resume_id" CC_MODEL="$model" CC_TIMEOUT="$timeout_secs" \
    CC_STREAM_FILE="$LOGS_DIR/${resume_id}.stream" CC_STDERR_FILE="$LOGS_DIR/${resume_id}.stderr" \
    bash "$SCRIPT_DIR/run-task.sh" resume "$session_id" "$budget" "$follow_up" "$workdir" > "$LOGS_DIR/${resume_id}.out" || exit_code=$?
    finish_task_from_output "$resume_id" "$exit_code"
  ) > "$LOGS_DIR/${resume_id}.wrapper.out" 2> "$LOGS_DIR/${resume_id}.wrapper.stderr" &

  local bg_pid=$!
  python3 "$STATE_TOOL" patch-pid --registry "$resume_reg" --pid "$bg_pid" >/dev/null
  disown "$bg_pid" 2>/dev/null || true
  echo "{\"task_id\": \"$resume_id\", \"resumed_from\": \"$task_id\", \"session_id\": \"$session_id\", \"pid\": $bg_pid, \"status\": \"dispatched\"}"
}

cmd_batch() {
  local manifest="${1:-}"
  shift || true
  local max_parallel="2"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max-parallel) max_parallel="${2:-2}"; shift 2 ;;
      *) echo "{\"error\": \"Unknown option: $1\"}" >&2; exit 1 ;;
    esac
  done

  [ -n "$manifest" ] || { echo '{"error": "Need manifest path"}' >&2; exit 1; }
  [ -f "$manifest" ] || { echo "{\"error\": \"Manifest not found: $manifest\"}" >&2; exit 1; }

  local batch_id="batch-$(date +%s)-$$"
  local tmp_handles="/tmp/${batch_id}.handles"
  : > "$tmp_handles"

  while IFS= read -r encoded; do
    [ -n "$encoded" ] || continue
    eval "$(python3 - "$encoded" <<'PY'
import base64, json, shlex, sys
row = json.loads(base64.b64decode(sys.argv[1]).decode())
for k in ['workdir','budget','model','label','task','timeout']:
    print(f"{k.upper()}={shlex.quote(str(row.get(k,'')))}")
PY
)"

    while true; do
      local running_count
      running_count=$(python3 - "$REGISTRY_DIR" "$batch_id" <<'PY'
import glob, json, os, sys
reg_dir, batch_id = sys.argv[1:3]
count = 0
for path in glob.glob(os.path.join(reg_dir, '*.json')):
    try:
        with open(path, encoding='utf-8') as f:
            d = json.load(f)
        if d.get('batch_id') == batch_id and d.get('status') == 'running':
            count += 1
    except Exception:
        pass
print(count)
PY
)
      [ "$running_count" -lt "$max_parallel" ] && break
      sleep 2
    done

    if [ -n "$TIMEOUT" ]; then
      bash "$0" dispatch "$WORKDIR" "$BUDGET" "$MODEL" "$LABEL" "$TASK" --timeout "$TIMEOUT" --batch-id "$batch_id" | tee -a "$tmp_handles"
    else
      bash "$0" dispatch "$WORKDIR" "$BUDGET" "$MODEL" "$LABEL" "$TASK" --batch-id "$batch_id" | tee -a "$tmp_handles"
    fi
    sleep 1
  done < <(python3 - "$manifest" <<'PY'
import base64, json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        print(base64.b64encode(line.encode()).decode())
PY
)

  echo "==="
  echo "{\"batch_id\": \"$batch_id\", \"manifest\": \"$manifest\", \"handles_file\": \"$tmp_handles\"}"
}

cmd_list() {
  local filter="${1:---all}"
  python3 - "$REGISTRY_DIR" "$filter" <<'PY'
import json, glob, os, sys
reg_dir, filt = sys.argv[1:3]
tasks = []
for f in glob.glob(os.path.join(reg_dir, '*.json')):
    try:
        with open(f, encoding='utf-8') as fh:
            d = json.load(fh)
        tasks.append(d)
    except Exception:
        pass
tasks.sort(key=lambda x: x.get('updated_at', ''), reverse=True)
if filt == '--running':
    tasks = [t for t in tasks if t.get('status') == 'running']
elif filt == '--done':
    tasks = [t for t in tasks if t.get('status') == 'done']
elif filt == '--failed':
    tasks = [t for t in tasks if t.get('status') in ('failed','timeout')]
if not tasks:
    print('No tasks found.')
else:
    for t in tasks[:30]:
        sid = (t.get('session_id') or '')[:12]
        cost = t.get('cost_usd', 0) or 0
        extra = f" batch:{t.get('batch_id')}" if t.get('batch_id') else ''
        print(f"{t.get('status','?'):8} | {t.get('task_id','?'):40} | ${cost:.3f} | {t.get('label','')} | sid:{sid}{extra}")
PY
}

cmd_cancel() {
  local task_id="${1:-}"
  if [ -z "$task_id" ]; then echo '{"error": "No task_id"}' >&2; exit 1; fi
  local reg_file="$REGISTRY_DIR/${task_id}.json"
  [ -f "$reg_file" ] || { echo "{\"error\": \"Task not found: $task_id\"}"; exit 1; }

  local pid
  pid=$(python3 -c "import json; print(json.load(open('$reg_file')).get('pid', ''))")
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null && echo "Killed PID $pid" || echo "PID $pid not running"
    pkill -P "$pid" 2>/dev/null || true
  fi
  python3 "$STATE_TOOL" cancel --registry "$reg_file" >/dev/null
  run_notify_hook "$task_id"
  echo "{\"task_id\": \"$task_id\", \"status\": \"cancelled\"}"
}

cmd_decide() {
  local task_id="${1:-}" decision="${2:-}"
  shift 2 || true
  local reason="" next_action="" owner="" retry_trigger=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      --next-action) next_action="${2:-}"; shift 2 ;;
      --owner) owner="${2:-}"; shift 2 ;;
      --retry-trigger) retry_trigger="${2:-}"; shift 2 ;;
      *) echo "{\"error\": \"Unknown option: $1\"}" >&2; exit 1 ;;
    esac
  done
  [ -n "$task_id" ] && [ -n "$decision" ] || { echo '{"error": "Need task_id and decision"}' >&2; exit 1; }
  local reg_file="$REGISTRY_DIR/${task_id}.json"
  [ -f "$reg_file" ] || { echo "{\"error\": \"Task not found: $task_id\"}" >&2; exit 1; }
  python3 "$STATE_TOOL" decide --registry "$reg_file" --decision "$decision" \
    --reason "$reason" --next-action "$next_action" --owner "$owner" --retry-trigger "$retry_trigger"
}

cmd_costs() {
  local filter="${1:---today}"
  if [ ! -f "$COST_LOG" ]; then
    echo "No cost data yet."
    exit 0
  fi
  python3 - "$COST_LOG" "$filter" <<'PY'
import json, sys
from datetime import datetime
cost_log, filt = sys.argv[1:3]
entries = []
with open(cost_log, encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except Exception:
            pass
if filt == '--today':
    today = datetime.now().strftime('%Y-%m-%d')
    entries = [e for e in entries if e.get('ts', '').startswith(today)]
total = sum(e.get('cost_usd', 0) for e in entries)
by_model = {}
for e in entries:
    m = e.get('model', 'unknown')
    by_model[m] = by_model.get(m, 0) + e.get('cost_usd', 0)
print(f'Tasks: {len(entries)}')
print(f'Total cost: ${total:.4f}')
print('By model:')
for m, c in sorted(by_model.items(), key=lambda x: -x[1]):
    print(f'  {m}: ${c:.4f}')
print('By task:')
for e in entries[-10:]:
    print(f"  {e.get('task_id','?'):40} | ${e.get('cost_usd',0):.4f} | {e.get('status','?')}")
PY
}

cmd_cleanup() {
  local count=0
  for f in "$REGISTRY_DIR"/*.json; do
    [ -f "$f" ] || continue
    local age=$(( ($(date +%s) - $(stat -c %Y "$f")) / 3600 ))
    if [ "$age" -gt 48 ]; then
      local status
      status=$(python3 -c "import json; print(json.load(open('$f')).get('status', ''))" 2>/dev/null)
      if [ "$status" = "done" ] || [ "$status" = "failed" ] || [ "$status" = "cancelled" ] || [ "$status" = "timeout" ] || [ "$status" = "incomplete" ]; then
        rm -f "$f" "$f.lock" "${f%.json}.announced"
        count=$((count + 1))
      fi
    fi
  done
  find "$LOGS_DIR" -name "*.out" -mmin +2880 -delete 2>/dev/null || true
  find "$LOGS_DIR" -name "*.stream" -mmin +2880 -delete 2>/dev/null || true
  find "$LOGS_DIR" -name "*.stderr" -mmin +2880 -delete 2>/dev/null || true
  find "$RESULTS_DIR" -name "*.json" -mmin +2880 -delete 2>/dev/null || true
  find "$HOOKS_DIR" -type f -mmin +2880 -delete 2>/dev/null || true
  echo "Cleaned $count old registry entries and old logs/results"
}

CMD="${1:-}"
shift || true

case "$CMD" in
  dispatch) cmd_dispatch "$@" ;;
  poll)     cmd_poll "$@" ;;
  watch)    cmd_watch "$@" ;;
  result)   cmd_result "$@" ;;
  resume)   cmd_resume "$@" ;;
  batch)    cmd_batch "$@" ;;
  list)     cmd_list "$@" ;;
  cancel)   cmd_cancel "$@" ;;
  decide)   cmd_decide "$@" ;;
  costs)    cmd_costs "$@" ;;
  cleanup)  cmd_cleanup "$@" ;;
  *)
    echo "Claude Code Orchestrator"
    echo ""
    echo "Commands:"
    echo "  dispatch <workdir> <budget|none> <model> <label> \"<task>\" [--timeout N] [--notify-cmd CMD] [--expect-file PATH] [--expect-min-bytes N] [--allowed-root PATH] [--next-action TEXT] [--continuation-mode MODE] [explicit owner routing fields]"
    echo "  poll <task-id>"
    echo "  watch <task-id>"
    echo "  result [--text|--raw] <task-id>"
    echo "  resume <task-id> <budget|none> \"<follow-up>\" [--timeout N] [--notify-cmd CMD] [--expect-file PATH] [--expect-min-bytes N] [--next-action TEXT] [--continuation-mode continue|switch|blocked|complete]"
    echo "  batch <manifest.jsonl> [--max-parallel N]"
    echo "  list [--running|--done|--failed|--all]"
    echo "  cancel <task-id>"
    echo "  decide <task-id> <continue|switch|blocked|complete> [--reason TEXT] [--next-action TEXT] [--owner TEXT] [--retry-trigger TEXT]"
    echo "  costs [--today|--all]"
    echo "  cleanup"
    ;;
esac
