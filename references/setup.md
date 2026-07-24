# Claude Delegate setup

## What this package gives you

A local Claude Code delegation lane with:
- dispatch, poll, result, resume
- optional non-root runner execution
- profile-based workdir scoping
- runner self-heal for Claude binary, auth file, and acpx install when you use the provided ensure script
- default bootstrap guidance that tells Claude to discover/read nearby `CLAUDE.delegate.md`, `AGENTS.md`, `TOOLS.md`, and `README.md` files before substantive work

## Quick install

1. Install Claude Code and log in once.
2. Copy this skill into your OpenClaw skills directory.
3. Edit `profiles.json` for your project roots, or keep a host-local profiles file and export `CLAUDE_DELEGATE_PROFILES=/abs/path/to/profiles.json`.
4. If you want a non-root runner, set these as needed:
   - `CLAUDE_RUNNER_USER`
   - `CLAUDE_RUNNER_HOME`
   - `CLAUDE_BIN`
   - `CLAUDE_PERMISSION_MODE`
   - `CLAUDE_BACKEND`
   - `CLAUDE_DELEGATE_BOOTSTRAP`
   - `CLAUDE_DELEGATE_DOC_BASENAME`
5. Run `scripts/setup.sh --check-only`.
6. Run `scripts/claude-delegate.sh doctor`.

## Delegate instruction files

By default, Claude Delegate appends bootstrap guidance that tells Claude to:
- discover and read the nearest `CLAUDE.delegate.md` files from the workdir, its ancestors, and any `add_dirs`
- inspect nearby `AGENTS.md`, `TOOLS.md`, and `README.md` files before substantive work

Recommended layering:
- workspace-level `CLAUDE.delegate.md`
- shared folder-level `CLAUDE.delegate.md`
- skill or repo-level `CLAUDE.delegate.md`

Knobs:
- `CLAUDE_DELEGATE_BOOTSTRAP=0` disables the default bootstrap prompt
- `CLAUDE_DELEGATE_DOC_BASENAME=SomethingElse.md` changes the filename Claude looks for

## Stable commands

```bash
bash scripts/claude-delegate.sh dispatch <profile> <budget|none> <model> <label> "<task>"
bash scripts/claude-delegate.sh poll <task-id>
bash scripts/claude-delegate.sh result <task-id>
bash scripts/claude-delegate.sh resume <task-id> <budget|none> "<follow-up>"
# Use budget "none" for no Claude --max-budget-usd cap; numeric budgets are for deliberately bounded probes.
bash scripts/claude-delegate.sh list --all
bash scripts/claude-delegate.sh doctor
```

## Profiles

`cc-profile.sh` reads `profiles.json` next to the skill by default.

Override it per host:

```bash
export CLAUDE_DELEGATE_PROFILES=/abs/path/to/profiles.json
```

Path values inside profiles support:
- `~`
- `${HOME}` and other environment variables

## Non-root runner notes

`ensure-nonroot-delegation.sh` is the boring path when you want root-owned OpenClaw to launch Claude as another user.

It can sync these from a source install into the runner account:
- Claude binary
- Claude auth file
- acpx config
- runner-local acpx install

If your host uses different source paths, override them before calling the wrapper:
- `OPENCLAW_ACPX_PACKAGE`
- `ROOT_CLAUDE_LINK`
- `ROOT_CLAUDE_CREDS`
- `ROOT_ACPX_CONFIG`
- `DEFAULT_ACPX_SPEC`

## What not to assume

- A healthy `claude auth status` is not enough. Run a real prompt probe.
- A plain text completion test does not prove tool-call compatibility.
- ACP and local CLI delegation are different lanes. Pick one on purpose.

## Recommended sanity checks

1. `bash scripts/setup.sh --check-only`
2. `bash scripts/claude-delegate.sh doctor`
3. `bash scripts/claude-delegate.sh dispatch scratch 0.10 sonnet smoke "Reply with exactly CLAUDE-DELEGATE-SMOKE-OK"`
4. `bash scripts/claude-delegate.sh result <task-id>`

## Packaging note

This skill intentionally keeps host-specific profiles outside the core workflow. For open-source sharing, keep the skill generic and put personal repo paths in your local `CLAUDE_DELEGATE_PROFILES` file.
