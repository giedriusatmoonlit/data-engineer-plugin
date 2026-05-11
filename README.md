# data-engineer-plugin

A Claude Code plugin with data-engineer helpers. First (and currently
only) helper: `/address-pr` — a 3-phase Azure DevOps PR-review-addressing
flow that parallelizes across PRs via [claude-squad](https://github.com/smtg-ai/claude-squad).

Sibling plugin to [api-scraper](https://github.com/giedriusatmoonlit/api-scraper).
Both can be installed together; they share no code and lock in different
namespaces (`api-scraper` locks by `DAT-NNN`, this plugin locks by
`PR-NNNN`).

## What /address-pr does

```
/data-engineer-plugin:address-pr 2299 2301 2305
```

For each PR:

1. **TRIAGE** — fetches the PR + comments via `az`, categorizes every
   comment thread (must-fix / nit / question / resolved), writes
   `pr_notes/PR-NNNN/{pr_packet.json, comments.md, plan.md, state.json}`.
2. **ADDRESS** — spawns a `cs-work` session in a fresh worktree
   (`<repo>-pr-NNNN`), where `/fix-pr` walks must-fix items one by one,
   makes the edits, commits them.
3. **HANDOFF** — writes `pr_notes/PR-NNNN/handoff.md` with: new commit
   SHAs, push command, draft replies for each question comment.

**It stops there.** No automated `git push`, no automated ADO replies.
The developer reviews the handoff, pushes, and replies. That stop-line
is deliberate.

## What it doesn't do

- ❌ Push branches
- ❌ Reply to ADO threads via API
- ❌ Approve / complete / abandon PRs
- ❌ Edit anything outside the per-PR worktree (`session-guard` PreToolUse hook rejects)
- ❌ Spawn subagents across multiple PRs from one session

## Phases

| Phase | Name      | Where           | Gate                                    |
|-------|-----------|-----------------|-----------------------------------------|
| 0 → 1 | TRIAGE    | master session  | every comment categorized; plan ordered |
| 1 → 2 | ADDRESS   | spawned cs pane | all MFs `[x]`, tree clean, new commits  |
| 2 → 3 | HANDOFF   | spawned cs pane | handoff.md non-empty                    |

The gate is enforced by `scripts/pr-stage-complete.sh`, not by the model.

## Install

```bash
# In your claude config dir (or cs-work's):
/plugin marketplace add giedriusatmoonlit/data-engineer-plugin
/plugin install data-engineer-plugin@data-engineer-plugin
/reload-plugins
```

Then run the installer for the one-time work-root + dep check:

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/install.sh
```

## Prerequisites

| | Hard | Soft |
|---|---|---|
| Tools | `jq`, `tmux`, `git`, `az` (with `az login` + `az devops login`) | `cs` (claude-squad), `cursor` |
| Env vars | `DATA_ENG_WORK_ROOT` (or default `$HOME/.data-engineer-work`); `DATA_ENG_REPO_ROOT` **or** `SCRAPER_REPO_ROOT`; `ADO_ORG` + `ADO_PROJECT` (or `az devops configure --defaults`) | `DATA_ENG_WORKTREE_PARENT` (defaults to `SCRAPER_WORKTREE_PARENT` or `$HOME/worktrees`) |

If you already have `api-scraper` installed, **most env vars are reused**
(`SCRAPER_REPO_ROOT` and `SCRAPER_WORKTREE_PARENT` fall through as
fallbacks). You don't need to maintain a duplicate set.

## Layout

```
data-engineer-plugin/
├── .claude-plugin/plugin.json
├── commands/
│   ├── address-pr.md          # orchestrator (multi-PR)
│   └── fix-pr.md              # per-session (single-PR loop)
├── skills/
│   └── address-pr-comments/
│       ├── SKILL.md           # categorization rules + ADO API shapes
│       └── handoff.template.md
├── scripts/
│   ├── _env.sh                # sourced helpers
│   ├── install.sh
│   ├── lock.sh                # per-session lock; subject = PR-NNNN
│   ├── session-guard.sh       # PreToolUse hook
│   ├── launch-pr-batch.sh     # spawns cs-work sessions per PR
│   └── pr-stage-complete.sh   # phase exit-gate validator
└── hooks/
    └── hooks.json
```

## On-disk state

```
$DATA_ENG_WORK_ROOT/
├── pr_notes/
│   ├── PR-2299/
│   │   ├── state.json
│   │   ├── pr_packet.json     # az response cache
│   │   ├── comments.md        # MF-/NIT-/Q- with checkbox status
│   │   ├── plan.md            # action order
│   │   └── handoff.md         # phase-3 output for the developer
│   └── _batch/
│       └── PB-2026-05-11-01/
│           ├── batch.json
│           └── batch.code-workspace
└── .session-lock-<SESSION_ID>.json
```

## Comparison with api-scraper

|                       | api-scraper                  | data-engineer-plugin           |
|-----------------------|------------------------------|--------------------------------|
| Subject               | `DAT-NNN` (Linear ticket)    | `PR-NNNN` (ADO PR id)          |
| Pipeline length       | 7 stages                     | 3 phases                       |
| Master command        | `/api-scraper:batch-prep`    | `/data-engineer-plugin:address-pr` |
| Per-session command   | `/api-scraper:make-scraper`  | `/data-engineer-plugin:fix-pr` |
| Lock file             | `.session-lock-*.json` (DAT) | `.session-lock-*.json` (PR)    |
| Work root             | `$SCRAPER_WORK_ROOT`         | `$DATA_ENG_WORK_ROOT`          |
| Worktree convention   | `<repo>-<ticket-lower>`      | `<repo>-pr-NNNN`               |
| Pushes / API replies  | Pushes + opens PR            | Stops one step before push     |

## Adding more helpers

This plugin is the "lots of small data-engineer routines" home. To add a
new helper:

1. Drop a `commands/<name>.md` (the slash command surface)
2. Add agents/skills/scripts under their respective dirs
3. Wire any PreToolUse / Stop hooks into `hooks/hooks.json`
4. Update this README

Keep the install discipline: `bash scripts/install.sh --check` should
still pass for the new helper's prerequisites, or the installer should
gain a new probe.
