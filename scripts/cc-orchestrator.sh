#!/bin/bash
# Claude Code Orchestrator
# High-level task management layer on top of run-task.sh
#
# Commands:
#   dispatch  — Submit a task, get a handle back immediately
#   poll      — Check if a task is done
#   result    — Get the full result of a completed task
#   resume    — Send a correction/continuation to a task
#   list      — Show all tracked tasks
#   cancel    — Kill a running task
#   costs     — Show cost summary across all tasks
#   cleanup   — Archive completed tasks, remove old data
#
# Usage:
#   cc-orchestrator.sh dispatch <workdir> <budget> <model> <label> "<task>"
#   cc-orchestrator.sh poll <task-id>
#   cc-orchestrator.sh result <task-id>
#   cc-orchestrator.sh resume <task-id> <budget> "<follow-up>"
#   cc-orchestrator.sh list [--running|--done|--failed|--all]
#   cc-orchestrator.sh cancel <task-id>
#   cc-orchestrator.sh costs [--today|--all]
#   cc-orchestrator.sh cleanup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY_DIR="/tmp/claude-subagent-registry"
RESULTS_DIR="/tmp/claude-subagent-results"
LOGS_DIR="/tmp/claude-subagent-logs"
COST_LOG="/tmp/claude-subagent-costs.jsonl"

mkdir -p "$REGISTRY_DIR" "$RESULTS_DIR" "$LOGS_DIR"

# ─── helpers ───

gen_task_id() {
  local label="${1:-task}"
  local clean_label=$(echo "$label" | tr ' /' '-' | tr -cd 'a-zA-Z0-9-' | head -c 30)
  echo "${clean_label}-$(date +%s)-$$"
}

write_registry() {
  local task_id="$1"
  local status="$2"
  local session_id="${3:-}"
  local label="${4:-}"
  local workdir="${5:-}"
  local model="${6:-}"
  local budget="${7:-}"
  local pid="${8:-}"
  local cost="${9:-0}"
  local result_preview="${10:-}"
  
  python3 -c "
import json, os, time
entry = {
    'task_id': '$task_id',
    'status': '$status',
    'session_id': '$session_id',
    'label': '''$label''',
    'workdir': '$workdir',
    'model': '$model',
    'budget': '$budget',
    'pid': '$pid',
    'cost_usd': float('$cost') if '$cost' else 0,
    'result_preview': '''$result_preview'''[:200],
    'updated_at': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
    'started_at': time.strftime('%Y-%m-%dT%H:%M:%S%z') if '$status' == 'running' else ''
}
# Merge with existing entry if present
reg_file = '$REGISTRY_DIR/$task_id.json'
if os.path.exists(reg_file):
    try:
        with open(reg_file) as f:
            existing = json.load(f)
        existing.update({k: v for k, v in entry.items() if v})
        entry = existing
    except: pass
entry['status'] = '$status'
entry['updated_at'] = time.strftime('%Y-%m-%dT%H:%M:%S%z')
with open(reg_file, 'w') as f:
    json.dump(entry, f, indent=2)
"
}

# ─── dispatch ───

