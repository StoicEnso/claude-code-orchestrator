# Claude Code Orchestrator

**Delegate tasks to Claude Code from any AI agent, automation pipeline, or CLI**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-blue.svg)](scripts/)
[![Requires](https://img.shields.io/badge/requires-claude%20CLI-purple.svg)](https://docs.anthropic.com/en/docs/claude-code)

---

## The Problem

AI agent systems often need to delegate complex coding tasks — multi-file refactors, test generation, architecture design — to a capable model with full execution context. Claude Code is excellent at this, but it runs as its own CLI with its own Anthropic API authentication. There's no built-in bridge between "my agent received a task" and "Claude Code is running it."

**Claude Code Orchestrator** is that bridge: a pair of Bash scripts that let any system that can run shell commands dispatch tasks to Claude Code asynchronously, poll for completion, retrieve structured results, resume sessions with full conversation history, track costs, and manage task lifecycle.

It works with OpenClaw, custom agents, CI/CD pipelines, cron jobs, or just your terminal.

---

## Features

| Feature | Description |
|---|---|
| **dispatch** | Submit a task and get a handle back immediately (async, non-blocking) |
| **poll** | Check task status: `running` → `done` / `failed` |
| **result** | Retrieve the full structured JSON output |
| **resume** | Continue a session with full conversation context (corrections, follow-ups) |
| **list** | View all tracked tasks with status and cost |
| **cancel** | Kill a running task by PID |
| **costs** | Cost summary by model and task, today or all-time |
| **cleanup** | Remove old task data after 48h |

---

## Quick Start

### 1. Install

```bash
git clone https://github.com/yourusername/claude-code-orchestrator
cd claude-code-orchestrator
bash install.sh
```

The installer checks for `claude` and `python3`, then copies the scripts to `~/.local/bin`.

**Prerequisites:**
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- Python 3 (standard library only — no pip packages needed)
- Bash 4+

### 2. Your first task

```bash
# Dispatch a coding task (returns immediately)
RESPONSE=$(cc-orchestrator dispatch /my/project 1.00 sonnet my-task \
  "Refactor the auth module to use JWT tokens instead of sessions")

# Extract the task ID
TASK_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")

# Poll until done
cc-orchestrator poll "$TASK_ID"

# Get the result
cc-orchestrator result "$TASK_ID"
```

---

## Architecture

```
Your Agent / Script / CI
        │
        │  cc-orchestrator dispatch ...
        ▼
┌─────────────────────────────────────┐
│         cc-orchestrator.sh          │
│                                     │
│  • Generates task ID                │
│  • Writes to /tmp registry          │
│  • Launches run-task.sh in BG ──────┼──► Background process
│  • Returns JSON handle immediately  │         │
└─────────────────────────────────────┘         │
        │                                       │  run-task.sh
        │  cc-orchestrator poll ...             │
        ▼                                       ▼
┌─────────────────────────────────────┐  ┌─────────────────────┐
│         Registry (/tmp)             │  │   claude --print    │
│                                     │  │   --output-format   │
│  task_id.json:                      │  │   json              │
│    status: running → done           │◄─┤   --max-budget-usd  │
│    session_id: abc123               │  │   --model sonnet    │
│    cost_usd: 0.042                  │  │   -p "your task"    │
│    result_preview: ...              │  └─────────────────────┘
└─────────────────────────────────────┘

  Resume flow:
  cc-orchestrator resume <task-id> ...
        │
        └──► run-task.sh resume <session-id> ...
                  │
                  └──► claude --resume <session-id> -p "follow-up"
                            (full conversation history preserved)
```

**Data locations** (all in `/tmp`, ephemeral by design):
- `/tmp/claude-subagent-registry/` — task metadata JSON files
- `/tmp/claude-subagent-logs/` — raw Claude Code output
- `/tmp/claude-subagent-results/` — structured result JSON
- `/tmp/claude-subagent-costs.jsonl` — append-only cost ledger

---

## Command Reference

### `dispatch` — Submit a task

```bash
cc-orchestrator dispatch <workdir> <budget> <model> <label> "<task>"
```

| Argument | Description | Example |
|---|---|---|
| `workdir` | Directory Claude Code will work in | `/my/project` |
| `budget` | Max spend in USD | `1.00` |
| `model` | Claude model | `haiku`, `sonnet`, `opus` |
| `label` | Human-readable name for the task | `refactor-auth` |
| `task` | The instruction for Claude Code | `"Refactor..."` |

**Returns JSON:**
```json
{
  "task_id": "refactor-auth-1712345678-1234",
  "pid": 98765,
  "status": "dispatched",
  "label": "refactor-auth",
  "model": "sonnet",
  "budget": "1.00"
}
```

Returns immediately. Claude Code runs in background.

---

### `poll` — Check task status and refresh from output/stream

```bash
cc-orchestrator poll <task-id>
```

Returns task metadata including `status`:
- `running` — still executing
- `done` — completed successfully
- `failed` — Claude Code errored or budget exceeded
- `cancelled` — manually cancelled
- `unknown-check-result` — process ended but registry not updated yet

---

### `result` — Get full output / text

```bash
cc-orchestrator result <task-id>
```

Returns the full structured JSON from Claude Code:

```json
{
  "status": "ok",
  "task_id": "refactor-auth-1712345678-1234",
  "session_id": "abc123def456...",
  "result": "I've refactored the auth module...\n\n```python\n...",
  "cost_usd": 0.042,
  "turns": 8,
  "duration_ms": 45000,
  "model": ["claude-sonnet-4-5"],
  "stop_reason": "end_turn"
}
```

---

### `resume` — Continue with full context

```bash
cc-orchestrator resume <task-id> <budget> "<follow-up>"
```

Resumes the Claude Code session from the original task, preserving the full conversation. Claude Code remembers everything it did — files it read, code it wrote, decisions it made.

```bash
# Original task
TASK=$(cc-orchestrator dispatch /project 2.00 sonnet impl \
  "Implement the user settings page")
TASK_ID=$(echo "$TASK" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")

# ... wait for completion ...

# Correction in context
cc-orchestrator resume "$TASK_ID" 0.50 \
  "Add form validation — email must be valid, username min 3 chars"
```

Returns a new task ID for the resume session.

---

### `list` — View all tasks

```bash
cc-orchestrator list                # All tasks (default)
cc-orchestrator list --running      # Only in-progress
cc-orchestrator list --done         # Only completed
cc-orchestrator list --failed       # Only failed
cc-orchestrator list --all          # All (explicit)
```

Output:
```
done     | my-task-1712345678-1234              | $0.042 | refactor-auth | sid:abc123def456
running  | new-task-1712349999-5678             | $0.000 | write-tests   | sid:
failed   | bad-task-1712340000-9999             | $0.001 | bad-prompt    | sid:xyz
```

---

### `cancel` — Kill a running task

```bash
cc-orchestrator cancel <task-id>
```

Sends SIGTERM to the background process and any child Claude Code processes.

---

### `costs` — Cost summary

```bash
cc-orchestrator costs              # Today (default)
cc-orchestrator costs --today      # Today
cc-orchestrator costs --all        # All time
```

Output:
```
Tasks: 5
Total cost: $0.2341
By model:
  sonnet: $0.1820
  haiku: $0.0521
By task:
  refactor-auth-1712345678-1234    | $0.0420 | done
  write-tests-1712346000-2345      | $0.0180 | done
```

---


### `watch` — Tail live progress
```bash
{baseDir}/scripts/cc-orchestrator.sh watch <task-id>
```

### `batch` — Dispatch multiple tasks from a manifest
```bash
{baseDir}/scripts/cc-orchestrator.sh batch <manifest.jsonl> [--max-parallel N]
```

### Notifications
`dispatch` and `resume` accept `--notify-cmd "shell command"` and export:
- `CC_NOTIFY_TASK_ID`
- `CC_NOTIFY_STATUS`
- `CC_NOTIFY_COST_USD`
- `CC_NOTIFY_RESULT_PREVIEW`

Use this for shell/webhook/email hooks.

### `cleanup` — Remove old data

```bash
cc-orchestrator cleanup
```

Removes registry entries and log files for tasks older than 48h with status `done`, `failed`, or `cancelled`.

---

## Integration Examples

### Generic Agent (shell)

```bash
#!/bin/bash
# Any agent that can run shell commands can use this pattern

dispatch_coding_task() {
  local task="$1"
  local workdir="${2:-.}"
  local budget="${3:-1.00}"
  
  local response
  response=$(cc-orchestrator dispatch "$workdir" "$budget" sonnet "agent-task" "$task")
  echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])"
}

