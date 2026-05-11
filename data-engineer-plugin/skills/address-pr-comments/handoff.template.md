# Handoff for {{PR_ID}} — {{PR_TITLE}}

> Phase 3 reached. fix-pr's work is done. Below is everything you need
> to push + close out the review round. fix-pr never pushes and never
> replies to ADO threads on your behalf — that's deliberate.

PR URL:        {{PR_URL}}
Source branch: {{SOURCE_BRANCH}} → {{TARGET_BRANCH}}
Worktree:      {{WORKTREE_PATH}}
Ticket:        {{TICKET_ID}}

---

## 1. New commits since triage

Triage SHA:  `{{HEAD_SHA_AT_TRIAGE}}`
HEAD now:    `{{CURRENT_SHA}}`

```
{{COMMITS_LIST}}
```

(Each line: `<short_sha> <subject>`)

---

## 2. Must-fix → commit mapping

| MF  | File:line                              | Commit         | Notes |
|-----|----------------------------------------|----------------|-------|
{{MF_TABLE}}

All `{{MF_TOTAL}}` must-fix items addressed.

---

## 3. Nits this round

Addressed:
{{NITS_ADDRESSED_LIST}}

Deferred (reason noted):
{{NITS_DEFERRED_LIST}}

---

## 4. Question replies (paste these on ADO)

{{QUESTION_DRAFTS}}

Each entry is a `Q-N · thread_url` + a paste-ready draft reply. Edit
freely before pasting — these are starting points, not final text.

---

## 5. Push + reply checklist

```bash
# 1. Confirm worktree clean + on the right branch
git -C {{WORKTREE_PATH}} status
git -C {{WORKTREE_PATH}} branch --show-current   # should print: {{SOURCE_BRANCH}}

# 2. Sanity-check what you're about to push
git -C {{WORKTREE_PATH}} log {{HEAD_SHA_AT_TRIAGE}}..HEAD --oneline
git -C {{WORKTREE_PATH}} diff {{HEAD_SHA_AT_TRIAGE}}..HEAD --stat

# 3. Push (NEVER --force without a deliberate reason)
git -C {{WORKTREE_PATH}} push origin {{SOURCE_BRANCH}}
```

Then on ADO ({{PR_URL}}):

- [ ] For each MF-N: open the thread, click "Resolve" (status → fixed)
- [ ] For each Q-N: paste the draft reply from §4 (edit as needed)
- [ ] Optionally request re-review from {{REVIEWER_HANDLES}}

---

## 6. If reviewer comes back with more

```
/data-engineer-plugin:fix-pr {{PR_ID}} --refresh
```

This re-fetches the PR, appends new comments to `comments.md` with
fresh IDs, and bumps you back to Phase 1 (ADDRESS) if any new MFs
landed. Existing checkbox state is preserved.
