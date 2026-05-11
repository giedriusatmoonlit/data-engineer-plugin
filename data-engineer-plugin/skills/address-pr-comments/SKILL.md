---
name: address-pr-comments
description: >
  Categorize Azure DevOps PR review comments into must-fix / nit / question /
  resolved, and write the per-PR triage packet (pr_packet.json + comments.md +
  plan.md + state.json). Used by /data-engineer-plugin:address-pr (master
  triage) and /data-engineer-plugin:fix-pr Phase 0 (in-session triage).
  Defines the ADO API call shapes, the categorization rules, the comments.md
  format, and the handoff.md template.
phase: 0-triage
---

# address-pr-comments

The canonical rules for taking an ADO PR and producing a structured
triage packet a `/fix-pr` session can mechanically work through.

> **Hard stop rule for the consumer**: this skill produces artifacts.
> It does not push commits, does not call `az repos pr update`, does
> not reply to threads. `/fix-pr` honors the same boundary.

---

## Step 0: ADO auth + defaults

```bash
az account show --query "user.name" -o tsv     # must succeed
az devops configure --list                     # must show org + project
```

If the org/project defaults aren't set, set them once:

```bash
az devops configure --defaults \
  organization="https://dev.azure.com/$ADO_ORG" \
  project="$ADO_PROJECT"
```

If `az repos pr show --id <N>` returns auth error, the developer must
run `az devops login` (interactive PAT prompt) or set
`AZURE_DEVOPS_EXT_PAT` env var.

---

## Step 1: Fetch the PR + comments

```bash
PR_NUM=2299   # numeric ADO id

az repos pr show --id "$PR_NUM" --output json > /tmp/pr.json
az repos pr list-comments --id "$PR_NUM" --output json > /tmp/comments.json

# Some teams also need file-level threads via the REST API:
ORG=$(az devops configure --list | awk -F'= *' '/^organization/{print $2}' | sed 's|.*/||')
PROJECT=$(az devops configure --list | awk -F'= *' '/^project/{print $2}')
REPO_ID=$(jq -r '.repository.id' /tmp/pr.json)
az rest \
  --method GET \
  --url "https://dev.azure.com/$ORG/$PROJECT/_apis/git/repositories/$REPO_ID/pullRequests/$PR_NUM/threads?api-version=7.0" \
  > /tmp/threads.json
```

Combine into the cached packet:

```bash
jq -s '{pr: .[0], comments: .[1], threads: .[2]}' \
  /tmp/pr.json /tmp/comments.json /tmp/threads.json \
  > "$DATA_ENG_WORK_ROOT/pr_notes/$PR_ID/pr_packet.json"
```

Extract canonical fields once for state.json:

| State field          | jq path on /tmp/pr.json                                   |
|----------------------|-----------------------------------------------------------|
| `pr_url`             | `.url \| sub("_apis/git/repositories"; "_git") \| ...`    |
|                      | (build from org/project/repo/PR_NUM — see below)          |
| `source_branch`      | `.sourceRefName \| sub("refs/heads/"; "")`                |
| `target_branch`      | `.targetRefName \| sub("refs/heads/"; "")`                |
| `head_sha_at_triage` | `.lastMergeSourceCommit.commitId`                         |
| `pr_title`           | `.title`                                                  |
| `ticket_id`          | first match of `DAT-[0-9]+` in `.title + " " + .description` |

Build the human PR URL (not the API URL):
```
https://dev.azure.com/$ORG/$PROJECT/_git/$REPO_NAME/pullrequest/$PR_NUM
```

---

## Step 2: Categorize each comment thread

A "comment" here = one thread (a top-level review comment + its replies).
ADO threads have a `status` field:

| ADO status     | Meaning                          | Our category   |
|----------------|----------------------------------|----------------|
| `active`       | Open, no action yet              | needs categorize |
| `pending`      | Reviewer is drafting             | skip (treat as not yet posted) |
| `fixed`        | Author marked fixed              | RESOLVED       |
| `wontFix`      | Resolved as won't fix            | RESOLVED       |
| `closed`       | Closed without action            | RESOLVED       |
| `byDesign`     | Resolved as by-design            | RESOLVED       |

For `active` threads, apply these rules **in order** (first match wins):

### MF (must-fix)

A thread is MF if **any** of these hold:

- PR vote `waitForAuthor` (-5) or `reject` (-10) from the thread's reviewer
- Thread's first comment text contains any of (case-insensitive):
  `must fix`, `blocker`, `P1`, `[critical]`, `please change`,
  `this won't work`, `incorrect`, `wrong`, `bug:`, `breaking`
