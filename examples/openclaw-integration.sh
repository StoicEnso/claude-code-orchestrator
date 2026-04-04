#!/bin/bash
# Example: OpenClaw Agent Integration
#
# This shows how an OpenClaw agent (or any AI agent system) would use
# cc-orchestrator to delegate complex coding tasks to Claude Code.
#
# The pattern is:
#   1. Agent receives a complex coding request
#   2. Agent dispatches it to Claude Code via cc-orchestrator
#   3. Agent does other work while Claude Code runs
#   4. Agent polls, retrieves result, and incorporates it
#   5. Agent optionally resumes if corrections are needed
#
# In OpenClaw, this is done from within a SKILL.md workflow using
# exec() to run these shell commands.

set -euo pipefail

CCO="${CC_ORCHESTRATOR_BIN:-cc-orchestrator}"

# ─── Configuration ────────────────────────────────────────────────────────────

PROJECT_DIR="${1:-/tmp/my-project}"
BUDGET="${2:-2.00}"
MODEL="${3:-sonnet}"

echo "=== OpenClaw Agent → Claude Code Integration ==="
echo "Project: $PROJECT_DIR"
echo "Budget:  \$$BUDGET"
echo "Model:   $MODEL"
echo ""

# ─── Helper: wait_for_task ────────────────────────────────────────────────────

wait_for_task() {
  local task_id="$1"
  local timeout="${2:-180}"
  local interval="${3:-10}"
  local elapsed=0
  
  while [ $elapsed -lt $timeout ]; do
    local status
    status=$($CCO poll "$task_id" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))")
    
    if [ "$status" = "done" ]; then
      echo "done"
      return 0
    elif [ "$status" = "failed" ]; then
      echo "failed"
      return 1
    fi
    
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  echo "timeout"
  return 1
}

# ─── Helper: get_result ───────────────────────────────────────────────────────

get_result() {
  local task_id="$1"
  $CCO result "$task_id" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('result', d.get('error', 'no result')))
"
}

# ─── Main Agent Workflow ──────────────────────────────────────────────────────

mkdir -p "$PROJECT_DIR"

# Step 1: Agent dispatches the primary coding task
echo "[Agent] Dispatching primary task to Claude Code..."
DISPATCH=$($CCO dispatch "$PROJECT_DIR" "$BUDGET" "$MODEL" "primary-coding-task" \
  "Implement a REST API endpoint handler in Python (using FastAPI) for user authentication. \
Include: POST /auth/login (returns JWT), POST /auth/logout, GET /auth/me (protected). \
Add proper error handling, input validation with Pydantic, and inline documentation.")

TASK_ID=$(echo "$DISPATCH" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")
echo "[Agent] Task dispatched: $TASK_ID"
echo "[Agent] Doing other work while Claude Code runs..."
echo ""

# Step 2: Agent does other work while Claude Code runs in background
# (In a real agent, this would be other processing, tool calls, etc.)
sleep 2
echo "[Agent] (Still working on other things...)"
sleep 2
echo ""

# Step 3: Poll and wait
echo "[Agent] Checking task status..."
FINAL_STATUS=$(wait_for_task "$TASK_ID" 300 10)
echo "[Agent] Task finished with status: $FINAL_STATUS"
echo ""

if [ "$FINAL_STATUS" = "done" ]; then
  # Step 4: Get and use the result
  echo "[Agent] Retrieving result..."
  RESULT=$(get_result "$TASK_ID")
  
  echo "[Agent] Claude Code produced:"
  echo "────────────────────────────────────────────────────────────"
  echo "$RESULT" | head -30
  echo "... (truncated for demo)"
  echo "────────────────────────────────────────────────────────────"
  echo ""
  
  # Step 5: Agent evaluates result and optionally resumes
  echo "[Agent] Evaluating result quality..."
  
  # In a real agent, you'd parse the result and decide whether to resume
  # Here we demonstrate a sample correction/follow-up
  NEEDS_FOLLOWUP=true
  
  if $NEEDS_FOLLOWUP; then
    echo "[Agent] Requesting follow-up: add rate limiting..."
    
    RESUME_DISPATCH=$($CCO resume "$TASK_ID" 0.50 \
      "Add rate limiting to the /auth/login endpoint: max 5 attempts per IP per minute. \
Use a simple in-memory store with TTL. Return 429 with Retry-After header when exceeded.")
    
    RESUME_ID=$(echo "$RESUME_DISPATCH" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")
    echo "[Agent] Resume task: $RESUME_ID"
    
    RESUME_STATUS=$(wait_for_task "$RESUME_ID" 180 10)
    echo "[Agent] Resume finished: $RESUME_STATUS"
    
    if [ "$RESUME_STATUS" = "done" ]; then
      echo ""
      echo "[Agent] Final implementation (with rate limiting):"
      echo "────────────────────────────────────────────────────────────"
      get_result "$RESUME_ID" | head -20
      echo "..."
      echo "────────────────────────────────────────────────────────────"
    fi
  fi
  
else
  echo "[Agent] Task did not complete successfully: $FINAL_STATUS"
  echo "[Agent] Raw output:"
  $CCO result "$TASK_ID"
fi

echo ""
echo "[Agent] Cost report:"
$CCO costs --today

echo ""
echo "[Agent] All tasks:"
$CCO list --all
