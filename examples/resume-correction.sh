#!/bin/bash
# Example: Dispatch → Resume (correction/continuation) flow
#
# The resume command lets you continue a Claude Code session with full
# conversation context. Useful for:
#   - Correcting a result ("use TypeScript instead of Python")
#   - Adding a follow-up step ("now write tests for that")
#   - Iterating on output ("make it more concise")

set -euo pipefail

CCO="cc-orchestrator"

echo "=== Resume / Correction Example ==="
echo ""

# 1. Initial task
echo "Step 1: Dispatching initial task..."
RESPONSE=$($CCO dispatch /tmp sonnet 1.00 draft-task \
  "Write a simple HTTP server in Python that responds with 'Hello World' on port 8080.")

TASK_ID=$(echo "$RESPONSE" | python3 -c "import json, sys; print(json.load(sys.stdin)['task_id'])")
echo "Task ID: $TASK_ID"
echo ""

# 2. Wait for it
echo "Step 2: Waiting for completion..."
while true; do
  STATUS=$($CCO poll "$TASK_ID" | python3 -c "import json, sys; print(json.load(sys.stdin).get('status'))")
  echo "  Status: $STATUS"
  [ "$STATUS" = "done" ] || [ "$STATUS" = "failed" ] && break
  sleep 5
done
echo ""

# 3. Show the initial result
echo "Step 3: Initial result:"
$CCO result "$TASK_ID" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('result', '')[:500])
print('...')
print('(session_id:', d.get('session_id', '')[:20], '...)')
"
echo ""

# 4. Resume with a correction — full conversation history is preserved
echo "Step 4: Resuming with correction..."
RESUME_RESPONSE=$($CCO resume "$TASK_ID" 0.50 \
  "Great. Now modify it to also serve static files from a /public directory, and add proper logging with timestamps.")

RESUME_ID=$(echo "$RESUME_RESPONSE" | python3 -c "import json, sys; print(json.load(sys.stdin)['task_id'])")
echo "Resume Task ID: $RESUME_ID"
echo ""

# 5. Wait for the resume
echo "Step 5: Waiting for resume to complete..."
while true; do
  STATUS=$($CCO poll "$RESUME_ID" | python3 -c "import json, sys; print(json.load(sys.stdin).get('status'))")
  echo "  Status: $STATUS"
  [ "$STATUS" = "done" ] || [ "$STATUS" = "failed" ] && break
  sleep 5
done
echo ""

# 6. Final result
echo "Step 6: Final result (with full context from both turns):"
$CCO result "$RESUME_ID" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('Cost this turn: \$', d.get('cost_usd', 0))
print()
print(d.get('result', 'No result'))
"
echo ""

# 7. Show total costs
echo "Step 7: Cost summary:"
$CCO costs --today