- Thread contains explicit "request changes" reaction from a required reviewer
- Thread is on a **file:line that contains a clear correctness issue**
  per the comment body (model judgment, but conservative — when in
  doubt, prefer MF over NIT)

### Q (question)

A thread is Q if **MF didn't fire** AND **any** of these hold:

- First comment ends in `?`
- Starts with `why`, `what`, `how`, `can you explain`, `could you clarify`
- Contains `not sure if`, `is this intentional`, `should this be`

### NIT (nit / style / optional)

A thread is NIT if **MF and Q didn't fire** AND **any** of these hold:

- Comment text starts with `nit:`, `style:`, `optional:`, `minor:`, `polish:`
- Suggests cosmetic-only changes (renames, formatting, whitespace, comments)
- Author explicitly tags as low-priority (`P3`, `feel free to ignore`)

### Default

If none of MF / Q / NIT fired and the thread is `active`, default to **MF**.
Reviewers don't open threads for fun — when in doubt, treat as must-fix
so the gate forces an explicit decision.

---

## Step 3: Write `comments.md`

Format:

```markdown
# PR #2299 review comments  (PR-2299 · DAT-591)

> Triage source: pr_packet.json (fetched 2026-05-11T10:30:00Z)
> Source branch: feat/nolovdat-scraper · Target: master
> Reviewer votes: @alice waitForAuthor, @bob approved

## Must-fix (3)

- [ ] **MF-1** · `Scrapers/NO/NOLOVDAT_basic.py:128` · @alice
  > The watermark check uses naive datetime comparison; will silently
  > skip rows during DST transitions.
  Thread: <thread_url>
  Suggested fix: convert to UTC explicitly before compare; use
  `pendulum.parse(...).in_tz('UTC')`.

- [ ] **MF-2** · `Pipelines/NO/NOLOVDAT.pipeline.py:42` · @alice
  > Missing `dq_expectations` for nullability on `Title`.
  Thread: <thread_url>

- [ ] **MF-3** · `Scrapers/NO/NOLOVDAT_raw.py:67` · @bob
  > Hardcoded UA string — use `Common.scraper_headers()`.
  Thread: <thread_url>

## Nits (2)

- [ ] **NIT-1** · `Scrapers/NO/NOLOVDAT_urls.py:15` · @alice
  > nit: rename `parse_lst` → `parse_listing` for consistency.
  Thread: <thread_url>

- [ ] **NIT-2** · `Migrations/NO/NOLOVDAT.migrate.py:30` · @bob
  > style: docstring missing on `_normalize_dates`.
  Thread: <thread_url>

## Questions (1)

- [ ] **Q-1** · general · @alice
  > Why are you using `recurrent_window_days=14` instead of the
  > default 7? Is there a watermark concern with this source?
  Thread: <thread_url>
  Draft reply: <leave blank — fill during HANDOFF>

## Resolved (already addressed)

- ✓ ~~Thread on `Common/scraper_headers.py:5`~~ (status: fixed)
```

Format rules:

- Top-level sections in order: Must-fix → Nits → Questions → Resolved
- Inside each section, items numbered with persistent IDs (MF-1, MF-2…)
  — once issued, an ID never changes; new comments on `--refresh` get
  fresh IDs continuing the sequence (MF-4, MF-5…)
- Checkbox `- [ ] ID` is the gate-tracked element. `pr-stage-complete.sh`
  greps `^- \[ \] MF-` to count unchecked must-fixes.
- Each item carries: file path + line range, reviewer handle, the
  comment text (quoted), thread URL for the developer to click through.
- On `--refresh`, **don't lose checkbox state**. Existing IDs keep
  their `[x]` or `[ ]`. New comments append at the end of their section
  prefixed with `**NEW:**`.

---

## Step 4: Write `plan.md`

Ordered, terse. The plan picks an order that minimizes rework:

```markdown
# Plan for PR-2299

1. **MF-3** (hardcoded UA) — Scrapers/NO/NOLOVDAT_raw.py:67
   Cheapest first; isolated change. Use `Common.scraper_headers()`.

2. **MF-1** (DST watermark) — Scrapers/NO/NOLOVDAT_basic.py:128
   Convert to UTC. Re-test against the corpus the reviewer flagged.

3. **MF-2** (dq_expectations) — Pipelines/NO/NOLOVDAT.pipeline.py:42
   Add nullability check for Title.

Then nits if time:
4. NIT-1, NIT-2

Q-1 needs a written reply at HANDOFF, not a code change. Draft answer:
"7-day default occasionally misses week-spanning publishes; bumping to
14d eliminates that without re-fetching the full corpus. Watermark
gate still constrains the upper bound."
```

