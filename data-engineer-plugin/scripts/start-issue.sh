#!/usr/bin/env bash
# data-engineer-plugin · /start-issue executor
#
# Given a DAT-NNN that already exists in Linear, set up the local
# environment to work on it:
#
#   1. Resolve target branch (existing remote/local, or create new)
#   2. Create the per-ticket worktree at <parent>/<repo>-dat-NNN if missing
#   3. Write .notes/issue-state.json + .cursor/rules/issue.md
#   4. Acquire the issue lock (issue-lock.sh acquire)
#   5. Launch Cursor on the worktree (unless --no-cursor)
#
# This script ASSUMES the Linear ticket already exists. Filing the
# ticket is the caller's job (the slash command tells the model to
# invoke the linear-ticket-creator skill first when needed). That
# split keeps the bash side dumb and the human-confirmation in chat.
#
# Usage:
#   bash start-issue.sh DAT-612 \
#        [--title "FRLEGIFRANCE pdf_url wrong format"] \
#        [--branch bugfix/dat-612-pdf-url] \
#        [--summary "Short body for the briefing"] \
#        [--no-cursor]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_env.sh
. "$SCRIPT_DIR/_env.sh"

require_env DATA_ENG_WORK_ROOT
require_cmd git jq

REPO=$(repo_root)
[ -n "$REPO" ] && [ -d "$REPO" ] || die "Repo root not set (DATA_ENG_REPO_ROOT or SCRAPER_REPO_ROOT)."

DAT_RAW="${1:-}"
[ -n "$DAT_RAW" ] || die "usage: start-issue.sh <DAT-NNN> [--title X] [--branch X] [--summary X] [--no-cursor]"
DAT_ID=$(canonicalize_dat "$DAT_RAW") || die "Invalid DAT id: $DAT_RAW"
shift

TITLE=""
BRANCH=""
SUMMARY=""
TICKET_URL=""
LAUNCH_CURSOR=1

while [ $# -gt 0 ]; do
  case "$1" in
    --title)    TITLE="${2:-}";    shift 2 ;;
    --branch)   BRANCH="${2:-}";   shift 2 ;;
    --summary)  SUMMARY="${2:-}";  shift 2 ;;
    --url)      TICKET_URL="${2:-}"; shift 2 ;;
    --no-cursor) LAUNCH_CURSOR=0; shift ;;
    *) die "Unknown flag: $1" ;;
  esac
done

WT=$(worktree_path_for_dat "$DAT_ID")
DAT_LOWER=$(dat_numeric_lower "$DAT_ID")

# ── Step 1: resolve branch ────────────────────────────────────────────────────
# Preference: explicit --branch → existing local matching dat-NNN → existing
# remote matching dat-NNN → new branch from master.

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40
}

if [ -z "$BRANCH" ]; then
  CANDIDATE=$(git -C "$REPO" for-each-ref --format='%(refname:short)' \
    'refs/heads/*' 'refs/remotes/origin/*' 2>/dev/null \
    | grep -iE "(^|/)([^/]*-)?dat-?$DAT_LOWER([^0-9]|$)" \
    | sed 's|^origin/||' \
    | head -1 || true)
  if [ -n "$CANDIDATE" ]; then
    BRANCH="$CANDIDATE"
    cyan "Reusing existing branch matching dat-$DAT_LOWER: $BRANCH"
  else
    SLUG=$(slugify "${TITLE:-issue}")
    [ -z "$SLUG" ] && SLUG="issue"
    BRANCH="bugfix/dat-$DAT_LOWER-$SLUG"
    cyan "Creating fresh branch: $BRANCH"
  fi
fi

# Materialize the branch if it doesn't exist locally yet.
if ! git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  # Try to track origin/<branch> if it exists, else fork from master.
  if git -C "$REPO" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git -C "$REPO" branch --track "$BRANCH" "origin/$BRANCH" >/dev/null
    cyan "Tracking origin/$BRANCH locally."
  else
    git -C "$REPO" fetch origin master --quiet || true
    BASE="origin/master"
    git -C "$REPO" show-ref --verify --quiet "refs/remotes/$BASE" || BASE="master"
    git -C "$REPO" branch "$BRANCH" "$BASE" >/dev/null
    cyan "Branched $BRANCH from $BASE."
  fi
fi

# ── Step 2: worktree create or reuse ──────────────────────────────────────────
if [ -d "$WT" ]; then
  EXISTING_BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  if [ "$EXISTING_BRANCH" = "$BRANCH" ]; then
    green "Worktree already at $WT on $BRANCH — reusing."
  else
    warn "Worktree at $WT is on $EXISTING_BRANCH, not $BRANCH."
    warn "Leaving it as-is. If you intend to retarget, run:"
    warn "  git -C $REPO worktree remove $WT && git -C $REPO worktree add $WT $BRANCH"
  fi
