---
description: Per-PR in-session command. Walks one ADO PR through three phases — triage comments → make + commit fixes → write developer handoff. Stops before push and before any ADO comment reply. Spawned automatically by /address-pr into each cs-work pane; can also be run directly.
argument-hint: <PR-NNNN|NNNN|#NNNN> [--refresh]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# /data-engineer-plugin:fix-pr

Per-PR state machine. Takes the **PR id** (any of `2299`, `#2299`,
`PR-2299` — canonicalized to `PR-NNNN`), reads
`pr_notes/PR-NNNN/state.json`, runs the next phase, validates the gate
via `pr-stage-complete.sh`, advances.

Same shape as `api-scraper`'s `/make-scraper` but for PRs — three
phases instead of seven stages, and it deliberately **stops before
push and before ADO replies**.

## The three phases

| Phase | Name      | What you produce                              | Gate                                   |
|-------|-----------|-----------------------------------------------|----------------------------------------|
| 0 → 1 | TRIAGE    | pr_packet.json, comments.md, plan.md          | every comment categorized; plan ordered |
| 1 → 2 | ADDRESS   | new commits in the worktree, MFs checked off  | must_fix_addressed == must_fix_total + clean tree + commits since triage |
| 2 → 3 | HANDOFF   | handoff.md (developer's push checklist)       | handoff.md non-empty                   |

Phase 3 is **terminal for this command**. fix-pr never:
- pushes the branch
- replies to ADO comment threads
- approves / completes / abandons the PR

## Preflight (every run)

Before any phase work:

1. **Canonicalize the PR id**: accept `2299`, `#2299`, `PR-2299` →
   canonical `PR-2299`. Reject anything else.
2. **Session lock**:
   ```bash
   bash $CLAUDE_PLUGIN_ROOT/scripts/lock.sh acquire <PR_ID>
   ```
   If another PR holds the lock, refuse and tell the user. **Do not**
   run `lock.sh release` without arguments to bypass — that's caught
   and refused by lock.sh itself.
3. **State** — read `pr_notes/<PR_ID>/state.json`. If missing, abort
   with:
   > Run /data-engineer-plugin:address-pr <PR_ID> first — no triage
   > packet yet.
4. **Worktree** — `state.worktree_path` must exist on disk. If not,
   abort with the restore instructions (see "Worktree missing" below).
5. **Branch** — confirm the worktree is on `state.source_branch`. If
   on a different branch, refuse and surface — don't auto-switch.
6. **--refresh** — if passed, re-run the triage `az repos pr` calls
   and diff against cached `pr_packet.json`. Append any new comments to
   `comments.md` as `NEW:` items (preserving existing checkbox state on
   pre-existing items). Bump `must_fix_total` if new MFs landed.

## Orientation banner (always printed first)

Before any work, print this block so the developer knows the state:

```
== /data-engineer-plugin:fix-pr · <PR_ID> ==
PR:          #<N>   <PR_TITLE>
PR URL:      <PR_URL>
Ticket:      <DAT-NNN or "<none>">
Phase:       <N> · <PHASE_NAME>      (advance: pr-stage-complete.sh <PR_ID>)
Source:      <SOURCE_BRANCH>         (target: <TARGET_BRANCH>)
Worktree:    <WORKTREE_PATH>
Triage SHA:  <HEAD_SHA_AT_TRIAGE>    (HEAD now: <CURRENT_SHA>)
Must-fix:    <ADDRESSED>/<TOTAL> addressed
Nits:        <NITS_TOTAL>   Questions: <QUESTIONS_TOTAL>
Awaiting human: <true|false>
About to do: <one short sentence on this turn's intent>
```

## Phase work

### Phase 0 → 1  TRIAGE

If you're here, `/address-pr` did not complete triage for this PR.
Run the **`address-pr-comments`** skill inline (its SKILL.md has the
canonical rules + ADO API calls). It will:

- Fetch `az repos pr show` + `list-comments`
- Cache the JSON to `pr_notes/<PR_ID>/pr_packet.json`
- Categorize every comment: `MF-N` (must-fix), `NIT-N` (nit),
  `Q-N` (question), `RESOLVED` (thread already closed/fixed)
- Write `comments.md` with checkbox status: `- [ ] MF-1 file.py:42 · @reviewer · ...`
- Write `plan.md` — ordered action list (which files first, why)
- Populate `state.json` fields: `pr_id`, `pr_url`, `source_branch`,
  `target_branch`, `head_sha_at_triage`, `must_fix_total`,
  `nits_total`, `questions_total`, `ticket_id` (if parsed)

Then:
```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
```

### Phase 1 → 2  ADDRESS

For each `MF-N` block in `comments.md`, in the order `plan.md`
specifies:

1. Re-read the comment + the surrounding code (Read the file:line range
   the comment points at).
2. Make the edit. **Stay inside the worktree path** — `session-guard`
   will reject writes outside it.
3. Mark the checkbox in `comments.md`: `- [ ] MF-N` → `- [x] MF-N`.
4. Bump `state.must_fix_addressed` by 1 (atomic state update —
   `_env.sh` provides `pr_state_update`).
5. Commit. One commit per MF when reasonable; group only tightly
   related MFs:
   ```bash
   git -C "$WORKTREE" add <files>
   git -C "$WORKTREE" commit -m "review: address MF-N (<short>)"
   ```

Optional: nits + questions. Address what you intend to. Mark `[x]`
when done; leave `[ ]` when deferred. Nits/Qs are **not gating**.

When all MFs are `[x]` and the worktree is clean:
```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
```

### Phase 2 → 3  HANDOFF

Render `pr_notes/<PR_ID>/handoff.md` from
`${CLAUDE_PLUGIN_ROOT}/skills/address-pr-comments/handoff.template.md`.
It must contain:

- New commit SHAs since `state.head_sha_at_triage` (each with subject)
- Per-MF mapping: which commit addresses which MF-N
- Nit summary (this round / deferred — with explicit notes for deferred)
- Question replies — one **draft reply per Q-N** the developer can paste
  into the ADO thread
- Exact push command:
  ```
  git -C <worktree> push origin <source_branch>
  ```
- Exact ADO thread URLs to reply on (one per MF-N and Q-N — for ADO
  the comment URL is e.g.
  `https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<N>?discussionId=<T>`)

Then:
```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
```

…and announce to the developer:

```
Phase 3 (HANDOFF) reached. fix-pr is done for <PR_ID>.

→ Read pr_notes/<PR_ID>/handoff.md
→ Run the push command shown there
→ Reply to each thread using the draft replies in handoff.md

Re-running /data-engineer-plugin:fix-pr <PR_ID> --refresh will re-fetch
the PR (e.g. after reviewer responds) and append any new comments as
Phase-1 work.
```

Then release the lock:
```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/lock.sh release <PR_ID>
```

## Artifact-probing rule

Use `pr-stage-complete.sh --check-only <PR_ID>` to test if a phase
gate will pass — it's the deterministic source of truth. **Do not**
`ls` random `pr_notes/<PR_ID>/*` paths to figure out what exists.

## Worktree missing

If `state.worktree_path` doesn't exist on disk:

```
Worktree for <PR_ID> is gone. fix-pr won't recreate it inline.
Run this in your master cs-work session:

  /data-engineer-plugin:address-pr --launch <BATCH_ID>

…or, if you don't have a batch, re-triage:

  /data-engineer-plugin:address-pr <PR_ID>

That will fetch origin/<source_branch>, create the worktree, and
re-spawn this session.
```

## What this command does NOT do

- ❌ Push the branch — handoff.md tells the developer how
- ❌ Reply to ADO threads via API — handoff.md provides paste-ready drafts
- ❌ Re-open / complete / abandon the PR
- ❌ Edit anything outside `state.worktree_path` (session-guard rejects)
- ❌ Force-push, ever
- ❌ Spawn subagents that fan out across PRs — same single-PR discipline
  as api-scraper's `/make-scraper` enforces single-ticket