The plan is human-editable. The model writes a first draft; the
developer may reorder before fix-pr starts ADDRESSing.

---

## Step 5: Write `state.json`

```json
{
  "pr_id": "PR-2299",
  "pr_url": "https://dev.azure.com/.../pullrequest/2299",
  "pr_title": "DAT-591 NOLOVDAT scraper",
  "ticket_id": "DAT-591",
  "ado_org": "moonlit-legal-technologies-bv",
  "ado_project": "Moonlit",
  "ado_repo": "Databricks",
  "source_branch": "feat/nolovdat-scraper",
  "target_branch": "master",
  "head_sha_at_triage": "1468371d...",
  "worktree_path": null,
  "phase": 0,
  "phase_name": "fresh",
  "batch_id": "PB-2026-05-11-01",
  "comments_fetched_at": "2026-05-11T10:30:00Z",
  "must_fix_total": 3,
  "must_fix_addressed": 0,
  "nits_total": 2,
  "nits_addressed": 0,
  "questions_total": 1,
  "questions_answered": 0,
  "awaiting_human": false,
  "last_known_vote": "waitForAuthor"
}
```

`worktree_path` stays null until `launch-pr-batch.sh` runs (it owns
worktree creation). `phase` becomes 1 after `pr-stage-complete.sh`
gates this triage as complete.

---

## Step 6: Refresh-on-re-run

When `/address-pr --refresh` or `/fix-pr --refresh` runs:

1. Re-fetch `az repos pr show` + threads
2. Diff against existing `pr_packet.json`:
   - Threads with new replies → check status; if reviewer added MUST-FIX
     reply on an existing thread, add a `**NEW reply on MF-N:**` line
     under that item (don't issue a new MF-N — same thread)
   - Threads created since triage → issue new IDs continuing sequence,
     prefix `**NEW:**`, default `[ ]`
   - Threads now status=fixed/closed → move to Resolved section,
     mark `✓ ~~...~~`
3. If PR's `head_sha` changed since triage:
   - Add to top of comments.md:
     ```
     ⚠ Head SHA changed: <old>...<new> — reviewer or you pushed since triage.
     Run: git -C <worktree> log <old>..<new> --oneline   to see what.
     ```
   - Don't auto-reset the worktree.

---

## Bash-snippet bundle

```bash
fetch_pr_packet() {
  local pr_num="$1" pr_id="PR-$1"
  local dir="$DATA_ENG_WORK_ROOT/pr_notes/$pr_id"
  mkdir -p "$dir"

  az repos pr show --id "$pr_num" --output json > "$dir/.pr.json"
  az repos pr list-comments --id "$pr_num" --output json > "$dir/.comments.json"

  local repo_id org project
  repo_id=$(jq -r '.repository.id' "$dir/.pr.json")
  org=$(az devops configure --list | awk -F'= *' '/^organization/{print $2}' | sed 's|.*/||;s|/$||')
  project=$(az devops configure --list | awk -F'= *' '/^project/{print $2}')
  az rest --method GET \
    --url "https://dev.azure.com/$org/$project/_apis/git/repositories/$repo_id/pullRequests/$pr_num/threads?api-version=7.0" \
    > "$dir/.threads.json"

  jq -s '{pr: .[0], comments: .[1], threads: .[2]}' \
    "$dir/.pr.json" "$dir/.comments.json" "$dir/.threads.json" \
    > "$dir/pr_packet.json"
  rm "$dir/.pr.json" "$dir/.comments.json" "$dir/.threads.json"
}
```

---

## Anti-patterns (will be caught downstream)

- Categorizing every active thread as NIT to make the gate trivially
  pass. `pr-stage-complete.sh` doesn't gate on NIT count, but the
  developer will rerun triage with `--refresh` and the gap will surface.
- Skipping a thread because it "looks like noise". Issue an ID; mark
  `[x]` immediately with a one-line note in the same item if you
  decide it's truly nothing. Audit trail > silent drop.
- Auto-replying to threads. This skill produces draft text; humans send it.
- Recreating an issued ID. IDs are append-only — never reorder, never
  renumber.
