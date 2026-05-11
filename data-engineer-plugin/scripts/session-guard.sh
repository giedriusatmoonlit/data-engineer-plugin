#!/usr/bin/env bash
# data-engineer-plugin · PreToolUse hook
#
# Wired in hooks/hooks.json. Reads the tool call from stdin (JSON) and
# refuses if it would touch a PR different from the one currently locked
# by /address-pr / /fix-pr.
#
# Allow rules:
#   - No lock file present → allow everything (we're outside /fix-pr)
#   - Path/command doesn't reference any PR dir → allow
#   - Path/command references the locked PR → allow
#   - Path/command references a DIFFERENT PR → refuse with exit 2
#
# Refuses on Write, Edit, NotebookEdit. Also inspects Bash commands for
# obvious cross-PR writes (rm/mv/cp/tee/redirect into pr_notes/PR-* or
# {repo}-pr-* worktrees).
#
# Exits:
#   0   allow
#   2   block (stderr goes back to the model as a tool error)

set -euo pipefail

: "${DATA_ENG_WORK_ROOT:?DATA_ENG_WORK_ROOT not set}"

_session_id() {
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    echo "$CLAUDE_SESSION_ID"
  elif [ -n "${DE_FAKE_SESSION_ID:-}" ]; then
    echo "$DE_FAKE_SESSION_ID"
  elif [ -n "${TMUX_PANE:-}" ]; then
    echo "tmux$(echo "$TMUX_PANE" | tr -c 'A-Za-z0-9' '_')"
  elif [ -n "${PPID:-}" ] && [ "$PPID" != "1" ]; then
    echo "ppid-$PPID"
  else
    echo "default"
  fi
}
LOCK_FILE="$DATA_ENG_WORK_ROOT/.session-lock-$(_session_id).json"

if [ ! -f "$LOCK_FILE" ]; then
  exit 0
fi

# Stale-lock reaping (matches lock.sh; 30 min for hook context).
HOLDER_PID=$(jq -r '.pid // 0' "$LOCK_FILE" 2>/dev/null)
HOLDER_EPOCH=$(jq -r '.started_epoch // 0' "$LOCK_FILE" 2>/dev/null)
NOW_EPOCH=$(date -u +%s)
STALE_AFTER=$((30 * 60))
if [ -n "$HOLDER_PID" ] && [ "$HOLDER_PID" != "0" ] && ! kill -0 "$HOLDER_PID" 2>/dev/null; then
  if [ -n "$HOLDER_EPOCH" ] && [ $((NOW_EPOCH - HOLDER_EPOCH)) -gt $STALE_AFTER ]; then
    rm -f "$LOCK_FILE" 2>/dev/null
    exit 0
  fi
fi

HELD_PR=$(jq -r '.pr_id // empty' "$LOCK_FILE" 2>/dev/null || echo)
if [ -z "$HELD_PR" ]; then
  exit 0
fi
HELD_NUM="${HELD_PR#PR-}"

PAYLOAD=$(cat)
TOOL=$(jq -r '.tool_name // empty' <<<"$PAYLOAD")

PATHS=()
case "$TOOL" in
  Write|Edit|NotebookEdit)
    P=$(jq -r '.tool_input.file_path // empty' <<<"$PAYLOAD")
    [ -n "$P" ] && PATHS+=("$P")
    ;;
  Bash)
    CMD=$(jq -r '.tool_input.command // empty' <<<"$PAYLOAD")
    # Catch pr_notes/PR-NNNN/... references.
    while IFS= read -r line; do
      [ -n "$line" ] && PATHS+=("$line")
    done < <(grep -oE "($DATA_ENG_WORK_ROOT|\$DATA_ENG_WORK_ROOT|~/[A-Za-z0-9._/-]*)/pr_notes/PR-[0-9]+[A-Za-z0-9./_-]*" <<<"$CMD" || true)
    # Catch worktree paths of the form <repo>-pr-NNNN[/...]
    # Use either DATA_ENG_WORKTREE_PARENT or SCRAPER_WORKTREE_PARENT as the
    # anchor — both may be in play if the user has api-scraper installed.
    for parent in "${DATA_ENG_WORKTREE_PARENT:-}" "${SCRAPER_WORKTREE_PARENT:-}"; do
      [ -z "$parent" ] && continue
      while IFS= read -r line; do
        [ -n "$line" ] && PATHS+=("$line")
      done < <(grep -oE "$parent/[A-Za-z0-9._-]+-pr-[0-9]+[A-Za-z0-9./_-]*" <<<"$CMD" || true)
    done
    ;;
  *)
    exit 0
    ;;
esac

[ "${#PATHS[@]}" -eq 0 ] && exit 0

# Extract the PR id from a path, if any. Two patterns:
#   .../pr_notes/PR-NNNN[/...]
#   .../<repo>-pr-NNNN[/...]
extract_pr_num() {
  local p="$1"
  if [[ "$p" =~ /pr_notes/PR-([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"; return
  fi
  if [[ "$p" =~ -pr-([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"; return
  fi
  echo ""
}

for P in "${PATHS[@]}"; do
  N=$(extract_pr_num "$P")
  if [ -n "$N" ] && [ "$N" != "$HELD_NUM" ]; then
    cat >&2 <<EOF
Refused by data-engineer-plugin session-guard.

This session is locked to PR: $HELD_PR
But you tried to $TOOL a path belonging to PR: PR-$N
  ($P)

/fix-pr is single-PR per session. Don't fan out across PRs.
Finish $HELD_PR first, or:
  bash \$CLAUDE_PLUGIN_ROOT/scripts/lock.sh release $HELD_PR
  /data-engineer-plugin:fix-pr PR-$N

If you genuinely intended this and are sure no race exists, you can
release the lock manually as shown above, then retry.
EOF
    exit 2
  fi
done

exit 0
