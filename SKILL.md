---
name: claude-delegate
description: "Give Claude back to OpenClaw through a local Claude Code delegation lane with dispatch, poll, result, resume, and an optional non-root bypassPermissions runner. Use when: you want Claude subscription access available to OpenClaw agents through a stable local worker lane, need resume/monitoring in a bounded workspace, or need Claude auth separate from OpenClaw providers. Don't use when: the user explicitly wants an ACP chat harness or thread, use acp-router plus sessions_spawn(runtime: \"acp\"); the task is a simple edit or shell command, use edit/exec directly; or the local Claude runner is not set up yet, read references/setup.md first."
---

# Claude Delegate

Give Claude back to OpenClaw.

Use this skill when Claude Code should run as a **local delegated worker**, not as an ACP chat harness.

The whole point is simple: third-party harnesses do not reliably get Claude subscription access, but OpenClaw operators still want Claude-quality work inside their agent system.

## Stable entrypoints

- Wrapper: `scripts/claude-delegate.sh`
- Profile wrapper: `scripts/cc-profile.sh`
- Orchestrator: `scripts/cc-orchestrator.sh`
- Low-level runner: `scripts/run-task.sh`

## Default flow

1. Read `references/setup.md` the first time you install or port this skill.
2. Configure `profiles.json`, or point `CLAUDE_DELEGATE_PROFILES` at a host-local profiles file.
3. Keep local delegate instructions in the nearest `CLAUDE.delegate.md` files. The wrapper now tells Claude to discover/read those plus nearby `AGENTS.md`, `TOOLS.md`, and `README.md` docs before substantive work.
4. Dispatch work through `scripts/claude-delegate.sh dispatch <profile> <budget|none> <model> <label> "<task>"`. Use `none` for the normal no-hard-dollar-cap path; numeric budgets are only for deliberately bounded probes.
5. Monitor with `poll`, `result`, `list`, or `doctor`.
6. Use `resume` to continue the same Claude session instead of starting over.

### Dispatch detachment guard

`dispatch` / `resume` run the Claude worker as a detached background job. A short outer OpenClaw `exec` timeout on the dispatch command must not kill the worker. If `poll` reports `failed-interrupted` with `worker_pid_dead_before_result`, inspect `/tmp/claude-subagent-logs/<task-id>.stream` before concluding Claude never started: a stream `system/init` event means the session exists and may be resumable even when the registry has no `.out` result.

### Budget multiplier

The stable workspace wrapper `/root/clawd/tools/claude-delegate.sh` sets `CLAUDE_DELEGATE_BUDGET_MULTIPLIER=5` by default, so numeric per-task caps are increased 5x before reaching Claude (for example `0.45` → `2.25`, `0.55` → `2.75`). Use `none` for no cap, or prefix a deliberate tiny probe with `CLAUDE_DELEGATE_BUDGET_MULTIPLIER=1` when you really want the literal number.

## When to prefer this over ACP

In this workspace, this skill is now the **default Claude path**.

Prefer this skill when you want:
- a boring local wrapper around Claude CLI
- a non-root runner user with synced auth/binary state
- bounded filesystem access through a chosen workdir
- cheap monitoring and resume without a chat-thread harness

Claude ACP is disabled for normal workspace use here, so do not route routine Claude work through ACP.

## Files to load when needed

- Setup, auth, env knobs, and profile customization: `references/setup.md`
- Delegate bootstrap guidance for this skill: `CLAUDE.delegate.md`

## Notes

- `scripts/cc-profile.sh` supports `CLAUDE_DELEGATE_PROFILES=/abs/path/to/profiles.json`.
- Profile paths support `~` and environment variable expansion.
- `scripts/ensure-nonroot-delegation.sh` supports env overrides for source paths if your Claude or acpx installs live somewhere else.
- Delegate bootstrap is on by default. Disable with `CLAUDE_DELEGATE_BOOTSTRAP=0` or change the instruction filename with `CLAUDE_DELEGATE_DOC_BASENAME`.