cmd_dispatch() {
  local workdir="${1:-.}"
  local budget="${2:-1.00}"
  local model="${3:-sonnet}"
  local label="${4:-task}"
  local task="${5:-}"
  
  if [ -z "$task" ]; then
    echo '{"error": "No task provided"}' >&2
    echo "Usage: cc-orchestrator.sh dispatch <workdir> <budget> <model> <label> \"<task>\"" >&2
    exit 1
  fi
  
  local task_id=$(gen_task_id "$label")
  
  # Register as running
  write_registry "$task_id" "running" "" "$label" "$workdir" "$model" "$budget" "" "0" ""
  
  # Launch in background
  (
    CC_TASK_ID="$task_id" bash "$SCRIPT_DIR/run-task.sh" run "$workdir" "$budget" "$model" "$task" \
      > "$LOGS_DIR/${task_id}.out" 2>&1
    
    EXIT_CODE=$?
    
    # Parse result and update registry
    if [ -f "$LOGS_DIR/${task_id}.out" ]; then
      python3 -c "
import json, sys
try:
    with open('$LOGS_DIR/${task_id}.out') as f:
        content = f.read().strip()
    # Try parsing whole file as JSON first (output is multi-line JSON)
    d = None
    try:
        d = json.loads(content)
    except:
        d = None
    if not d:
        d = {'status': 'error', 'error': 'no parseable output'}
    
    status = 'done' if d.get('status') == 'ok' else 'failed'
    session_id = d.get('session_id', '')
    cost = d.get('cost_usd', 0)
    result = d.get('result', d.get('error', ''))[:200]
    
    # Update registry
    import os, time
    reg_file = '$REGISTRY_DIR/$task_id.json'
    if os.path.exists(reg_file):
        with open(reg_file) as f:
            entry = json.load(f)
    else:
        entry = {}
    
    entry.update({
        'status': status,
        'session_id': session_id,
        'cost_usd': cost,
        'result_preview': result,
        'updated_at': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'exit_code': $EXIT_CODE
    })
    
    with open(reg_file, 'w') as f:
        json.dump(entry, f, indent=2)
    
    # Append to cost log
    cost_entry = {
        'task_id': '$task_id',
        'label': entry.get('label', ''),
        'model': entry.get('model', ''),
        'cost_usd': cost,
        'status': status,
        'ts': time.strftime('%Y-%m-%dT%H:%M:%S%z')
    }
    with open('$COST_LOG', 'a') as f:
        f.write(json.dumps(cost_entry) + '\n')
        
except Exception as e:
    import time
    reg_file = '$REGISTRY_DIR/$task_id.json'
    with open(reg_file, 'w') as f:
        json.dump({'task_id': '$task_id', 'status': 'failed', 'error': str(e), 'updated_at': time.strftime('%Y-%m-%dT%H:%M:%S%z')}, f)
" 2>/dev/null
    fi
  ) &
  
  local bg_pid=$!
  
  # Update registry with PID
  write_registry "$task_id" "running" "" "$label" "$workdir" "$model" "$budget" "$bg_pid" "0" ""
  
  # Return the handle immediately
  echo "{\"task_id\": \"$task_id\", \"pid\": $bg_pid, \"status\": \"dispatched\", \"label\": \"$label\", \"model\": \"$model\", \"budget\": \"$budget\"}"
}

# ─── poll ───

cmd_poll() {
  local task_id="${1:-}"
  if [ -z "$task_id" ]; then echo '{"error": "No task_id"}' >&2; exit 1; fi
  
  local reg_file="$REGISTRY_DIR/${task_id}.json"
  if [ ! -f "$reg_file" ]; then
    echo "{\"error\": \"Task not found: $task_id\"}"
    exit 1
  fi
  
  python3 -c "
import json
with open('$reg_file') as f:
    d = json.load(f)
# Check if PID is still running
pid = d.get('pid', '')
if pid and d.get('status') == 'running':
    import os
    try:
        os.kill(int(pid), 0)
        d['alive'] = True
    except:
        d['alive'] = False
        # Process died but registry not updated — check output
        d['status'] = 'unknown-check-result'
print(json.dumps(d, indent=2))
"
}

# ─── result ───

cmd_result() {
  local task_id="${1:-}"
  if [ -z "$task_id" ]; then echo '{"error": "No task_id"}' >&2; exit 1; fi
  
  local out_file="$LOGS_DIR/${task_id}.out"
  if [ -f "$out_file" ]; then
    cat "$out_file"
  else
    echo "{\"error\": \"No output file for task $task_id\"}"
  fi
}

# ─── resume ───

