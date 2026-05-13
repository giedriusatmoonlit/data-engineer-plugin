#!/usr/bin/env bash
# data-engineer-plugin · session lock for /start-issue
#
# DAT-ticket-keyed sibling of lock.sh (which is PR-keyed). One Claude
# session works on one DAT ticket at a time — once acquired, the
# issue-guard PreToolUse hook refuses Write/Edit/Bash against any other
# DAT worktree.
#
# Subcommands:
#   acquire <DAT_ID>     Claim the session for one ticket.
#   release [DAT_ID]     Release the lock. If DAT_ID given, only
#                        releases if it matches the held ticket.
#   sweep                Remove any lock whose owner PID is dead and
#                        whose age is > 2h.
#   status               Print the current lock (or 'unlocked').
#   read-dat             Print just the locked DAT id, or nothing.
#
# Lock file:
#   $DATA_ENG_WORK_ROOT/.session-issue-lock-<SESSION_ID>.json
#
# Exits 0 on success, 1 on refusal, 2 on misuse / missing env.

set -euo pipefail

: "${DATA_ENG_WORK_ROOT:?DATA_ENG_WORK_ROOT not set}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_env.sh
. "$SCRIPT_DIR/_env.sh"

SESSION_ID=$(session_id)
LOCK_FILE="$DATA_ENG_WORK_ROOT/.session-issue-lock-${SESSION_ID}.json"
STALE_AFTER_SECS=$((2 * 60 * 60))

is_stale() {
  [ -f "$LOCK_FILE" ] || return 1
  local pid started_epoch now
  pid=$(jq -r '.pid // empty' "$LOCK_FILE" 2>/dev/null || echo)
  started_epoch=$(jq -r '.started_epoch // 0' "$LOCK_FILE" 2>/dev/null || echo 0)
  now=$(now_epoch)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  if [ $((now - started_epoch)) -lt $STALE_AFTER_SECS ]; then
    return 1
  fi
  return 0
}

read_held_dat() {
  [ -f "$LOCK_FILE" ] || { echo ""; return; }
  jq -r '.dat_id // empty' "$LOCK_FILE" 2>/dev/null || echo ""
}

cmd="${1:-}"

case "$cmd" in
  acquire)
    DAT_ID="${2:?usage: issue-lock.sh acquire <DAT_ID>}"
    DAT_ID=$(canonicalize_dat "$DAT_ID") || die "Invalid DAT id: $2"
    if [ -f "$LOCK_FILE" ]; then
      HELD=$(read_held_dat)
      if [ "$HELD" = "$DAT_ID" ]; then
        :   # resuming
      elif is_stale; then
        rm -f "$LOCK_FILE"
      else
        red "Refused: session already locked to $HELD (alive)."
        red "Holder: $(cat "$LOCK_FILE")"
        red "Finish that ticket, or:"
        red "  bash $0 release $HELD     # if you know it's safe"
        red "  bash $0 sweep             # auto-clean if owner is dead"
        exit 1
      fi
    fi
    jq -n \
      --arg session_id "${CLAUDE_SESSION_ID:-no-session-id}" \
      --argjson pid "$$" \
      --arg dat_id "$DAT_ID" \
      --arg started_at "$(now_iso)" \
      --argjson started_epoch "$(now_epoch)" \
      --arg worktree "$(worktree_path_for_dat "$DAT_ID")" \
      '{session_id:$session_id, pid:$pid, dat_id:$dat_id,
        started_at:$started_at, started_epoch:$started_epoch,
        worktree:$worktree}' \
      > "$LOCK_FILE"
    green "Issue lock acquired: $DAT_ID (pid $$)"
    ;;

  release)
    if [ ! -f "$LOCK_FILE" ]; then
      echo "(no issue lock held)"; exit 0
    fi
    DAT_ID="${2:-}"
    FORCE=0
    [ "$DAT_ID" = "--force" ] && { FORCE=1; DAT_ID=""; }
    [ "${3:-}" = "--force" ] && FORCE=1
    HELD=$(read_held_dat)

    if [ -z "$DAT_ID" ] && [ "$FORCE" -eq 0 ]; then
      cat >&2 <<EOF
Refused: 'issue-lock.sh release' without a DAT arg.

This session holds an issue lock on: $HELD

If you got here because issue-guard refused a Bash/Write/Edit on a
different DAT worktree, the FIX is NOT to release the lock — it's to
stop trying to do that other ticket's work in this session. One
session, one DAT.

If you genuinely need to release (e.g. you finished $HELD):
  bash $0 release $HELD

If $HELD is wedged and you need to force-release:
  bash $0 release --force
EOF
      exit 1
    fi

    if [ -n "$DAT_ID" ]; then
      DAT_ID=$(canonicalize_dat "$DAT_ID") || true
    fi

    if [ -n "$DAT_ID" ] && [ "$DAT_ID" != "$HELD" ]; then
      red "Refused: lock holds $HELD, not $DAT_ID. Pass --force to override."
      exit 1
    fi
    rm -f "$LOCK_FILE"
    green "Issue lock released: $HELD"
    ;;

  sweep)
    local_count=0
    swept=0
    for f in "$DATA_ENG_WORK_ROOT"/.session-issue-lock-*.json; do
      [ -f "$f" ] || continue
      local_count=$((local_count + 1))
      LOCK_FILE_ORIG="$LOCK_FILE"
      LOCK_FILE="$f"
      if is_stale; then
        HELD=$(read_held_dat)
        rm -f "$f"
        echo "Swept stale issue lock: $(basename "$f") (was holding $HELD)"
        swept=$((swept + 1))
      fi
      LOCK_FILE="$LOCK_FILE_ORIG"
    done
    if [ "$local_count" -eq 0 ]; then
      echo "(no issue locks present)"
    elif [ "$swept" -eq 0 ]; then
      echo "$local_count issue lock(s) present, all live"
    fi
    ;;

  status)
    if [ -f "$LOCK_FILE" ]; then
      cat "$LOCK_FILE"
    else
      echo "unlocked"
    fi
    ;;

  read-dat)
    read_held_dat
    ;;

  *)
    echo "usage: $0 {acquire <DAT_ID> | release [DAT_ID] | sweep | status | read-dat}" >&2
    exit 2
    ;;
esac
