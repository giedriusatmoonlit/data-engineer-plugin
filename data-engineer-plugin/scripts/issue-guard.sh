#!/usr/bin/env bash
# data-engineer-plugin · PreToolUse hook for /start-issue
#
# DAT-keyed sibling of session-guard.sh. Refuses any Write/Edit/Bash
# that targets a path under a different DAT worktree than the one
# currently locked.
#
# Allow rules:
#   - No issue lock present → allow (we're outside /start-issue)
#   - Path/command doesn't reference any DAT worktree → allow
#   - Path/command references the locked DAT's worktree → allow
#   - Path/command references a DIFFERENT DAT worktree → refuse (exit 2)
#
# This runs alongside session-guard.sh (PR-keyed). Both fire on the same
# matcher; the first one to refuse wins. Whichever lock is held does the
# guarding — the other is a no-op.

set -euo pipefail

if [ -z "${DATA_ENG_WORK_ROOT:-}" ]; then
  exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

_session_id() {
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    echo "$CLAUDE_SESSION_ID"
  elif [ -n "${DE_FAKE_SESSION_ID:-}" ]; then
    echo "$DE_FAKE_SESSION_ID"
  elif [ -n "${MPROCS_NAME:-}" ]; then
    echo "mprocs-$(printf '%s' "$MPROCS_NAME" | tr -c 'A-Za-z0-9' '_')"
  elif [ -n "${PPID:-}" ] && [ "$PPID" != "1" ]; then
    echo "ppid-$PPID"
  else
    echo "default"
  fi
}
LOCK_FILE="$DATA_ENG_WORK_ROOT/.session-issue-lock-$(_session_id).json"

if [ ! -f "$LOCK_FILE" ]; then
  exit 0
fi

# Stale-lock reaping (matches issue-lock.sh; 30 min for hook context).
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

HELD_DAT=$(jq -r '.dat_id // empty' "$LOCK_FILE" 2>/dev/null || echo)
if [ -z "$HELD_DAT" ]; then
  exit 0
fi
HELD_NUM="${HELD_DAT#DAT-}"

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
    # Catch worktree paths of the form <repo>-dat-NNN[/...].
    for parent in "${DATA_ENG_WORKTREE_PARENT:-}" "${SCRAPER_WORKTREE_PARENT:-}"; do
      [ -z "$parent" ] && continue
      while IFS= read -r line; do
        [ -n "$line" ] && PATHS+=("$line")
      done < <(grep -oE "$parent/[A-Za-z0-9._-]+-dat-[0-9]+[A-Za-z0-9./_-]*" <<<"$CMD" || true)
    done
    ;;
  *)
    exit 0
    ;;
esac

[ "${#PATHS[@]}" -eq 0 ] && exit 0

extract_dat_num() {
  local p="$1"
  if [[ "$p" =~ -dat-([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"; return
  fi
  echo ""
}

for P in "${PATHS[@]}"; do
  N=$(extract_dat_num "$P")
  if [ -n "$N" ] && [ "$N" != "$HELD_NUM" ]; then
    cat >&2 <<EOF
Refused by data-engineer-plugin issue-guard.

This session is locked to issue: $HELD_DAT
But you tried to $TOOL a path belonging to: DAT-$N
  ($P)

/start-issue is single-DAT per session. Don't fan out across tickets.
Finish $HELD_DAT first, or:
  bash \$CLAUDE_PLUGIN_ROOT/scripts/issue-lock.sh release $HELD_DAT
  /data-engineer-plugin:start-issue DAT-$N

If you genuinely intended this and are sure no race exists, you can
release the lock manually as shown above, then retry.
EOF
    exit 2
  fi
done

exit 0
