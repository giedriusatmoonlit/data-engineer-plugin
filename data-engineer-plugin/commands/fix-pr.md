---
description: Per-PR in-session command. Walks one ADO PR through two phases — triage comments → consultative per-thread address loop. Stops before push and before any ADO comment reply. Spawned automatically by /address-pr into each mprocs proc; can also be run directly.
argument-hint: <PR-NNNN|NNNN|#NNNN> [--refresh]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# /data-engineer-plugin:fix-pr

Per-PR state machine. Takes the **PR id** (any of `2299`, `#2299`,
`PR-2299` — canonicalized to `PR-NNNN`), reads
`.notes/state.json` (inside the PR's worktree), runs the next phase, validates the gate
via `pr-stage-complete.sh`, advances.

Same shape as `api-scraper`'s `/make-scraper` but for PRs — two phases
instead of seven stages, and it deliberately **stops before push and
before ADO replies**.

## The two phases

| Phase | Name      | What you produce                                | Gate                                                    |
|-------|-----------|-------------------------------------------------|---------------------------------------------------------|
| 0 → 1 | TRIAGE    | pr_packet.json + open_threads[] in state.json   | every active ADO thread listed in open_threads          |
| 1 → 2 | ADDRESS   | per-thread decisions + commits (when applicable)| every open_threads entry has a decision; commits clean  |

Phase 2 is **terminal for this command**. At the end of ADDRESS the
model prints an in-chat summary (commits since triage, per-thread
decision rendering, push command, ADO links). No `handoff.md` file —
the chat IS the handoff. fix-pr never:
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
   You're already cd'd into the worktree (the launcher set the mprocs
   proc's `cwd` to the worktree), so `.notes/state.json` resolves
   relative.
4. **Worktree** — `state.worktree_path` must exist on disk. If not,
   abort with the restore instructions (see "Worktree missing" below).
5. **Branch** — confirm the worktree is on `state.source_branch`. If
   on a different branch, refuse and surface — don't auto-switch.
6. **--refresh** — if passed, re-run the triage `az repos pr` calls
   and diff against cached `pr_packet.json`. Append new threads to
   `state.open_threads[]` with fresh T-N ids (continuing the sequence;
   preserve any `decisions[]` already recorded for pre-existing threads).
   Bump `open_threads_total` if new threads landed.

## Orientation banner (always first, deterministic)

The very first thing every turn — before reading any state, before any
phase work, before any plan — is to print the situational briefing:

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-status.sh <PR_ID>
```

This is a shell script (not model-generated text), so the output is
deterministic: PR title + URL, linked ticket, current phase + name,
worktree health (branch, dirty/clean, commits since triage),
open-thread counts (total / addressed / deferred / undecided), the top
3 undecided threads, and the single most useful next action for the
current phase.

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
- Filter ADO threads by status: keep `active`, drop
  `fixed`/`wontFix`/`closed`/`byDesign`/`pending`
- Write the open list as structured data into `.notes/state.json` —
  **no classification, no must-fix / nit / question tags**:
  ```json
  {
    "open_threads": [
      {"id": "T-1", "thread_id": "12345",
       "file_path": "Scrapers/NO/...", "line": 128, "reviewer": "@alice",
       "comment_excerpt": "DST watermark...", "thread_url": "...",
       "status": "active",
       "relevant_skills": ["api-scraper:scraper-rules", ...]},
      ...
    ],
    "resolved_threads": [...],
    "decisions": []
  }
  ```
- Populate the canonical fields: `pr_id`, `pr_url`, `pr_title`,
  `source_branch`, `target_branch`, `head_sha_at_triage`, `ticket_id`
  (parsed DAT-NNN if found), `open_threads_total`, `last_known_vote`,
  `comments_fetched_at`

**No markdown files** written this phase. The per-thread presentation
happens in chat during ADDRESS — no `comments.md` / `plan.md` to keep
in sync with state.

Then:
```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
```

### Phase 1 → 2  ADDRESS  (consultative loop — present in chat, dev decides, you apply)

You are **not** an autonomous fixer. You are the developer's collaborator
defending their code against a reviewer who may be wrong, partially
right, or asking for something not worth the cost. The chat IS the
conversation; there is no plan.md / comments.md to maintain.

**There is no must-fix / nit / question classification.** Every
non-resolved ADO thread is one `open_threads[]` entry. You walk them
in array order; the dev decides per thread whether it gets a code
change, a reply, or a defer.

#### Two hard rules (read before doing anything)

**Rule 1 — No code change or text-only reply without a per-thread dev
decision.**
You may **only** apply (step 5) a decision on a thread after the dev
has explicitly authorized that specific thread in their previous
message. Steps 1–4 are the presentation + ask. Step 4 ends the turn —
full stop. You do not proceed to step 5 in the same turn as step 4.

After a step-5 apply + step-6 record, you may immediately present the
**next** thread (steps 1–4) in the same turn — this keeps the loop
tight. But every turn must end at step 4 (a question to the dev) or
at the phase-2 gate-advance — never with multiple unapproved
decisions in a single turn.

The only exception: the dev's first message in the phase is literally
`approve all` or `auto`. In that case, fall through to autonomous mode
for the remaining threads in this phase (still pause for explicit
confirmation on any Open Question items the model raises).

**Anti-pattern to avoid**: reading state.open_threads, deciding all
the threads have "obvious answers", and applying every decision in
one turn. That bypasses Rule 1 and Rule 2 and defeats the entire point
of the consultative loop. If you find yourself about to do this —
stop, present the FIRST undecided thread in chat, ask the dev, end
the turn.

**Rule 2 — The reviewer is not the authority. The dev is.**
Your "proposed approach" is your own technical assessment, not a
restatement of the reviewer's comment. Reviewers are sometimes wrong,
sometimes asking for the wrong thing, sometimes flagging a real issue
but suggesting a worse fix than what's possible. When you propose an
approach:
  - If you agree with the reviewer, say why and propose the concrete change.
  - If you partially agree, say which part you'd take and which you'd push back on.
  - If you think the reviewer is wrong, say so explicitly — propose
    reply text that explains the disagreement, not a code change.
    The dev chooses whether to argue, concede, or compromise.
  - If the thread is a question (no code change implied), propose
    draft reply text. The dev pastes it on ADO after fix-pr exits.
  - Never default to "the reviewer asked for X, so I'll do X". That
    short-circuits the dev's judgment.

#### Per-thread loop

Read `.notes/state.json`'s `open_threads` array and `decisions` array.
Find the **first** `T-N` in `open_threads` (in array order) whose `id`
is **not yet in** `decisions[].thread_id`. Process **only that one**
this turn. Then stop.

1. **Read the entry** from state.json (it has comment_excerpt,
   file_path, line, reviewer, thread_url, relevant_skills).

2. **Read the listed skills**. For each `<plugin>:<skill-name>` in
   `relevant_skills`, resolve via:
   ```bash
   ls $HOME/.claude-work/plugins/cache/<plugin>/<plugin>/*/skills/<skill-name>/SKILL.md
   ```
   Read each match. If missing: print a soft warning and continue
   without that domain knowledge.

3. **Print the thread block in chat**:
   - The comment excerpt + file:line + reviewer + thread_url
   - The code region around file:line (3-10 lines, Read'd inline) — if
     the thread is general (no file:line), skip
   - Your **proposed approach** — one paragraph. Per Rule 2, this is
     YOUR assessment. Pick one:
       - **Code change**: agree / partially agree, describe the edit
       - **Reply only**: thread is a question, or you disagree with
         the reviewer — propose draft reply text
       - **Defer suggestion**: out-of-scope or needs follow-up ticket
   - Open question if there's genuine ambiguity

4. **Ask the dev**, one short prompt. Options:
   - `approve` — apply the proposed approach (code change OR reply,
     whichever the proposal was)
   - `different: <text>` — apply what the dev describes; their `<text>`
     becomes the `dev_note` on the decision
   - `reply: <text>` — record a text-only reply (skip code change even
     if the proposal was code); `<text>` becomes `reply_text`
   - `skip` — defer this thread; gate refuses Phase 2 until either
     decided OR removed from `open_threads`
   - `show alternatives` — propose 2-3 terse alternatives, then re-ask
   - `show related code` — Read more files, print a one-paragraph map,
     then re-ask

   If the dev says anything else, interpret as `different: <their text>`.

   **STOP HERE. End the turn.** Do not proceed to step 5 until the dev
   replies. Do not preview your intended code change. Do not read more
   files "to be ready." The next thing that happens is the dev's reply
   — and nothing else. (Exception: `approve all` / `auto` mode — see
   Rule 1.)

5. **(Next turn, after dev replies) Apply the approved approach**:
   - **Code change**: edit in the worktree. Stay inside the worktree
     path. Follow conventions from the skills you just read.
   - **Reply only**: no code change. Just record the reply text in
     state.decisions[].

6. **Record the decision** (atomic state update — use `pr_state_update`).

   **For `applied`** (code change committed):
   ```bash
   git -C "$WORKTREE" add <files>
   git -C "$WORKTREE" commit -m "review: address T-N (<short>)"
   ```
   ```json
   {
     "thread_id": "T-1",
     "action": "applied",
     "commit_sha": "abc1234",
     "applied_summary": "Converted to UTC via pendulum",
     "dev_note": "<verbatim if dev overrode the proposal, else omit>",
     "decided_at": "<iso>"
   }
   ```
   Bump `state.addressed` by 1 in the same `jq` expression.

   **For `reply`** (text-only, no commit):
   ```json
   {
     "thread_id": "T-1",
     "action": "reply",
     "reply_text": "<the text to paste on ADO>",
     "decided_at": "<iso>"
   }
   ```
   Bump `state.addressed` by 1. No commit, no `commit_sha`.

   **For `deferred`** (skipped):
   ```json
   {
     "thread_id": "T-1",
     "action": "deferred",
     "deferred_reason": "<short>",
     "decided_at": "<iso>"
   }
   ```
   Does NOT bump `addressed`. The gate refuses Phase 2 until every
   `open_threads` entry has a decision (applied / reply / deferred)
   AND `addressed == count(applied) + count(reply)` matches the
   non-deferred subset.

#### Audit trail

The chat history IS the audit trail. State.decisions[] is the
structured log — every applied / reply / deferred thread, with
timestamps and (for applied) commit SHAs. The end-of-ADDRESS summary
renders this human-readable directly in chat.

#### Gate

When every `T-N` in `open_threads` has a corresponding entry in
`decisions[]` (action `applied`, `reply`, or `deferred`), the worktree
is clean, and at least one new commit exists since `head_sha_at_triage`
(unless every decision is `reply` or `deferred` — then no commit is
required):

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
```

The gate refuses to advance if any thread is undecided. Every
`applied` decision must reference a real commit_sha in `triage..HEAD`
(fabricated SHAs are rejected). Every `reply` decision must have
non-empty `reply_text`.

### End of ADDRESS — print the summary, release the lock

When `pr-stage-complete.sh` has advanced state to phase 2, print the
end-of-ADDRESS summary directly in chat. **No `handoff.md` file** —
the chat history is the handoff.

The summary contains:

1. **New commits since triage** — `git log <head_sha_at_triage>..HEAD --oneline`
2. **Per-thread render** — for each entry in `decisions[]`:
   - `applied`: `T-N · file:line · commit_sha · applied_summary`
   - `reply`: `T-N · thread_url` followed by the `reply_text` (so the
     dev can copy-paste directly)
   - `deferred`: `T-N · thread_url · deferred_reason`
3. **Push command**:
   ```
   git -C <worktree> push origin <source_branch>
   ```
4. **ADO checklist**:
   - For each `applied` T-N: click "Resolve" on the thread (status → fixed)
   - For each `reply` T-N: paste the reply text on `<thread_url>`
   - For each `deferred` T-N: decide whether to reply with the reason
     or file a follow-up ticket

Then announce:

```
Phase 2 (ADDRESS) complete for <PR_ID>. fix-pr is done.

→ Run the push command above when ready
→ Reply / resolve threads on ADO using the per-thread render
→ /data-engineer-plugin:fix-pr <PR_ID> --refresh — re-fetch the PR after
  reviewer responds; new threads land as fresh T-N ids, decisions[]
  preserved.
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
Run this in your master claude session:

  /data-engineer-plugin:address-pr --launch <BATCH_ID>

…or, if you don't have a batch, re-triage:

  /data-engineer-plugin:address-pr <PR_ID>

That will fetch origin/<source_branch>, create the worktree, and
re-spawn this session.
```

## What this command does NOT do

- ❌ Push the branch — the end-of-ADDRESS summary tells the developer how
- ❌ Reply to ADO threads via API — `reply` decisions hold paste-ready text for the dev
- ❌ Re-open / complete / abandon the PR
- ❌ Edit anything outside `state.worktree_path` (session-guard rejects)
- ❌ Force-push, ever
- ❌ Spawn subagents that fan out across PRs — same single-PR discipline
  as api-scraper's `/make-scraper` enforces single-ticket
