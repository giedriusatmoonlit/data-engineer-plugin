---
description: Per-PR in-session command. Walks one ADO PR through three phases — triage comments → make + commit fixes → write developer handoff. Stops before push and before any ADO comment reply. Spawned automatically by /address-pr into each cs-work pane; can also be run directly.
argument-hint: <PR-NNNN|NNNN|#NNNN> [--refresh]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# /data-engineer-plugin:fix-pr

Per-PR state machine. Takes the **PR id** (any of `2299`, `#2299`,
`PR-2299` — canonicalized to `PR-NNNN`), reads
`.notes/state.json` (inside the PR's worktree), runs the next phase, validates the gate
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
3. **State** — read `<worktree>/.notes/state.json`. If missing, abort with:
   > Run /data-engineer-plugin:address-pr <PR_ID> first — no triage
   > packet yet.
   You're already cd'd into the worktree (the launcher set the tmux
   session's working dir to the worktree), so `.notes/state.json`
   resolves relative.
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

Every spawned pane self-triages on its first turn — the master
`/address-pr` doesn't pre-fetch anything. Run the **`address-pr-comments`**
skill inline. It will:

- Fetch `az repos pr show` + `list-comments` + threads
- Cache the JSON to `.notes/pr_packet.json` (used by `--refresh` for diffing)
- Categorize every comment in memory: `must-fix` / `nit` / `question` /
  `resolved` (rules in the skill)
- Write the categorization as structured data into `.notes/state.json`:
  ```json
  {
    "categorized_comments": [
      {"id": "MF-1", "kind": "must-fix", "thread_id": "12345",
       "file_path": "Scrapers/NO/...", "line": 128, "reviewer": "@alice",
       "comment_excerpt": "DST watermark...", "thread_url": "...",
       "relevant_skills": ["api-scraper:scraper-rules", ...]},
      ...
    ],
    "decisions": []
  }
  ```
- Populate the canonical fields: `pr_id`, `pr_url`, `pr_title`,
  `source_branch`, `target_branch`, `head_sha_at_triage`, `ticket_id`
  (parsed DAT-NNN if found), `must_fix_total`, `nits_total`,
  `questions_total`, `last_known_vote`, `comments_fetched_at`

**No markdown files** written this phase. The per-MF presentation
happens in chat during ADDRESS — no `comments.md` / `plan.md` to keep
in sync with state.

Then:
```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
```

### Phase 1 → 2  ADDRESS  (consultative loop — present in chat, dev decides, you apply)

You are **not** an autonomous fixer. You are a reviewer's collaborator.
For every MF (and non-trivial NIT), present the proposal in chat and
get the developer's nod before touching code. The chat IS the
conversation; there is no plan.md / comments.md to maintain.

#### Per-MF loop

Read `.notes/state.json`'s `categorized_comments` array and
`decisions` array. For each `MF-N` in `categorized_comments` (in array
order) whose `id` is **not yet in** `decisions[].mf_id`:

1. **Read the entry** from state.json (it has comment_excerpt,
   file_path, line, reviewer, thread_url, relevant_skills).

2. **Read the listed skills**. For each `<plugin>:<skill-name>` in
   `relevant_skills`, resolve via:
   ```bash
   ls $HOME/.claude-work/plugins/cache/<plugin>/<plugin>/*/skills/<skill-name>/SKILL.md
   ```
   Read each match. If missing: print a soft warning and continue
   without that domain knowledge.

3. **Print the MF block in chat**:
   - The comment excerpt + file:line + reviewer
   - The code region around file:line (3-10 lines, Read'd inline)
   - Your **proposed approach** — one paragraph, concrete
   - Open question if there's genuine ambiguity

4. **Ask the dev**, one short prompt. Five options:
   - `approve` — apply the proposed approach
   - `different: <text>` — apply what the dev describes; their `<text>`
     becomes the `dev_note` on the decision
   - `skip` — defer this MF; counter does NOT bump; gate refuses Phase 2
     until either resolved or removed from `categorized_comments`
   - `show alternatives` — propose 2-3 terse alternatives, then re-ask
   - `show related code` — Read more files, print a one-paragraph map,
     then re-ask

   If the dev says anything else, interpret as `different: <their text>`.

   **Shortcut**: if the dev's first message in the phase is `approve
   all` or `auto`, skip the per-MF prompts and apply every proposed
   approach autonomously. Still surface Open Question items for explicit
   confirmation. Useful when the dev has read your proposals end-to-end
   in chat already.

5. **Apply the approved approach** (yours or the dev's override). Stay
   inside the worktree. Follow conventions from the skills you just read.

6. **Commit + record the decision**:
   ```bash
   git -C "$WORKTREE" add <files>
   git -C "$WORKTREE" commit -m "review: address MF-N (<short>)"
   ```
   Then append to `state.decisions[]` (atomic — use `pr_state_update`):
   ```json
   {
     "mf_id": "MF-1",
     "action": "applied",
     "commit_sha": "abc123",
     "applied_summary": "Converted to UTC via pendulum",
     "dev_note": "<verbatim if overridden, else omit>",
     "decided_at": "<iso>"
   }
   ```
   Bump `state.must_fix_addressed` by 1 in the same `jq` expression.

7. **If `skip`**: append a `"deferred"` decision instead, with
   `deferred_reason`:
   ```json
   {"mf_id": "MF-1", "action": "deferred", "deferred_reason": "...", "decided_at": "..."}
   ```
   Do NOT bump `must_fix_addressed`. The gate will refuse Phase 2 until
   the deferred items are addressed OR removed from `categorized_comments`
   (the dev's choice — if they decide it's not actually a blocker, edit
   state.json to drop it).

#### Nits

Same loop, prompt is just `approve` / `skip` (no alternatives — nits
don't need debate). Approved nits get committed + a decision with
`kind: "nit"`. Skipped nits don't gate.

#### Questions (Q-N)

**Never code-change for a question.** They become reply text:

- Show the draft reply
- Ask: `approve / rewrite: <text> / skip`
- Append a decision: `{kind: "question", q_id, reply_text, decided_at}`
- The actual reply happens at HANDOFF (dev pastes on ADO); you only
  collect text here.

#### Audit trail

The chat history IS the audit trail. State.decisions[] is the structured
log — every applied/deferred MF, every question reply, with timestamps
and commit SHAs. handoff.md (built at Phase 3) renders this human-readable.

#### Gate

When every MF in `categorized_comments` has a corresponding entry in
`decisions[]` (action="applied" or "deferred"),
`must_fix_addressed == must_fix_total`, the worktree is clean, and at
least one new commit exists since `head_sha_at_triage`:

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
```

The gate refuses to advance if any MF is undecided OR if
`must_fix_addressed < must_fix_total` (= some MFs were deferred but not
removed from `categorized_comments`).

### Phase 2 → 3  HANDOFF

Render `.notes/handoff.md` from
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

→ Read .notes/handoff.md
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
`ls` random `.notes/*` paths to figure out what exists.

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
