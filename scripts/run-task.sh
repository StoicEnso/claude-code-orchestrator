#!/bin/bash
# Claude Code Subagent Runner
#
# Modes:
#   run     — one-shot task (default)
#   resume  — continue a previous session
#   status  — check if a session exists and show its last result
#   clean   — remove old result files
#
# Usage:
#   run-task.sh run    <workdir> <budget> <model> <task-description>
#   run-task.sh resume <session-id> <budget> <task-description> [workdir]
#   run-task.sh status <session-id>
#
# Models: opus (default), sonnet, haiku
# Output: JSON to stdout with structured result
#
# Environment:
#   CC_TASK_ID       — optional task ID for tracking
#   CC_TIMEOUT       — optional timeout in seconds (0 = no timeout)
#   CC_STREAM_FILE   — optional raw stream log path
#   CC_STDERR_FILE   — optional stderr log path

set -euo pipefail

RESULTS_DIR="/tmp/claude-subagent-results"
LOGS_DIR="/tmp/claude-subagent-logs"
mkdir -p "$RESULTS_DIR" "$LOGS_DIR"

MODE="${1:-run}"

parse_stream() {
  local stream_file="$1"
  local output_file="$2"
  local task_id="$3"
  local status_hint="$4"
  local session_hint="${5:-}"
  local exit_code="${6:-0}"

  python3 - "$stream_file" "$output_file" "$task_id" "$status_hint" "$session_hint" "$exit_code" <<'PY'
import json, sys, os
from pathlib import Path

stream_file, output_file, task_id, status_hint, session_hint, exit_code = sys.argv[1:7]
exit_code = int(exit_code)

session_id = session_hint or ""
assistant_texts = []
result_event = None
models = []
stream_events = 0
last_event_type = ""
errors = []

if os.path.exists(stream_file):
    with open(stream_file, 'r', encoding='utf-8', errors='replace') as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                event = json.loads(raw)
            except Exception:
                continue
            stream_events += 1
            last_event_type = event.get('type', '')
            if event.get('type') == 'system' and event.get('subtype') == 'init':
                session_id = event.get('session_id') or session_id
            elif event.get('type') == 'assistant':
                session_id = event.get('session_id') or session_id
                msg = event.get('message', {})
                for block in msg.get('content', []) or []:
                    if block.get('type') == 'text' and block.get('text'):
                        assistant_texts.append(block.get('text'))
            elif event.get('type') == 'result':
                result_event = event
                session_id = event.get('session_id') or session_id
                models = list((event.get('modelUsage') or {}).keys())
                errors = event.get('errors') or []

result_text = "\n\n".join(t.strip() for t in assistant_texts if t and t.strip()).strip()
if result_event and result_event.get('result'):
    result_text = result_event.get('result')

status = status_hint
if exit_code == 124:
    status = 'timeout'
elif result_event is not None:
    status = 'ok' if not result_event.get('is_error', False) else 'error'
elif status_hint not in ('ok', 'error', 'timeout'):
    status = 'error' if exit_code else 'ok'

out = {
    'status': status,
    'task_id': task_id,
    'session_id': session_id,
    'result': result_text or (errors[0] if errors else 'no result'),
    'cost_usd': (result_event or {}).get('total_cost_usd', 0),
    'turns': (result_event or {}).get('num_turns', 0),
    'duration_ms': (result_event or {}).get('duration_ms', 0),
    'model': models,
    'stop_reason': (result_event or {}).get('stop_reason', ''),
    'result_subtype': (result_event or {}).get('subtype', ''),
    'stream_events': stream_events,
    'last_event_type': last_event_type,
    'output_file': output_file,
    'stream_file': stream_file,
    'exit_code': exit_code,
}

Path(output_file).write_text(json.dumps(out, indent=2), encoding='utf-8')
print(json.dumps(out, indent=2))
PY
}

run_claude_stream() {
  local workdir="$1"
  local budget="$2"
  local model="$3"
  local task="$4"
  local stream_file="$5"
  local stderr_file="$6"
  local timeout_secs="$7"

  local -a cmd=(claude --print --output-format stream-json --verbose --max-budget-usd "$budget" --model "$model" -p "$task")

  cd "$workdir"
  if [ "$timeout_secs" != "0" ] && [ -n "$timeout_secs" ]; then
    timeout --signal=TERM "$timeout_secs" "${cmd[@]}" > "$stream_file" 2> "$stderr_file"
  else
    "${cmd[@]}" > "$stream_file" 2> "$stderr_file"
  fi
}

resume_claude_stream() {
  local session_id="$1"
  local budget="$2"
  local task="$3"
  local stream_file="$4"
  local stderr_file="$5"
  local timeout_secs="$6"

  local -a cmd=(claude --print --output-format stream-json --verbose --max-budget-usd "$budget" --resume "$session_id" -p "$task")

  if [ "$timeout_secs" != "0" ] && [ -n "$timeout_secs" ]; then
    timeout --signal=TERM "$timeout_secs" "${cmd[@]}" > "$stream_file" 2> "$stderr_file"
  else
    "${cmd[@]}" > "$stream_file" 2> "$stderr_file"
  fi
}

