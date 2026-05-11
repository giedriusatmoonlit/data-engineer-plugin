---
description: Bulk PR-review-addressing orchestrator for Azure DevOps. Triages N PRs in parallel, then spawns one claude-squad session per PR running /fix-pr in its own worktree. Each session stops one step before push — no automated git push, no automated ADO comment replies. Sibling command to api-scraper's /batch-prep but PR-keyed.
argument-hint: <PR-NNNN|NNNN|#NNNN> [...] | --mine | --report <BATCH_ID> | --launch <BATCH_ID> [--force] | --status <PR>... | --no-launch | --dry-run <PR>... | --refresh <BATCH_ID>
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# /data-engineer-plugin:address-pr

Bulk PR onboarding for ADO PRs. Diagnoses every input PR (fetches via
`az repos pr`, categorizes comments via the **`address-pr-comments`**
skill, writes per-PR packets to `pr_notes/PR-NNNN/`), then auto-spawns
one claude-squad session per PR. Inside each session,
`/data-engineer-plugin:fix-pr` runs the per-PR three-phase loop.

This command **never pushes** and **never replies to ADO threads**. It
prepares everything; the developer pushes when they're ready.

## Forms

```
/data-engineer-plugin:address-pr 2299 2301 2305    # explicit (any of: 2299, #2299, PR-2299)
/data-engineer-plugin:address-pr --mine            # az repos pr list --creator @me
/data-engineer-plugin:address-pr --status PR-2299  # read-only snapshot
/data-engineer-plugin:address-pr --report <PB_ID>  # re-render existing batch
/data-engineer-plugin:address-pr --refresh <PB_ID> # re-fetch comments, append new ones
/data-engineer-plugin:address-pr --launch <PB_ID>  # standalone: just spawn cs sessions
/data-engineer-plugin:address-pr --dry-run 2299 2301
```

Optional flags:

```
--concurrency N        Override per-PR parallel fan-out cap (default 3)
--no-launch            Skip the cs-work spawn at the end. Default is to
                       auto-spawn one cs instance per ready PR.
--force                With --launch, tear down existing tmux/cs entries
                       for the batch's PRs and re-spawn fresh.
```

## Three phases per PR (set by /fix-pr)

| Phase | Done by             | What | Gate                          |
|-------|---------------------|------|-------------------------------|
| 0→1   | this command        | TRIAGE: pr_packet.json, comments.md, plan.md | every comment categorized |
| 1→2   | /fix-pr in cs pane  | ADDRESS: edits + commits in worktree | all MFs `[x]`, tree clean, new commits |
| 2→3   | /fix-pr in cs pane  | HANDOFF: handoff.md for the developer | handoff.md non-empty |

After phase 3, the developer (human) pushes + replies on ADO. `fix-pr`
never automates those.

## Preflight checks

Before any work:

1. **Required env**:
   - `$DATA_ENG_WORK_ROOT` (default `$HOME/.data-engineer-work`)
   - `$DATA_ENG_REPO_ROOT` OR `$SCRAPER_REPO_ROOT` set and a directory
   - `$ADO_ORG` + `$ADO_PROJECT` set, OR `az devops configure --list`
     already has `organization` + `project` defaults
2. **Hard deps**: `az`, `jq`, `tmux`, `git` on PATH. `az account show`
   succeeds (otherwise instruct the user to `az login` / paste a PAT).
3. **Auto-spawn deps** (only if `--no-launch` not passed): `claude-squad`
   (`cs`) installed. If absent, warn but still write the packets — the
   developer can spawn manually.
4. **`$DATA_ENG_WORK_ROOT/pr_notes/_batch/` writable** — create it if missing.
5. **At least one PR resolved**.

## Form-specific behavior

### Explicit PR list / `--mine`

