#!/usr/bin/env bash
# data-engineer-plugin · session lock for /address-pr / /fix-pr
#
# One Claude Code session advances one PR at a time. This script is the
# gatekeeper — same shape as api-scraper's lock.sh, but the subject is a
# PR id (PR-NNNN) instead of a DAT ticket id.
#
# Subcommands:
#   acquire <PR_ID> [PHASE]    Claim the session for one PR. Refuses if
#                              another PR holds the lock (and the holder
#                              is alive + not stale).
#   release [PR_ID]            Release the lock. If PR_ID given, only
#                              releases if it matches the held PR.
#   sweep                      Remove the lock if its owner PID is dead
#                              or the lock is older than 2h.
#   status                     Print the current lock (or 'unlocked').
#   read-pr                    Print just the locked PR id, or nothing.
#
# Lock file:
#   $DATA_ENG_WORK_ROOT/.session-lock-<SESSION_ID>.json
#
# Exits 0 on success, 1 on refusal, 2 on misuse / missing env.

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
SESSION_ID=$(_session_id)
LOCK_FILE="$DATA_ENG_WORK_ROOT/.session-lock-${SESSION_ID}.json"
STALE_AFTER_SECS=$((2 * 60 * 60))   # 2 hours

now_iso()    { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch()  { date -u +%s; }

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

read_held_pr() {
  [ -f "$LOCK_FILE" ] || { echo ""; return; }
  jq -r '.pr_id // empty' "$LOCK_FILE" 2>/dev/null || echo ""
}

cmd="${1:-}"

case "$cmd" in
  acquire)
    PR_ID="${2:?usage: lock.sh acquire <PR_ID> [PHASE]}"
    # Accept numeric / #1234 / PR-1234 and canonicalize.
    PR_ID_RAW="$PR_ID"
    PR_ID="${PR_ID#\#}"; PR_ID="${PR_ID#PR-}"; PR_ID="${PR_ID#pr-}"
    [[ "$PR_ID" =~ ^[0-9]+$ ]] || { echo "Invalid PR id: $PR_ID_RAW" >&2; exit 2; }
    PR_ID="PR-$PR_ID"
    PHASE="${3:-0}"
    [[ "$PHASE" =~ ^[0-9]+$ ]] || PHASE=0
    if [ -f "$LOCK_FILE" ]; then
      HELD=$(read_held_pr)
      if [ "$HELD" = "$PR_ID" ]; then
        :   # resuming same PR
      elif is_stale; then
        rm -f "$LOCK_FILE"
      else
        echo "Refused: session already locked to $HELD (alive)." >&2
        echo "Holder: $(cat "$LOCK_FILE")" >&2
        echo "Finish that PR, or:" >&2
        echo "  bash $0 release $HELD     # if you know it's safe" >&2
        echo "  bash $0 sweep             # auto-clean if owner is dead" >&2
        exit 1
      fi
    fi
    jq -n \
      --arg session_id "${CLAUDE_SESSION_ID:-no-session-id}" \
      --argjson pid "$$" \
      --arg pr_id "$PR_ID" \
      --argjson phase "$PHASE" \
      --arg started_at "$(now_iso)" \
      --argjson started_epoch "$(now_epoch)" \
      '{session_id:$session_id, pid:$pid, pr_id:$pr_id, phase:$phase,
        started_at:$started_at, started_epoch:$started_epoch}' \
      > "$LOCK_FILE"
    echo "Lock acquired: $PR_ID (phase $PHASE, pid $$)"
    ;;

  release)
    if [ ! -f "$LOCK_FILE" ]; then
      echo "(no lock held)"; exit 0
    fi
    PR_ID="${2:-}"
    FORCE=0
    [ "$PR_ID" = "--force" ] && { FORCE=1; PR_ID=""; }
    [ "${3:-}" = "--force" ] && FORCE=1
    HELD=$(read_held_pr)

    if [ -z "$PR_ID" ] && [ "$FORCE" -eq 0 ]; then
      cat >&2 <<EOF
Refused: 'lock.sh release' without a PR arg.

This session holds a lock on: $HELD

If you got here because session-guard refused a Bash/Write/Edit on a
different PR, the FIX is NOT to release the lock — it's to stop trying
to do that other PR's work in this session. /fix-pr is single-PR by
design.

If you genuinely need to release (e.g. you finished $HELD and are
exiting cleanly):
  bash $0 release $HELD

If $HELD is wedged and you need to force-release:
  bash $0 release --force
EOF
      exit 1
    fi

    # Tolerate numeric / #N / PR-N forms for the arg.
    if [ -n "$PR_ID" ]; then
      PR_ID="${PR_ID#\#}"; PR_ID="${PR_ID#PR-}"; PR_ID="${PR_ID#pr-}"
      [[ "$PR_ID" =~ ^[0-9]+$ ]] && PR_ID="PR-$PR_ID"
    fi

    if [ -n "$PR_ID" ] && [ "$PR_ID" != "$HELD" ]; then
      echo "Refused: lock holds $HELD, not $PR_ID. Pass --force to override." >&2
      exit 1
    fi
    rm -f "$LOCK_FILE"
    echo "Lock released: $HELD"
    ;;

  sweep)
    local_count=0
    swept=0
    for f in "$DATA_ENG_WORK_ROOT"/.session-lock-*.json; do
      [ -f "$f" ] || continue
      local_count=$((local_count + 1))
      LOCK_FILE_ORIG="$LOCK_FILE"
      LOCK_FILE="$f"
      if is_stale; then
        HELD=$(read_held_pr)
        rm -f "$f"
        echo "Swept stale lock: $(basename "$f") (was holding $HELD)"
        swept=$((swept + 1))
      fi
      LOCK_FILE="$LOCK_FILE_ORIG"
    done
    if [ "$local_count" -eq 0 ]; then
      echo "(no locks present)"
    elif [ "$swept" -eq 0 ]; then
      echo "$local_count lock(s) present, all live"
    fi
    ;;

  status)
    if [ -f "$LOCK_FILE" ]; then
      cat "$LOCK_FILE"
    else
      echo "unlocked"
    fi
    ;;

  read-pr)
    read_held_pr
    ;;

  *)
    echo "usage: $0 {acquire <PR_ID> [PHASE] | release [PR_ID] | sweep | status | read-pr}" >&2
    exit 2
    ;;
esac
