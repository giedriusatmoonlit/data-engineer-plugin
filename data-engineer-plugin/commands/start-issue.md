---
description: Start work on a new Moonlit issue. Resolves a Linear ticket (file new or reuse existing), creates or reuses a per-ticket git worktree, writes a scoped Cursor context file, acquires a session lock keyed by the ticket, and launches Cursor on the worktree. Hooks then refuse Write/Edit/Bash against any other ticket's worktree until the lock is released.
argument-hint: <DAT-NNN> | "<problem description>" [--no-cursor] [--branch <name>]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# /data-engineer-plugin:start-issue

One command to go from "here is a problem" to "I'm scoped to one DAT ticket
in a dedicated worktree with Cursor open and a hook fence around it."

Wraps the existing `linear-ticket-creator` skill (for new tickets) plus
git-worktree + `.cursor/rules/` + `issue-lock.sh` plumbing. Once locked, the
session-guard hooks refuse any Write/Edit/Bash that targets a different DAT
worktree — keeps cross-ticket bleed from happening.

## Reuse map

This command is glue. The actual work happens in existing pieces:

| Step | Reuses | Where |
|------|--------|-------|
| File new Linear ticket | `linear-ticket-creator` skill | `~/.claude-work/skills/linear-ticket-creator/SKILL.md` |
| Worktree resolve + add | `worktree-manager` skill conventions (`Databricks-dat-NNN` path, `.git/info/exclude` for `.notes/`) | `~/.claude-work/skills/worktree-manager/SKILL.md` |
| Branch + WIP-stash safety | `context-switch` skill — model should invoke it before this command if it suspects WIP on the wrong branch | `~/.claude-work/skills/context-switch/SKILL.md` |
| Session lock + cross-ticket fence | `lock.sh` / `session-guard.sh` pattern — `issue-lock.sh` / `issue-guard.sh` are the DAT-keyed siblings, sharing `_env.sh` helpers | `scripts/_env.sh` |
| SessionStart briefing | `session-start-briefing.sh` pattern — `issue-status.sh` is the DAT-keyed sibling | `scripts/session-start-briefing.sh` |
| Per-ticket scratchpad layout | The same `<worktree>/.notes/` + `.git/info/exclude` trick already used by `/fix-pr` | `init_pr_notes` in `_env.sh` (re-implemented as `init_issue_notes`) |

## Forms

```
/data-engineer-plugin:start-issue DAT-612                        # resume / reuse existing ticket
/data-engineer-plugin:start-issue "scraper FRX null Html"        # propose + (after confirm) file new ticket
/data-engineer-plugin:start-issue DAT-612 --no-cursor            # skip Cursor launch
/data-engineer-plugin:start-issue DAT-612 --branch bugfix/dat-612-html
```

## Required env

- `$DATA_ENG_WORK_ROOT` (default `$HOME/.data-engineer-work`) — lock files live here
- `$DATA_ENG_REPO_ROOT` OR `$SCRAPER_REPO_ROOT` — base checkout (the existing Databricks repo)
- `$DATA_ENG_WORKTREE_PARENT` OR `$SCRAPER_WORKTREE_PARENT` — where worktrees land (default `$HOME/worktrees`)
- Linear auth only when filing new: `LINEAR_API_KEY` or `~/.config/linear/token`

Hard deps: `git`, `jq`, `cursor` on PATH (skip Cursor check if `--no-cursor`).

## Steps the model must run

1. **Preflight.** Source `$CLAUDE_PLUGIN_ROOT/scripts/_env.sh`, then call
   `require_env DATA_ENG_WORK_ROOT` and verify a repo root resolves
   (`repo_root` returns non-empty). Abort with a specific message if anything's
   missing.

2. **Resolve ticket.**
   - First positional arg matches `^DAT-[0-9]+$` → that's the ticket id. Skip to step 4.
   - Otherwise: treat the arg as a problem description.
     a. Propose a one-line title + the suggested project/labels back to the
        user in chat. Ask: "File DAT ticket for this? (y/N)".
     b. On `y` (or "yes" / "go"), invoke the `linear-ticket-creator` skill
        with the description, capture the returned `DAT-NNN` + URL.
     c. On `n`, abort with: "OK — re-run with `DAT-NNN` once the ticket exists."

3. **Optional title hint.** If you have a title (from the just-filed ticket or
   from `--title <…>` if the user passed one), keep it — it's used to slug the
   branch when one needs creating.

4. **Run the worktree + lock setup script:**
   ```bash
   bash "$CLAUDE_PLUGIN_ROOT/scripts/start-issue.sh" "$DAT_ID" \
     --title "$TITLE_OR_EMPTY" \
     ${BRANCH:+--branch "$BRANCH"} \
     ${NO_CURSOR:+--no-cursor}
   ```
   The script handles every side-effect: branch resolve/create, `git worktree
   add` if missing, `.notes/issue-state.json`, `.cursor/rules/issue.md`,
   `issue-lock.sh acquire`, optional `cursor <worktree>` launch.

5. **Brief the user.** Print the script's output verbatim and a one-line
   recap pointing at the ticket URL + worktree path.

## What this command does NOT do

- ❌ Push, deploy, or run any Databricks job
- ❌ Edit any source code — only `.notes/` + `.cursor/rules/` inside the worktree
- ❌ Open a PR — that's `/api-scraper:pr-creator` or `/data-engineer-plugin:fix-pr`
- ❌ Touch a different ticket's worktree once locked

## After running

The session is locked to one DAT. The PreToolUse `issue-guard` hook will
refuse any Write/Edit/NotebookEdit/Bash that targets a path under another
`Databricks-dat-<other>` worktree. To unlock:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/issue-lock.sh" release DAT-612
```