cmd_resume() {
  local task_id="${1:-}"
  local budget="${2:-0.50}"
  local follow_up="${3:-}"
  
  if [ -z "$task_id" ] || [ -z "$follow_up" ]; then
    echo '{"error": "Need task_id and follow-up prompt"}' >&2
    exit 1
  fi
  
  local reg_file="$REGISTRY_DIR/${task_id}.json"
  if [ ! -f "$reg_file" ]; then
    echo "{\"error\": \"Task not found: $task_id\"}"
    exit 1
  fi
  
  # Get session_id from registry
  local session_id=$(python3 -c "import json; print(json.load(open('$reg_file')).get('session_id', ''))")
  
  if [ -z "$session_id" ]; then
    echo "{\"error\": \"No session_id found for task $task_id — cannot resume\"}"
    exit 1
  fi
  
  local resume_id="${task_id}-r$(date +%s)"
  
  # Register the resume
  local label=$(python3 -c "import json; print(json.load(open('$reg_file')).get('label', 'resume'))")
  write_registry "$resume_id" "running" "$session_id" "${label}-resume" "" "" "$budget" "" "0" ""
  
  # Launch resume in background
  (
    CC_TASK_ID="$resume_id" bash "$SCRIPT_DIR/run-task.sh" resume "$session_id" "$budget" "$follow_up" \
      > "$LOGS_DIR/${resume_id}.out" 2>&1
    
    # Parse and update registry (same as dispatch)
    python3 -c "
import json, os, time
try:
    with open('$LOGS_DIR/${resume_id}.out') as f:
        content = f.read().strip()
    try:
        d = json.loads(content)
    except:
        d = None
    if not d:
        d = {'status': 'error', 'error': 'no parseable output'}
    
    status = 'done' if d.get('status') == 'ok' else 'failed'
    reg_file = '$REGISTRY_DIR/$resume_id.json'
    if os.path.exists(reg_file):
        with open(reg_file) as f:
            entry = json.load(f)
    else:
        entry = {}
    
    entry.update({
        'status': status,
        'session_id': d.get('session_id', '$session_id'),
        'resumed_from': '$task_id',
        'cost_usd': d.get('cost_usd', 0),
        'result_preview': d.get('result', '')[:200],
        'updated_at': time.strftime('%Y-%m-%dT%H:%M:%S%z')
    })
    with open(reg_file, 'w') as f:
        json.dump(entry, f, indent=2)
    
    with open('$COST_LOG', 'a') as f:
        f.write(json.dumps({'task_id': '$resume_id', 'label': entry.get('label',''), 'cost_usd': d.get('cost_usd',0), 'status': status, 'ts': time.strftime('%Y-%m-%dT%H:%M:%S%z')}) + '\n')
except Exception as e:
    with open('$REGISTRY_DIR/$resume_id.json', 'w') as f:
        json.dump({'task_id': '$resume_id', 'status': 'failed', 'error': str(e)}, f)
" 2>/dev/null
  ) &
  
  echo "{\"task_id\": \"$resume_id\", \"resumed_from\": \"$task_id\", \"session_id\": \"$session_id\", \"pid\": $!, \"status\": \"dispatched\"}"
}

# ─── list ───

cmd_list() {
  local filter="${1:---all}"
  
  python3 -c "
import json, glob, os
tasks = []
for f in glob.glob('$REGISTRY_DIR/*.json'):
    try:
        with open(f) as fh:
            d = json.load(fh)
        tasks.append(d)
    except: pass

tasks.sort(key=lambda x: x.get('updated_at', ''), reverse=True)

filt = '$filter'
if filt == '--running':
    tasks = [t for t in tasks if t.get('status') == 'running']
elif filt == '--done':
    tasks = [t for t in tasks if t.get('status') == 'done']
elif filt == '--failed':
    tasks = [t for t in tasks if t.get('status') == 'failed']

if not tasks:
    print('No tasks found.')
else:
    for t in tasks[:20]:
        sid = t.get('session_id', '')[:12]
        cost = t.get('cost_usd', 0)
        print(f'{t.get(\"status\",\"?\"):8} | {t.get(\"task_id\",\"?\"):40} | \${cost:.3f} | {t.get(\"label\",\"\")} | sid:{sid}')
"
}

# ─── cancel ───

