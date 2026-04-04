#!/bin/bash
# Claude Code Orchestrator — Installer
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Claude Code Orchestrator — Installer${NC}"
echo "────────────────────────────────────────"

# Check dependencies
echo -n "Checking for claude binary... "
if ! command -v claude &>/dev/null; then
  echo -e "${RED}NOT FOUND${NC}"
  echo ""
  echo "  Claude Code CLI is required. Install it from:"
  echo "  https://docs.anthropic.com/en/docs/claude-code"
  echo ""
  echo "  Quick install:"
  echo "    npm install -g @anthropic-ai/claude-code"
  echo ""
  exit 1
else
  echo -e "${GREEN}OK${NC} ($(command -v claude))"
fi

echo -n "Checking for python3... "
if ! command -v python3 &>/dev/null; then
  echo -e "${RED}NOT FOUND${NC}"
  echo ""
  echo "  Python 3 is required. Install it with your package manager:"
  echo "    Ubuntu/Debian: apt install python3"
  echo "    macOS:         brew install python3"
  echo ""
  exit 1
else
  echo -e "${GREEN}OK${NC} ($(python3 --version))"
fi

# Create install directory if needed
mkdir -p "$INSTALL_DIR"

# Install scripts
echo ""
echo "Installing scripts to $INSTALL_DIR..."

cp "$SCRIPT_DIR/scripts/cc-orchestrator.sh" "$INSTALL_DIR/cc-orchestrator"
cp "$SCRIPT_DIR/scripts/run-task.sh" "$INSTALL_DIR/cc-run-task"

chmod +x "$INSTALL_DIR/cc-orchestrator"
chmod +x "$INSTALL_DIR/cc-run-task"

echo -e "  ${GREEN}✓${NC} cc-orchestrator → $INSTALL_DIR/cc-orchestrator"
echo -e "  ${GREEN}✓${NC} cc-run-task     → $INSTALL_DIR/cc-run-task"

# Check PATH
echo ""
if echo "$PATH" | grep -q "$INSTALL_DIR"; then
  echo -e "${GREEN}✓${NC} $INSTALL_DIR is in your PATH"
else
  echo -e "${YELLOW}⚠${NC}  $INSTALL_DIR is not in your PATH."
  echo "   Add this to your ~/.bashrc or ~/.zshrc:"
  echo ""
  echo '     export PATH="$HOME/.local/bin:$PATH"'
  echo ""
  echo "   Then run: source ~/.bashrc"
fi

echo ""
echo -e "${BOLD}Quick start:${NC}"
echo ""
echo "  # Dispatch a task (async — returns immediately)"
echo "  TASK=\$(cc-orchestrator dispatch /your/project 1.00 sonnet my-task \\"
echo "    \"Refactor the auth module to use JWT tokens\")"
echo "  TASK_ID=\$(echo \"\$TASK\" | python3 -c \"import json,sys; print(json.load(sys.stdin)['task_id'])\")"
echo ""
echo "  # Poll until done"
echo "  cc-orchestrator poll \"\$TASK_ID\""
echo ""
echo "  # Get the full result"
echo "  cc-orchestrator result \"\$TASK_ID\""
echo ""
echo "  # See all tasks"
echo "  cc-orchestrator list"
echo ""
echo "  # Today's cost summary"
echo "  cc-orchestrator costs"
echo ""
echo -e "${GREEN}Installation complete!${NC}"
