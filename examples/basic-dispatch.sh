#!/bin/bash
# Example: Basic dispatch → poll → result flow
#
# This is the simplest usage pattern: submit a task, wait for it,
# then read the result. Good for understanding the core workflow.

set -euo pipefail

# Path to orchestrator (adjust if not in PATH)
CCO="cc-orchestrator"

echo "=== Basic Dispatch Example ==="
echo ""

# 1. Dispatch a task
echo "Step 1: Dispatching task..."
RESPONSE=$($CCO dispatch /tmp sonnet 1.00 my-first-task \
  "Create a Python function that validates an email address using a regex. Include docstring and unit tests.")

echo "Response: $RESPONSE"
echo ""

# Extract task ID from JSON response
TASK_ID=$(echo "$RESPONSE" | python3 -c "import json, sys; print(json.load(sys.stdin)['task_id'])")
echo "Task ID: $TASK_ID"
echo ""

# 2. Poll until done
echo "Step 2: Polling for completion..."
MAX_WAIT=120
ELAPSED=0
POLL_INTERVAL=5

while [ $ELAPSED -lt $MAX_WAIT ]; do
  STATUS_JSON=$($CCO poll "$TASK_ID")
  STATUS=$(echo "$STATUS_JSON" | python3 -c "import json, sys; print(json.load(sys.stdin).get('status', 'unknown'))")
  
  echo "  [$ELAPSED s] Status: $STATUS"
  
  if [ "$STATUS" = "done" ] || [ "$STATUS" = "failed" ]; then
    break
  fi
  
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""

# 3. Get the full result
echo "Step 3: Fetching result..."
RESULT=$($CCO result "$TASK_ID")
echo "$RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('Status:  ', d.get('status'))
print('Cost:    \$', d.get('cost_usd', 0))
print('Turns:   ', d.get('turns', 0))
print('Session: ', d.get('session_id', '')[:20], '...')
print()
print('Result:')
print('-' * 60)
print(d.get('result', 'No result'))
"