cmd_cancel() {
  local task_id="${1:-}"
  if [ -z "$task_id" ]; then echo '{"error": "No task_id"}' >&2; exit 1; fi
  
  local reg_file="$REGISTRY_DIR/${task_id}.json"
  if [ ! -f "$reg_file" ]; then
    echo "{\"error\": \"Task not found: $task_id\"}"
    exit 1
  fi
  
  local pid=$(python3 -c "import json; print(json.load(open('$reg_file')).get('pid', ''))")
  
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null && echo "Killed PID $pid" || echo "PID $pid not running"
    # Also kill any child claude processes
    pkill -P "$pid" 2>/dev/null || true
  fi
  
  write_registry "$task_id" "cancelled" "" "" "" "" "" "" "0" ""
  echo "{\"task_id\": \"$task_id\", \"status\": \"cancelled\"}"
}

# ─── costs ───

cmd_costs() {
  local filter="${1:---today}"
  
  if [ ! -f "$COST_LOG" ]; then
    echo "No cost data yet."
    exit 0
  fi
  
  python3 -c "
import json, sys
from datetime import datetime, timedelta

entries = []
with open('$COST_LOG') as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                entries.append(json.loads(line))
            except: pass

filt = '$filter'
if filt == '--today':
    today = datetime.now().strftime('%Y-%m-%d')
    entries = [e for e in entries if e.get('ts', '').startswith(today)]

total = sum(e.get('cost_usd', 0) for e in entries)
by_model = {}
for e in entries:
    m = e.get('model', 'unknown')
    by_model[m] = by_model.get(m, 0) + e.get('cost_usd', 0)

print(f'Tasks: {len(entries)}')
print(f'Total cost: \${total:.4f}')
print(f'By model:')
for m, c in sorted(by_model.items(), key=lambda x: -x[1]):
    print(f'  {m}: \${c:.4f}')
print(f'By task:')
for e in entries[-10:]:
    print(f'  {e.get(\"task_id\",\"?\"):40} | \${e.get(\"cost_usd\",0):.4f} | {e.get(\"status\",\"?\")}')
"
}

# ─── cleanup ───

cmd_cleanup() {
  # Archive completed tasks older than 48h
  local count=0
  for f in "$REGISTRY_DIR"/*.json; do
    [ -f "$f" ] || continue
    local age=$(( ($(date +%s) - $(stat -c %Y "$f")) / 3600 ))
    if [ "$age" -gt 48 ]; then
      local status=$(python3 -c "import json; print(json.load(open('$f')).get('status', ''))" 2>/dev/null)
      if [ "$status" = "done" ] || [ "$status" = "failed" ] || [ "$status" = "cancelled" ]; then
        rm -f "$f"
        count=$((count + 1))
      fi
    fi
  done
  
  # Clean old output logs
  find "$LOGS_DIR" -name "*.out" -mmin +2880 -delete 2>/dev/null
  find "$RESULTS_DIR" -name "*.json" -mmin +2880 -delete 2>/dev/null
  
  echo "Cleaned $count old registry entries and old logs/results"
}

# ─── main ───

CMD="${1:-}"
shift || true

case "$CMD" in
  dispatch) cmd_dispatch "$@" ;;
  poll)     cmd_poll "$@" ;;
  result)   cmd_result "$@" ;;
  resume)   cmd_resume "$@" ;;
  list)     cmd_list "$@" ;;
  cancel)   cmd_cancel "$@" ;;
  costs)    cmd_costs "$@" ;;
  cleanup)  cmd_cleanup "$@" ;;
  *)
    echo "Claude Code Orchestrator"
    echo ""
    echo "Commands:"
    echo "  dispatch <workdir> <budget> <model> <label> \"<task>\"  — Submit task"
    echo "  poll <task-id>                                         — Check status"
    echo "  result <task-id>                                       — Get full output"
    echo "  resume <task-id> <budget> \"<follow-up>\"               — Continue/correct"
    echo "  list [--running|--done|--failed|--all]                 — List tasks"
    echo "  cancel <task-id>                                       — Kill running task"
    echo "  costs [--today|--all]                                  — Cost summary"
    echo "  cleanup                                                — Remove old data"
    ;;
esac
