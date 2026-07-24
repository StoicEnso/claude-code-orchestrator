# CLAUDE.delegate.md

This folder contains the local Claude Delegate skill used by Henry's workspace.

## Before changing this skill
- Read `SKILL.md` and `references/setup.md` first.
- If you are changing behavior under `scripts/`, inspect the wrapper entrypoint and the orchestrator/runner flow before editing.
- Check whether `/root/clawd/tools/claude-delegate.sh` and the OSS repo copy at `/root/clawd/oss/openclaw-claude-delegate` should stay aligned with the same behavior.

## Design rule
- Keep the local lane reliable and boring.
- Keep host-specific behavior behind environment variables or clearly local files.
- When you add bootstrap or instruction behavior, make the precedence obvious: nearest repo guidance first, broader workspace guidance second.

## Non-root runner path rule (ccbot)
The delegated Claude runs as non-root `ccbot`, which CANNOT traverse `/root` (mode 700, root-only) — so `/root/clawd/...` paths fail even though the data is there. In delegated prompts, reference the workspace by its REAL path `/data/clawd/...` (or `/data/landscapio-ceo`, `/data/kdp-ceo`) or use paths relative to the task workdir. `/root/clawd` is only a convenience symlink for the root shell.
