#!/bin/bash
# Example: Dispatch 3 tasks in parallel
#
# Dispatch multiple independent tasks at once, then collect results
# when they're all done. Each runs as a separate background process
# against its own Claude Code session.
#
# Great for: parallelising code generation, running multiple analyses
# simultaneously, or splitting a large task into independent subtasks.

set -euo pipefail

CCO="cc-orchestrator"

echo "=== Parallel Task Dispatch Example ==="
echo ""

PROJECT_DIR="/tmp/parallel-demo"
mkdir -p "$PROJECT_DIR"

# 1. Dispatch all three tasks simultaneously
echo "Step 1: Dispatching 3 tasks in parallel..."

T1=$($CCO dispatch "$PROJECT_DIR" sonnet 1.00 task-auth \
  "Write a Python module for JWT authentication. Include encode, decode, and verify functions with proper error handling.")
T1_ID=$(echo "$T1" | python3 -c "import json, sys; print(json.load(sys.stdin)['task_id'])")
echo "  Task 1 (auth):    $T1_ID"

T2=$($CCO dispatch "$PROJECT_DIR" sonnet 1.00 task-db \
  "Write a Python module for SQLite database operations. Include connect, insert, query, and close functions with context manager support.")
T2_ID=$(echo "$T2" | python3 -c "import json, sys; print(json.load(sys.stdin)['task_id'])")
echo "  Task 2 (database): $T2_ID"

T3=$($CCO dispatch "$PROJECT_DIR" sonnet 1.00 task-api \
  "Write a Python module for making HTTP API requests. Include get, post, put, delete with retry logic and timeout handling.")
T3_ID=$(echo "$T3" | python3 -c "import json, sys; print(json.load(sys.stdin)['task_id'])")
echo "  Task 3 (api):      $T3_ID"

echo ""
echo "All 3 tasks dispatched. Now polling until all complete..."
echo ""

# 2. Poll all three until done
declare -A DONE
DONE[$T1_ID]=0
DONE[$T2_ID]=0
DONE[$T3_ID]=0
LABELS=( ["$T1_ID"]="auth" ["$T2_ID"]="database" ["$T3_ID"]="api" )

MAX_WAIT=300
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
  ALL_DONE=true
  
  for TASK_ID in "$T1_ID" "$T2_ID" "$T3_ID"; do
    if [ "${DONE[$TASK_ID]}" = "0" ]; then
      STATUS=$($CCO poll "$TASK_ID" | python3 -c "import json, sys; print(json.load(sys.stdin).get('status'))")
      if [ "$STATUS" = "done" ] || [ "$STATUS" = "failed" ]; then
        DONE[$TASK_ID]=1
        echo "  ✓ ${LABELS[$TASK_ID]} ($TASK_ID): $STATUS"
      else
        ALL_DONE=false
      fi
    fi
  done
  
  $ALL_DONE && break
  
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  echo "  [${ELAPSED}s] Still waiting..."
done

echo ""
echo "=== All tasks complete! ==="
echo ""

# 3. Collect results
echo "Step 3: Results:"
echo ""

for TASK_ID in "$T1_ID" "$T2_ID" "$T3_ID"; do
  LABEL="${LABELS[$TASK_ID]}"
  echo "--- $LABEL ---"
  $CCO result "$TASK_ID" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('Status: ', d.get('status'))
print('Cost:   \$', d.get('cost_usd', 0))
print('Preview:', str(d.get('result', ''))[:200], '...')
"
  echo ""
done

# 4. Total cost
echo "=== Cost Summary ==="
$CCO costs --today