else
  # If branch is checked out elsewhere (incl. main), git worktree refuses.
  # Surface that explicitly so the user knows what to do.
  if git -C "$REPO" worktree list --porcelain | grep -qE "^branch refs/heads/$BRANCH\$"; then
    OTHER=$(git -C "$REPO" worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '
      $1=="worktree"{wt=$2} $1=="branch" && $2==b {print wt; exit}')
    die "Branch $BRANCH is already checked out at $OTHER. Free it first (or pass a different --branch)."
  fi
  git -C "$REPO" worktree add "$WT" "$BRANCH" >/dev/null
  green "Worktree created: $WT on $BRANCH"
fi

# ── Step 3: .notes/issue-state.json + .cursor/rules/issue.md ──────────────────
init_issue_notes "$DAT_ID"

STATE_FILE=$(dat_state_file "$DAT_ID")
CURSOR_RULE=$(dat_cursor_rule "$DAT_ID")

if [ -f "$STATE_FILE" ]; then
  # Update non-empty fields without clobbering existing ones.
  TMP=$(mktemp)
  jq \
    --arg branch "$BRANCH" \
    --arg worktree "$WT" \
    --arg title "$TITLE" \
    --arg url "$TICKET_URL" \
    --arg summary "$SUMMARY" \
    --arg now "$(now_iso)" \
    '. as $orig
     | .branch     = $branch
     | .worktree   = $worktree
     | .title      = (if $title   == "" then ($orig.title // "")      else $title   end)
     | .ticket_url = (if $url     == "" then ($orig.ticket_url // "") else $url     end)
     | .summary    = (if $summary == "" then ($orig.summary // "")    else $summary end)
     | .updated_at = $now' \
    "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
  cyan "Updated $STATE_FILE"
else
  jq -n \
    --arg ticket_id "$DAT_ID" \
    --arg ticket_url "$TICKET_URL" \
    --arg title "$TITLE" \
    --arg summary "$SUMMARY" \
    --arg branch "$BRANCH" \
    --arg worktree "$WT" \
    --arg created "$(now_iso)" \
    '{ticket_id:$ticket_id, ticket_url:$ticket_url, title:$title, summary:$summary,
      branch:$branch, worktree:$worktree, phase:"started",
      created_at:$created, updated_at:$created}' \
    > "$STATE_FILE"
  green "Wrote $STATE_FILE"
fi

# Cursor scope file — gives Cursor's chat ticket-anchored context when the
# worktree is opened as a folder. Idempotent: only write if missing, so an
# edited rule survives re-runs.
if [ ! -f "$CURSOR_RULE" ]; then
  mkdir -p "$(dirname "$CURSOR_RULE")"
  cat > "$CURSOR_RULE" <<EOF
---
description: Scope context for $DAT_ID
alwaysApply: true
---

# $DAT_ID — scoped chat context

You are working in the **$DAT_ID** worktree.

- **Branch**: \`$BRANCH\`
- **Worktree path**: \`$WT\`
${TICKET_URL:+- **Linear**: $TICKET_URL}
${TITLE:+- **Title**: $TITLE}

${SUMMARY:+## Problem summary

$SUMMARY
}
## Hard rules

1. Only edit files inside this worktree (\`$WT\`).
2. Do not touch other \`*-dat-*\` worktrees in this session — the
   data-engineer-plugin's PreToolUse hook will refuse cross-ticket writes
   while the lock is held.
3. Keep commits focused on $DAT_ID. If you discover a separate bug,
   file a new Linear ticket rather than bundling.
4. The \`.notes/\` directory is git-excluded scratch space — safe to
   write briefings, scratch SQL, partial drafts. Do not put real code
   there.
EOF
  cyan "Wrote $CURSOR_RULE"
fi

# ── Step 4: acquire the issue lock ────────────────────────────────────────────
bash "$SCRIPT_DIR/issue-lock.sh" acquire "$DAT_ID"

# ── Step 5: launch Cursor ─────────────────────────────────────────────────────
if [ "$LAUNCH_CURSOR" = "1" ]; then
  if command -v cursor >/dev/null 2>&1; then
    # New window targeting the worktree. setsid+disown so this script
    # doesn't sit waiting on Cursor's lifecycle.
    setsid -f cursor "$WT" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    green "Launched Cursor on $WT"
  else
    warn "'cursor' not on PATH — open this folder manually:"
    warn "  File → Open Folder → $WT"
  fi
fi

# ── Step 6: briefing ──────────────────────────────────────────────────────────
echo
bash "$SCRIPT_DIR/issue-status.sh" "$DAT_ID"
