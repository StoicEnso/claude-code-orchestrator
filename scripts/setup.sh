#!/bin/bash
# Claude Code Orchestrator — One-time setup
# Run this after installing the skill to verify everything works.
#
# Usage: setup.sh [--check-only]
#
# What it does:
#   1. Verifies claude CLI is installed and authenticated
#   2. Verifies python3 is available
#   3. Creates required temp directories
#   4. Runs a smoke test (dispatches a tiny task, polls, verifies)
#   5. Reports status

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CHECK_ONLY="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ERRORS=0

ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; ERRORS=$((ERRORS + 1)); }

echo "Claude Code Orchestrator — Setup Check"
echo "========================================"
echo ""

# 1. Check claude CLI
echo "Dependencies:"
if command -v claude &>/dev/null; then
  VERSION=$(claude --version 2>&1 | head -1)
  ok "claude CLI found: $VERSION"
else
  fail "claude CLI not found. Install: npm install -g @anthropic-ai/claude-code"
fi

# 2. Check python3
if command -v python3 &>/dev/null; then
  PY_VERSION=$(python3 --version 2>&1)
  ok "python3 found: $PY_VERSION"
else
  fail "python3 not found. Install python3."
fi

# 3. Check scripts exist and are executable
echo ""
echo "Scripts:"
for script in run-task.sh cc-orchestrator.sh; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    if [ -x "$SCRIPT_DIR/$script" ]; then
      ok "$script — present and executable"
    else
      warn "$script — present but not executable, fixing..."
      chmod +x "$SCRIPT_DIR/$script"
      ok "$script — fixed"
    fi
  else
    fail "$script — missing!"
  fi
done

# 4. Create temp directories
echo ""
echo "Directories:"
for dir in /tmp/claude-subagent-results /tmp/claude-subagent-registry /tmp/claude-subagent-logs; do
  mkdir -p "$dir" 2>/dev/null
  ok "$dir"
done

# 5. Check claude auth (quick test)
echo ""
echo "Authentication:"
if command -v claude &>/dev/null; then
  AUTH_TEST=$(echo "respond with only the word 'authenticated'" | timeout 30 claude --print 2>&1 || true)
  if echo "$AUTH_TEST" | grep -qi "authenticated"; then
    ok "Claude Code authenticated and responding"
  elif echo "$AUTH_TEST" | grep -qi "error\|unauthorized\|login\|expired"; then
    fail "Claude Code auth issue. Run 'claude' interactively to re-authenticate."
  else
    warn "Could not confirm auth (response: ${AUTH_TEST:0:100})"
  fi
fi

# 6. Smoke test (skip if --check-only)
if [ "$CHECK_ONLY" != "--check-only" ] && [ $ERRORS -eq 0 ]; then
  echo ""
  echo "Smoke Test:"
  
  RESULT=$("$SCRIPT_DIR/run-task.sh" run /tmp 0.10 haiku "Respond with exactly: SMOKE_TEST_PASS" 2>&1)
  
  if echo "$RESULT" | grep -q "SMOKE_TEST_PASS"; then
    COST=$(echo "$RESULT" | python3 -c "import json,sys; print(f'\${json.load(sys.stdin).get(\"cost_usd\",0):.4f}')" 2>/dev/null || echo "unknown")
    SESSION=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id','')[:12])" 2>/dev/null || echo "unknown")
    ok "Smoke test passed (cost: $COST, session: $SESSION...)"
  else
    fail "Smoke test failed. Output: ${RESULT:0:200}"
  fi
elif [ "$CHECK_ONLY" = "--check-only" ]; then
  echo ""
  echo "(Smoke test skipped — --check-only mode)"
fi

# Summary
echo ""
echo "========================================"
if [ $ERRORS -eq 0 ]; then
  ok "Setup complete! All checks passed."
  echo ""
  echo "Quick start:"
  echo "  $SCRIPT_DIR/cc-orchestrator.sh dispatch /tmp 0.50 sonnet my-first-task \"List all files in the current directory\""
else
  fail "$ERRORS check(s) failed. Fix the issues above and re-run."
  exit 1
fi
