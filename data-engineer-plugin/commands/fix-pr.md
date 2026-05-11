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

## Orientation banner (always first, deterministic)

The very first thing every turn — before reading any state, before any
phase work, before any plan — is to print the situational briefing:

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-status.sh <PR_ID>
```

This is a shell script (not model-generated text), so the output is
deterministic: PR title + URL, linked ticket, current phase + name,
worktree health (branch, dirty/clean, commits since triage),
must-fix / nit / question counts, the top 3 unaddressed MFs, and the
single most useful next action for the current phase.

After the banner prints, state in ONE sentence what *this turn* will do.
Then proceed.

Do not skip this step. Even on a resumed session where the state is
"obvious," the developer benefits from seeing the same briefing every
time — it's the same shape, so they scan it in under 2 seconds.

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

### Phase 1 → 2  ADDRESS  (consultative loop — propose, ask, apply)

You are **not** an autonomous fixer in this phase. You are a reviewer's
collaborator. For every MF (and non-trivial NIT), present the plan and
get the developer's nod before touching code. This dramatically cuts
review round-trips compared to "guess what the reviewer meant, edit,
commit".

#### Per-MF loop

Walk `plan.md`'s MF blocks in the order they appear. For each `MF-N`:

1. **Print the MF block from plan.md verbatim** — reviewer intent, code
   excerpt, relevant skills, **Proposed approach**, **Open question**.
   The developer should see this *before* any code change.

2. **Read the listed skills**. For each `<plugin>:<skill-name>` in the
   "Relevant skills" line, resolve the path:
   ```bash
   ls $HOME/.claude-work/plugins/cache/<plugin>/<plugin>/*/skills/<skill-name>/SKILL.md
   ```
   Read each match. If the file isn't there, print a soft warning
   (`skill <name> not installed — proceeding without that domain
   knowledge`) and continue. **Do not** invent the skill's content.

3. **Ask the developer**, one short prompt. The five options are:
   - `approve` — apply the Proposed approach as written
   - `different: <description>` — apply something else the dev describes
     (the description goes verbatim under the MF in comments.md as a
     `Dev note:` line for audit)
   - `skip` — defer this MF. Marked in comments.md with a `Deferred:`
     note. Does NOT bump `must_fix_addressed`. The Phase 1→2 gate will
     refuse to advance until either it's done or moved to a follow-up
     issue.
   - `show alternatives` — you propose 2–3 alternative approaches,
     terse, then re-ask
   - `show related code` — you Read more files the change touches and
     print a one-paragraph map, then re-ask

   If the dev responds with anything else, interpret as `different:
   <their text>`.

   **Shortcut**: if the dev's first message in the phase is
   `approve all` (or `auto`), skip the per-MF prompts and apply every
   Proposed approach autonomously. Surface only the Open question items
   for confirmation. Use this for plans the dev has already read end to
   end.

4. **Apply the approved approach** (your own or the dev's override):
   - Stay inside the worktree (`state.worktree_path`). `session-guard`
     rejects writes outside it.
   - For each edited file, follow the conventions in the skills you
     just read — naming, imports, structure. Don't re-derive from
     scratch what the skill already specifies.

5. **Record + commit**:
   - Append to `comments.md` under the MF item:
     - `Dev note: <verbatim dev text>` if they overrode
     - `Applied: <one-line summary>` always
   - Mark the checkbox: `- [ ] MF-N` → `- [x] MF-N`
   - Bump `state.must_fix_addressed` by 1 (use `pr_state_update` from
     `_env.sh`)
   - Commit. One commit per MF unless the dev explicitly asks to
     group:
     ```bash
     git -C "$WORKTREE" add <files>
     git -C "$WORKTREE" commit -m "review: address MF-N (<short>)"
     ```

6. **If `skip`**: append `Deferred: <dev reason or 'no reason given'>`
   under the MF in comments.md, leave the checkbox `[ ]`. Do NOT bump
   the counter. Move on to the next MF.

#### Nits

Same consultative loop, but the prompt is just `approve` / `skip`
(no alternatives flow — nits don't need debate). Approved nits get
committed too. Skipped nits don't gate.

#### Questions (Q-N)

**Never autonomously code-change for a question.** They become reply
text. Walk the Q section of plan.md and for each `Q-N`:
- Show the draft reply
- Ask: `approve / rewrite: <text> / skip`
- Record the dev's chosen reply text in comments.md under the Q
- (The actual reply happens at HANDOFF; you only collect text here)

#### Gate

When all MFs are `[x]` or `Deferred:`-tagged (with at least one of each
of MF resolved), comments.md has no unchecked `^- \[ \] MF-` lines, the
worktree is clean, and there's at least one new commit since
`state.head_sha_at_triage`:

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
```

The gate will refuse to advance if `must_fix_addressed < must_fix_total`,
which is exactly what you want when items were deferred — you'll either
have to come back to them or convert them into follow-up issues before
shipping this round.

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