case "$MODE" in
  run)
    WORKDIR="${2:-.}"
    BUDGET="${3:-1.00}"
    MODEL="${4:-opus}"
    TASK="${5:-}"

    if [ -z "$TASK" ]; then
      echo '{"error": "No task provided", "usage": "run-task.sh run <workdir> <budget> <model> <task>"}' >&2
      exit 1
    fi

    TASK_ID="${CC_TASK_ID:-$(date +%s)-$$}"
    OUTPUT_FILE="$RESULTS_DIR/${TASK_ID}.json"
    STREAM_FILE="${CC_STREAM_FILE:-$LOGS_DIR/${TASK_ID}.stream}"
    STDERR_FILE="${CC_STDERR_FILE:-$LOGS_DIR/${TASK_ID}.stderr}"
    TIMEOUT_SECS="${CC_TIMEOUT:-0}"

    STATUS_HINT="ok"
    EXIT_CODE=0
    set +e
    run_claude_stream "$WORKDIR" "$BUDGET" "$MODEL" "$TASK" "$STREAM_FILE" "$STDERR_FILE" "$TIMEOUT_SECS"
    EXIT_CODE=$?
    set -e
    if [ "$EXIT_CODE" -eq 124 ]; then
      STATUS_HINT="timeout"
    elif [ "$EXIT_CODE" -ne 0 ]; then
      STATUS_HINT="error"
    fi

    parse_stream "$STREAM_FILE" "$OUTPUT_FILE" "$TASK_ID" "$STATUS_HINT" "" "$EXIT_CODE"
    ;;

  resume)
    SESSION_ID="${2:-}"
    BUDGET="${3:-1.00}"
    TASK="${4:-}"
    WORKDIR="${5:-.}"

    if [ -z "$SESSION_ID" ] || [ -z "$TASK" ]; then
      echo '{"error": "Need session_id and task", "usage": "run-task.sh resume <session-id> <budget> <task> [workdir]"}' >&2
      exit 1
    fi

    TASK_ID="${CC_TASK_ID:-resume-$(date +%s)-$$}"
    OUTPUT_FILE="$RESULTS_DIR/${TASK_ID}.json"
    STREAM_FILE="${CC_STREAM_FILE:-$LOGS_DIR/${TASK_ID}.stream}"
    STDERR_FILE="${CC_STDERR_FILE:-$LOGS_DIR/${TASK_ID}.stderr}"
    TIMEOUT_SECS="${CC_TIMEOUT:-0}"

    STATUS_HINT="ok"
    EXIT_CODE=0
    cd "$WORKDIR"
    set +e
    resume_claude_stream "$SESSION_ID" "$BUDGET" "$TASK" "$STREAM_FILE" "$STDERR_FILE" "$TIMEOUT_SECS"
    EXIT_CODE=$?
    set -e
    if [ "$EXIT_CODE" -eq 124 ]; then
      STATUS_HINT="timeout"
    elif [ "$EXIT_CODE" -ne 0 ]; then
      STATUS_HINT="error"
    fi

    parse_stream "$STREAM_FILE" "$OUTPUT_FILE" "$TASK_ID" "$STATUS_HINT" "$SESSION_ID" "$EXIT_CODE"
    ;;

  status)
    SESSION_ID="${2:-}"

    if [ -z "$SESSION_ID" ]; then
      echo "Recent Claude Code results:"
      ls -lt "$RESULTS_DIR"/*.json 2>/dev/null | head -10
      exit 0
    fi

    python3 - "$RESULTS_DIR" "$SESSION_ID" <<'PY'
import json, glob, os, sys
results_dir, session_id = sys.argv[1:3]
results = []
for f in glob.glob(os.path.join(results_dir, '*.json')):
    try:
        with open(f, encoding='utf-8') as fh:
            d = json.load(fh)
        sid = d.get('session_id', '')
        if sid == session_id or d.get('resumed_from', '') == session_id:
            results.append({
                'file': f,
                'task_id': d.get('task_id', ''),
                'session_id': sid,
                'status': d.get('status', '?'),
                'cost_usd': d.get('cost_usd', 0),
                'result_preview': str(d.get('result', ''))[:200],
                'mtime': os.path.getmtime(f)
            })
    except Exception:
        pass
results.sort(key=lambda x: x.get('mtime', 0))
if results:
    print(json.dumps(results, indent=2))
else:
    print(json.dumps({'error': f'No results found for session {session_id}'}))
PY
    ;;

  clean)
    find "$RESULTS_DIR" -name "*.json" -mmin +1440 -delete 2>/dev/null || true
    find "$LOGS_DIR" -name "*.stream" -mmin +1440 -delete 2>/dev/null || true
    find "$LOGS_DIR" -name "*.stderr" -mmin +1440 -delete 2>/dev/null || true
    echo "Cleaned old results and stream logs"
    ;;

  *)
    echo "Usage: $0 {run|resume|status|clean} [args...]" >&2
    exit 1
    ;;
esac