wait_for_task() {
  local task_id="$1"
  local timeout="${2:-300}"
  local elapsed=0
  
  while [ $elapsed -lt $timeout ]; do
    local status
    status=$(cc-orchestrator poll "$task_id" | \
      python3 -c "import json,sys; print(json.load(sys.stdin).get('status'))")
    
    [ "$status" = "done" ] && return 0
    [ "$status" = "failed" ] && return 1
    
    sleep 10
    elapsed=$((elapsed + 10))
  done
  return 1
}

# Usage
TASK_ID=$(dispatch_coding_task "Write unit tests for src/auth.py")
wait_for_task "$TASK_ID"
cc-orchestrator result "$TASK_ID"
```

---

### OpenClaw Agent

In an OpenClaw SKILL.md, use `exec()` to call the orchestrator from within agent workflows:

```bash
# Dispatch from within a skill
TASK=$(exec cc-orchestrator dispatch /project 2.00 sonnet "implement-feature" \
  "Implement the payment webhook handler. Parse Stripe events, update order status in DB, \
   send confirmation emails. Use existing DB and email utilities in src/utils/.")

TASK_ID=$(echo "$TASK" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")

# Poll with timeout (agent continues other work between polls)
for i in $(seq 1 30); do
  STATUS=$(cc-orchestrator poll "$TASK_ID" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('status'))")
  [ "$STATUS" = "done" ] && break
  sleep 10
done

# Retrieve and use result
RESULT=$(cc-orchestrator result "$TASK_ID" | \
  python3 -c "import json,sys; print(json.load(sys.stdin).get('result'))")

# Resume if corrections needed
cc-orchestrator resume "$TASK_ID" 0.50 "Also add idempotency key checks"
```

---

### CI/CD Pipeline (GitHub Actions)

```yaml
- name: Generate boilerplate
  run: |
    TASK=$(cc-orchestrator dispatch ${{ github.workspace }} 2.00 sonnet "ci-codegen" \
      "Generate TypeScript API client from openapi.yaml. Output to src/api/client.ts")
    TASK_ID=$(echo "$TASK" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")
    
    # Wait up to 5 minutes
    for i in $(seq 1 30); do
      STATUS=$(cc-orchestrator poll "$TASK_ID" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('status'))")
      [ "$STATUS" = "done" ] && break
      [ "$STATUS" = "failed" ] && exit 1
      sleep 10
    done
    
    cc-orchestrator result "$TASK_ID"
```

---

### Parallel Tasks

```bash
# Dispatch multiple tasks simultaneously
T1=$(cc-orchestrator dispatch /project 1.00 sonnet "write-auth" "Write auth module")
T2=$(cc-orchestrator dispatch /project 1.00 sonnet "write-db" "Write database module")
T3=$(cc-orchestrator dispatch /project 1.00 sonnet "write-api" "Write API handlers")

ID1=$(echo "$T1" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")
ID2=$(echo "$T2" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")
ID3=$(echo "$T3" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")

# Poll all three, collect when done
for ID in "$ID1" "$ID2" "$ID3"; do
  while true; do
    S=$(cc-orchestrator poll "$ID" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status'))")
    [ "$S" = "done" ] || [ "$S" = "failed" ] && break
    sleep 10
  done
  echo "$ID done — $(cc-orchestrator result "$ID" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cost_usd', 0))")"
done
```

---

## Configuration

The scripts use `/tmp` for all runtime data by default. You can override the paths by editing the variables at the top of each script:

```bash
# In cc-orchestrator.sh
REGISTRY_DIR="/tmp/claude-subagent-registry"   # Task metadata
RESULTS_DIR="/tmp/claude-subagent-results"     # Structured results
LOGS_DIR="/tmp/claude-subagent-logs"           # Raw Claude output
COST_LOG="/tmp/claude-subagent-costs.jsonl"    # Cost ledger
```

Change these to a persistent path (e.g., `~/.local/share/cc-orchestrator/`) if you want data to survive reboots.

**Environment variables:**

| Variable | Description |
|---|---|
| `CC_TASK_ID` | Override the auto-generated task ID (useful for external tracking) |

---


## Workspace Profiles

The repo now includes `scripts/cc-profile.sh` plus `profiles.json` so agents can summon Claude Code with the right workspace roots and shared directories already allowed via `--add-dir`.

Examples:
```bash
bash scripts/cc-profile.sh karim env
bash scripts/cc-profile.sh karim dispatch 0.75 sonnet foster-recon "Create a bounded recon artifact"   --expect-file /root/clawd/kdp-books/foster-carer-record-book/research/cc-recon-brief.md   --expect-min-bytes 300   --next-action "run bounded Phase B write"   --continuation-mode continue
```

Default bundled profiles:
- `main`
- `karim`
- `zara`

This lets each agent keep its own working directory while still giving Claude Code access to shared skills/process roots where appropriate.

## Cost Guide

Approximate costs per task based on Claude API pricing (subject to change):

| Model | Use case | Typical task cost |
|---|---|---|
| `haiku` | Simple tasks, boilerplate, small edits | $0.001 – $0.01 |
| `sonnet` | Most coding tasks — recommended default | $0.01 – $0.10 |
| `opus` | Complex architecture, difficult debugging | $0.05 – $0.50 |

**Tips:**
- Use `haiku` for high-volume, simple tasks (formatting, renaming, boilerplate)
- Use `sonnet` for typical feature implementation and refactoring
- Use `opus` only when `sonnet` is struggling — it's 5–10x more expensive
- Set conservative budgets and resume with more budget if needed rather than over-budgeting upfront
- Run `cc-orchestrator costs --all` regularly to track spend

---

## Limitations & Caveats

- **Claude Code must be authenticated.** Run `claude auth login` before using this tool. The scripts do not manage API keys.
- **Data is ephemeral.** All state lives in `/tmp`. A reboot clears everything. Change the paths if you need persistence.
- **No queue.** Tasks are just background processes. There's no job queue, retry logic, or concurrency limit. Don't dispatch hundreds simultaneously.
- **No streaming.** Results are only available after Claude Code finishes. You can poll but not stream intermediate output.
- **Session IDs are model-local.** A session started with `sonnet` can only be resumed with `sonnet` (or the same model family). Don't mix models in a resume chain.
- **Cost tracking is best-effort.** If a process is killed unexpectedly, the cost may not be logged. The Claude API dashboard is authoritative.
- **No Windows support.** These are Bash scripts. WSL2 works fine.

---

## Project Structure

```
claude-code-orchestrator/
├── scripts/
│   ├── cc-orchestrator.sh    # High-level task management (dispatch, poll, resume, costs...)
│   └── run-task.sh           # Low-level Claude Code runner (run, resume, status, clean)
├── examples/
│   ├── basic-dispatch.sh     # Simple dispatch → poll → result
│   ├── resume-correction.sh  # Dispatch → resume flow
│   ├── parallel-tasks.sh     # 3 tasks in parallel
│   └── openclaw-integration.sh  # Full agent integration example
├── install.sh                # Installer
├── LICENSE                   # MIT
└── README.md
```

---

## Contributing

Contributions welcome. Some areas that would improve this:

- **Persistent storage** — SQLite backend instead of `/tmp` JSON files
- **Retry logic** — auto-retry failed tasks with exponential backoff
- **Webhook support** — HTTP callback when task completes
- **Token usage** — expose token counts alongside cost
- **macOS `stat` compatibility** — current `stat -c` is Linux-only
- **Test suite** — mock Claude CLI for unit tests

To contribute:

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/my-improvement`
3. Make your changes
4. Test manually (see `examples/`)
5. Open a pull request

Please keep the scripts dependency-free (no npm, pip, or external tools beyond `claude` and `python3`).

---

## License

MIT © 2026 Ihusan Henry

See [LICENSE](LICENSE) for full text.