1. **Resolve PR list**:
   - Explicit list → canonicalize each (1234, #1234, PR-1234 → PR-1234)
   - `--mine` → `az repos pr list --creator @me --status active --output json`
2. **Read prior state per PR**: for each, check
   `$DATA_ENG_WORK_ROOT/pr_notes/PR-NNNN/state.json`. Parse `phase`,
   `batch_id`, `awaiting_human`, `must_fix_addressed/total`.
3. **Resolve or generate BATCH_ID**:
   - All same `batch_id` → re-run that batch (same as `--refresh`)
   - All different / mixed → fresh `PB-YYYY-MM-DD-NN`
4. **Pre-spawn status table** (always print):
   ```
   BATCH_ID:  PB-2026-05-11-01

   | PR        | Ticket   | Phase            | Will run? |
   |-----------|----------|------------------|-----------|
   | PR-2299   | DAT-591  | 1 (triaged)      | spawn cs (resume at ADDRESS) |
   | PR-2301   | DAT-605  | 0 (no state)     | triage + spawn cs |
   | PR-2305   | DAT-612  | 2 (addressed)    | spawn cs (resume at HANDOFF) |
   ```
5. **Per-PR triage** (in parallel, capped by `--concurrency`): for each
   PR at phase 0, run the **`address-pr-comments`** skill:
   - `az repos pr show --id N --output json`
   - `az repos pr list-comments --id N --output json` (threads + replies)
   - Parse DAT-NNN from title or description (record in
     `state.ticket_id`; empty if not found — non-fatal)
   - Categorize every comment: MF / NIT / Q / RESOLVED (rules in the skill)
   - Write `pr_notes/PR-NNNN/{pr_packet.json, comments.md, plan.md, state.json}`
   - Phase 0 → 1 (run `pr-stage-complete.sh PR-NNNN`)
6. **Write `pr_notes/_batch/<BATCH_ID>/batch.json`**:
   ```json
   {
     "batch_id": "PB-...",
     "created_at": "...",
     "ado_org": "...",
     "ado_project": "...",
     "prs": [
       {"pr_id":"PR-2299","ticket_id":"DAT-591","source_branch":"...","target_branch":"master",
        "pr_url":"...","head_sha":"...","must_fix_total":3,"phase":1}
     ]
   }
   ```
7. **Auto-spawn cs sessions** unless `--no-launch`:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/launch-pr-batch.sh" "$BATCH_ID"
   ```
   The launcher creates the worktrees (`<repo>-pr-NNNN`), spawns tmux
   sessions, queues `/data-engineer-plugin:fix-pr PR-NNNN`, writes
   cs state.json entries, and prints attach instructions + Cursor
   workspace path.

### `--status <PR>...`

Pure read. Resolve PRs, print the same table as step 4 above, exit.
No writes, no `az` call, no spawn. Uses cached `state.json` only.

### `--report <BATCH_ID>`

Re-render the table from existing `batch.json`. No diagnosis, no fan-out.

### `--refresh <BATCH_ID>`

Re-run `az repos pr show` + `list-comments` for every PR in the batch.
Diff against the cached `pr_packet.json`:
- New comments → append to `comments.md` as `NEW:` items (preserving
  existing checkbox state on items already there)
- Resolved threads → mark `RESOLVED` in `comments.md`
- Push-since-triage detection: if the PR's `head_sha` differs from
  `state.head_sha_at_triage`, surface this — the reviewer or you may
  have pushed since triage; the developer needs to decide whether to
  rebase the worktree or accept the divergence.

### `--launch <BATCH_ID>`

Skip preflight #1–#5 except env-var checks. Run only
`bash $CLAUDE_PLUGIN_ROOT/scripts/launch-pr-batch.sh <BATCH_ID>`.
With `--force`, the launcher tears down existing tmux + cs entries for
that batch's PRs before re-spawning.

### `--dry-run`

Triage only. Diagnose each PR, print disposition (counts of MF/NIT/Q,
parsed ticket id if any), **no** writes to disk, **no** fan-out.

## Output (developer-facing, post-completion)

```
Batch PB-2026-05-11-01 complete.

| PR        | Ticket   | MF  | NIT | Q   | Phase            | Next |
|-----------|----------|-----|-----|-----|------------------|------|
| PR-2299   | DAT-591  |  3  |  2  |  1  | 1 (triaged)      | cs pane open; /fix-pr will resume at ADDRESS |
| PR-2301   | DAT-605  |  5  |  4  |  0  | 1 (triaged)      | cs pane open |
| PR-2305   | DAT-612  |  0  |  0  |  0  | (auto-handed-off) | nothing to address |

Batch report:  $DATA_ENG_WORK_ROOT/pr_notes/_batch/PB-.../batch.json
Cursor:        cursor $DATA_ENG_WORK_ROOT/pr_notes/_batch/PB-.../batch.code-workspace
```

## What this command does NOT do

- ❌ Push the branches — that's `/fix-pr`'s handoff, executed by the dev
- ❌ Reply to ADO threads via API
- ❌ Approve / complete / abandon PRs
- ❌ Edit any code — only writes under `pr_notes/`
- ❌ Spawn anything other than the triage work and `launch-pr-batch.sh`

## Implementation notes for the model running this command

1. Run preflight. Abort on first failure with a specific error.
2. Resolve PR list per form.
3. State scan: read each PR's `pr_notes/PR-NNNN/state.json` if present.
4. Resolve BATCH_ID.
5. Print the pre-spawn status table.
6. For `--status` / `--report`, exit here.
7. For everything else, run the per-PR triage loop. For each PR at
   phase 0, use the **`address-pr-comments`** skill — its `SKILL.md`
   has the canonical categorization rules and ADO API call shapes.
8. Write `batch.json` once all triage is done.
9. Print the completion table.
10. Unless `--no-launch` / `--status` / `--report` / `--dry-run`, run
    `launch-pr-batch.sh <BATCH_ID>` and append its output verbatim.

Do **not** spawn arbitrary Task agents from this command. The triage is
small enough to run inline (one PR ≈ a few `az` calls + categorization);
the launcher handles all session spawning.
