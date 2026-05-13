#!/usr/bin/env bash
# data-engineer-plugin · per-issue status / briefing
#
# Called by:
#   - SessionStart hook (via session-start-briefing.sh dispatch) when cwd
#     looks like a *-dat-NNN worktree
#   - /start-issue's bash side, at the end of setup
#   - Manually:   bash issue-status.sh DAT-612
#
# Prints a tight briefing: ticket id, branch, worktree path, last commit,
# whether the issue lock is held by this session, summary from
# issue-state.json if present.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_env.sh
. "$SCRIPT_DIR/_env.sh"

DAT_ID="${1:-}"

# If no arg, infer from cwd.
if [ -z "$DAT_ID" ]; then
  if [[ "$PWD" =~ -dat-([0-9]+)(/|$) ]]; then
    DAT_ID="DAT-${BASH_REMATCH[1]}"
  fi
fi

if [ -z "$DAT_ID" ]; then
  echo "(issue-status: no DAT id given and cwd is not a *-dat-NNN worktree — no-op)"
  exit 0
fi

DAT_ID=$(canonicalize_dat "$DAT_ID") || { red "Invalid DAT id: $1"; exit 2; }
WT=$(worktree_path_for_dat "$DAT_ID")
STATE=$(dat_state_file "$DAT_ID")

if [ ! -d "$WT" ]; then
  yellow "Worktree not on disk: $WT"
  yellow "Run /data-engineer-plugin:start-issue $DAT_ID to create it."
  exit 0
fi

BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
LAST=$(git -C "$WT" log -1 --pretty='%h %s (%cr)' 2>/dev/null || echo "?")

cyan "── $DAT_ID briefing ──────────────────────────────────────────────"
echo "  worktree:   $WT"
echo "  branch:     $BRANCH"
echo "  last commit:$LAST"

if [ -f "$STATE" ]; then
  TITLE=$(jq -r '.title // empty' "$STATE")
  URL=$(jq -r '.ticket_url // empty' "$STATE")
  SUMMARY=$(jq -r '.summary // empty' "$STATE")
  PHASE=$(jq -r '.phase // empty' "$STATE")
  [ -n "$TITLE" ]   && echo "  title:      $TITLE"
  [ -n "$URL" ]     && echo "  linear:     $URL"
  [ -n "$PHASE" ]   && echo "  phase:      $PHASE"
  if [ -n "$SUMMARY" ]; then
    echo "  summary:"
    sed 's/^/    /' <<<"$SUMMARY"
  fi
else
  yellow "  (no issue-state.json — was /start-issue ever run for this worktree?)"
fi

# Lock awareness — only print if a lock for this session is present.
LF="$DATA_ENG_WORK_ROOT/.session-issue-lock-$(session_id).json"
if [ -f "$LF" ]; then
  HELD=$(jq -r '.dat_id // empty' "$LF" 2>/dev/null || echo)
  if [ "$HELD" = "$DAT_ID" ]; then
    green "  lock:       held by this session ✓"
  elif [ -n "$HELD" ]; then
    red "  lock:       held by $HELD (NOT this ticket) — cross-ticket writes will be refused"
  fi
fi

cyan "────────────────────────────────────────────────────────────────"
