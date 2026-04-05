---
name: claude-code-orchestrator
description: "Delegate tasks to Claude Code as a subagent via shell scripts. Use when: need Claude/Anthropic model access for complex coding, multi-file refactoring, PR creation, or when OpenClaw's Anthropic provider is unavailable. Also use when: spawning background coding tasks, parallel task execution, or multi-turn coding sessions with corrections. Don't use when: task is a simple file edit (use edit tool), quick shell command (use exec), or when gpt-5.4/sonnet via OpenClaw can handle it directly."
metadata:
  openclaw:
    emoji: "🔧"
    requires:
      bins: ["claude", "python3"]
---

# Claude Code Orchestrator

Delegate tasks to Claude Code (installed locally) as a pseudo-subagent. Claude Code uses its own Anthropic API auth (Claude Code subscription), independent of OpenClaw's provider config.

## Setup (one-time)

If Claude Code is not installed:
```bash
# Install Claude Code
npm install -g @anthropic-ai/claude-code

# Verify
claude --version
claude --print -p "Say hello"
```

If Claude Code needs auth, run `claude` interactively once to complete the login flow.

## Orchestrator

**Path:** `{baseDir}/scripts/cc-orchestrator.sh`

### dispatch — Submit a task (returns immediately)

```bash
{baseDir}/scripts/cc-orchestrator.sh dispatch <workdir> <budget> <model> <label> "<task>"
```

- **workdir**: Directory Claude Code works in (scopes file access)
- **budget**: Max spend in USD (e.g. `1.00`)
- **model**: `sonnet` (default), `opus` (strongest), `haiku` (cheapest)
- **label**: Human-readable name for tracking
- **task**: The task description

Returns JSON with `task_id` and `pid`. Task runs in background.

### poll — Check task status

```bash
{baseDir}/scripts/cc-orchestrator.sh poll <task-id>
```

Returns JSON with `status` (running/done/failed), `cost_usd`, `session_id`, `result_preview`.

### result — Get full output

```bash
{baseDir}/scripts/cc-orchestrator.sh result <task-id>
```

Returns the complete structured JSON output from Claude Code.

### resume — Continue or correct a previous task

```bash
{baseDir}/scripts/cc-orchestrator.sh resume <task-id> <budget> "<follow-up>"
```

Claude Code reloads the **full conversation history** from the session and continues. Use for:
- Corrections: "actually, change X to Y"
- Multi-step work: "now implement step 2"
- Review: "explain what you changed and why"

### list — View all tasks

```bash
{baseDir}/scripts/cc-orchestrator.sh list [--running|--done|--failed|--all]
```

### cancel — Kill a running task

```bash
{baseDir}/scripts/cc-orchestrator.sh cancel <task-id>
```

### costs — Cost summary

```bash
{baseDir}/scripts/cc-orchestrator.sh costs [--today|--all]
```

### cleanup — Remove old data

```bash
{baseDir}/scripts/cc-orchestrator.sh cleanup
```

## Low-Level Script

For direct execution without the orchestrator layer:

```bash
{baseDir}/scripts/run-task.sh run <workdir> <budget> <model> "<task>"
{baseDir}/scripts/run-task.sh resume <session-id> <budget> "<follow-up>"
{baseDir}/scripts/run-task.sh status [<session-id>]
{baseDir}/scripts/run-task.sh clean
```

## Integration Patterns

### Pattern 1: Background dispatch from any agent

```bash
CC="{baseDir}/scripts/cc-orchestrator.sh"

# Dispatch (returns immediately)
HANDLE=$($CC dispatch /path/to/project 1.00 sonnet "my-task" "Refactor the auth module")
TASK_ID=$(echo "$HANDLE" | python3 -c "import json,sys; print(json.load(sys.stdin)['task_id'])")

# Later: check status
$CC poll "$TASK_ID"

# If corrections needed:
$CC resume "$TASK_ID" 0.50 "Also add unit tests for the new code"
```

### Pattern 2: Inline with exec (OpenClaw agents)

```bash
# Run in background via exec
exec background:true command:"bash {baseDir}/scripts/cc-orchestrator.sh dispatch /root/project 1.00 sonnet label 'task' > /tmp/handle.json 2>&1"

# Poll for completion
exec command:"bash {baseDir}/scripts/cc-orchestrator.sh poll <task-id>"
```

### Pattern 3: Parallel tasks

```bash
CC="{baseDir}/scripts/cc-orchestrator.sh"
$CC dispatch ./src 0.50 sonnet "lint" "Fix all ESLint errors"
$CC dispatch ./src 0.50 sonnet "types" "Add TypeScript types to utils/"
$CC dispatch ./docs 0.50 haiku "docs" "Update the API docs"

# Monitor all
$CC list --running
```

## Cost Guide

| Model | Typical cost per task | Best for |
|-------|----------------------|----------|
| `haiku` | $0.01-0.05 | Simple file reads, quick checks |
| `sonnet` | $0.05-0.20 | Most subagent work, coding, analysis |
| `opus` | $0.15-0.50 | Complex reasoning, multi-file refactors |

## Key Differences from OpenClaw Subagents

| | OpenClaw subagent | Claude Code subagent |
|---|---|---|
| Auth | OpenClaw API keys | Claude Code subscription |
| Tools | sessions_send, cron, memory_search | Read, Write, Edit, Bash, WebFetch |
| Context | Inherits AGENTS.md, SOUL.md | Only sees files in workdir |
| Steering | `subagents steer` | `resume` with follow-up prompt |
| Session resume | Not supported | Full resume via `--resume` |
| Cost tracking | Gateway usage logs | JSON output `cost_usd` field |

## Default Operating Mode (recommended)

**Do not treat Claude Code as a one-shot "research + write + finalize everything" agent by default.**

Use this pattern unless the task is trivially small:

### Phase A — Scout / Recon
Create exactly one bounded reconnaissance artifact.

Artifact should contain only:
- key signals
- constraints
- ranked next step
- exact downstream write target
- minimum files Phase B should use

### Phase B — Bounded Write
Run a second Claude Code task that uses only:
- the Phase A artifact
- the minimum local truth files
- one explicit output target

### Phase C — Verify
Before calling the task done:
- confirm the target file exists on disk
- confirm it is non-trivial (not tiny / empty)
- skim the artifact directly instead of trusting status output alone

## When to use this default pattern

Use **Scout -> Bound -> Write -> Verify** for:
- research briefs
- triage reports
- prompt packs
- implementation scripts
- cover/composition briefs
- content-ops planning artifacts

Avoid one-shot end-to-end runs for:
- large ambiguous content tasks
- tasks that require both broad exploration and exact final output
- unattended shipping without file verification

## Resume guidance

`resume` is useful, but it is a **fallback**, not the default operating mode.

Prefer:
- a fresh bounded write step after reconnaissance
- `resume` only when the original session clearly has useful context worth preserving
- checking that `session_id` is present before depending on a resume-heavy workflow

## Verification rule

For this tool, **done means verified**, not just "Claude said it's done."

Treat a task as successful only when:
- the expected file exists
- the file content is materially useful
- the artifact matches the requested output target

## Security Notes

- Claude Code has full filesystem access within its working directory
- Always set an appropriate **workdir** to scope what Claude Code can see
- Use budget caps to prevent runaway costs
- Avoid pointing it at sensitive directories (credentials, configs)
- Results stored in `/tmp/claude-subagent-results/` (auto-cleaned by `cleanup`)
