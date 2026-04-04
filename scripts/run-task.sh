#!/bin/bash
# Claude Code Subagent Runner
# 
# Modes:
#   run     — one-shot task (default)
#   resume  — continue a previous session
#   status  — check if a session exists and show its last result
#
# Usage:
#   run-task.sh run    <workdir> <budget> <model> <task-description>
#   run-task.sh resume <session-id> <budget> <task-description>
#   run-task.sh status <session-id>
#
# Models: opus (default), sonnet, haiku
# Output: JSON to stdout with structured result
#
# Environment:
#   CC_TASK_ID  — optional task ID for tracking (used in output filenames)

set -euo pipefail

RESULTS_DIR="/tmp/claude-subagent-results"
mkdir -p "$RESULTS_DIR"

MODE="${1:-run}"

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
    
    cd "$WORKDIR"
    
    # Run Claude Code
    if claude --print \
      --output-format json \
      --max-budget-usd "$BUDGET" \
      --model "$MODEL" \
      -p "$TASK" > "$OUTPUT_FILE" 2>/dev/null; then
      STATUS="ok"
    else
      EXIT_CODE=$?
      STATUS="error"
      # If output file is empty or doesn't exist, create error JSON
      if [ ! -s "$OUTPUT_FILE" ]; then
        echo "{\"error\": \"claude exited with code $EXIT_CODE\", \"task_id\": \"$TASK_ID\"}" > "$OUTPUT_FILE"
      fi
    fi
    
    # Parse and output structured result
    python3 -c "
import json, sys
try:
    with open('$OUTPUT_FILE') as f:
        d = json.load(f)
    out = {
        'status': '$STATUS',
        'task_id': '$TASK_ID',
        'session_id': d.get('session_id', ''),
        'result': d.get('result', d.get('error', 'no result')),
        'cost_usd': d.get('total_cost_usd', 0),
        'turns': d.get('num_turns', 0),
        'duration_ms': d.get('duration_ms', 0),
        'model': list(d.get('modelUsage', {}).keys()),
        'stop_reason': d.get('stop_reason', ''),
        'output_file': '$OUTPUT_FILE'
    }
    print(json.dumps(out, indent=2))
except Exception as e:
    print(json.dumps({'status': 'parse_error', 'error': str(e), 'task_id': '$TASK_ID', 'output_file': '$OUTPUT_FILE'}))
"
    ;;
    
  resume)
    SESSION_ID="${2:-}"
    BUDGET="${3:-1.00}"
    TASK="${4:-}"
    
    if [ -z "$SESSION_ID" ] || [ -z "$TASK" ]; then
      echo '{"error": "Need session_id and task", "usage": "run-task.sh resume <session-id> <budget> <task>"}' >&2
      exit 1
    fi
    
    TASK_ID="${CC_TASK_ID:-resume-$(date +%s)-$$}"
    OUTPUT_FILE="$RESULTS_DIR/${TASK_ID}.json"
    
    # Resume the session
    if claude --print \
      --output-format json \
      --max-budget-usd "$BUDGET" \
      --resume "$SESSION_ID" \
      -p "$TASK" > "$OUTPUT_FILE" 2>/dev/null; then
      STATUS="ok"
    else
      EXIT_CODE=$?
      STATUS="error"
      if [ ! -s "$OUTPUT_FILE" ]; then
        echo "{\"error\": \"claude resume exited with code $EXIT_CODE\", \"session_id\": \"$SESSION_ID\", \"task_id\": \"$TASK_ID\"}" > "$OUTPUT_FILE"
      fi
    fi
    
    # Parse result
    python3 -c "
import json, sys
try:
    with open('$OUTPUT_FILE') as f:
        d = json.load(f)
    out = {
        'status': '$STATUS',
        'task_id': '$TASK_ID',
        'session_id': d.get('session_id', '$SESSION_ID'),
        'resumed_from': '$SESSION_ID',
        'result': d.get('result', d.get('error', 'no result')),
        'cost_usd': d.get('total_cost_usd', 0),
        'turns': d.get('num_turns', 0),
        'duration_ms': d.get('duration_ms', 0),
        'model': list(d.get('modelUsage', {}).keys()),
        'output_file': '$OUTPUT_FILE'
    }
    print(json.dumps(out, indent=2))
except Exception as e:
    print(json.dumps({'status': 'parse_error', 'error': str(e), 'task_id': '$TASK_ID', 'output_file': '$OUTPUT_FILE'}))
"
    ;;
    
  status)
    SESSION_ID="${2:-}"
    
    if [ -z "$SESSION_ID" ]; then
      # List recent results
      echo "Recent Claude Code results:"
      ls -lt "$RESULTS_DIR"/*.json 2>/dev/null | head -10
      exit 0
    fi
    
    # Find results for this session
    python3 -c "
import json, glob, os
results = []
for f in glob.glob('$RESULTS_DIR/*.json'):
    try:
        with open(f) as fh:
            d = json.load(fh)
        sid = d.get('session_id', '')
        if sid == '$SESSION_ID' or d.get('resumed_from', '') == '$SESSION_ID':
            results.append({
                'file': f,
                'task_id': d.get('task_id', ''),
                'session_id': sid,
                'status': d.get('status', '?'),
                'cost_usd': d.get('cost_usd', 0),
                'result_preview': str(d.get('result', ''))[:200],
                'mtime': os.path.getmtime(f)
            })
    except: pass
results.sort(key=lambda x: x.get('mtime', 0))
if results:
    print(json.dumps(results, indent=2))
else:
    print(json.dumps({'error': 'No results found for session $SESSION_ID'}))
"
    ;;
    
  clean)
    # Clean results older than 24h
    find "$RESULTS_DIR" -name "*.json" -mmin +1440 -delete 2>/dev/null
    echo "Cleaned old results"
    ;;
    
  *)
    echo "Usage: $0 {run|resume|status|clean} [args...]" >&2
    exit 1
    ;;
esac
