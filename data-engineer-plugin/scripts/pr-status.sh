#!/usr/bin/env bash
# data-engineer-plugin · pr-status.sh
#
# Deterministic situational briefing for one PR. Prints a self-contained
# block telling the developer (and the model in the spawned cs pane):
#   - what PR this is (title, URL, branch, linked ticket)
#   - what phase we're at
#   - worktree health (exists? clean? on the right branch?)
#   - open-thread counts + top undecided threads
#   - the single most useful next action
#
# Called automatically by /data-engineer-plugin:fix-pr as step 0.
# Also runnable by the developer at any time:
#   bash $CLAUDE_PLUGIN_ROOT/scripts/pr-status.sh PR-2299
#
# Usage:
#   pr-status.sh <PR_ID|NNNN|#NNNN> [--brief]
#
# Exits 0 always (it's a read-only status print, not a gate).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/_env.sh"
require_env DATA_ENG_WORK_ROOT
require_cmd jq

PR_ARG="${1:-}"
BRIEF=0
[ "${2:-}" = "--brief" ] && BRIEF=1

[ -n "$PR_ARG" ] || { red "usage: $0 <PR_ID> [--brief]"; exit 2; }
PR_ID=$(canonicalize_pr "$PR_ARG") || { red "Not a valid PR id: $PR_ARG"; exit 2; }
PR_NUM=$(pr_numeric "$PR_ID")

STATE=$(pr_state_file "$PR_ID")
PR_DIR=$(pr_dir "$PR_ID")

# ── divider ───────────────────────────────────────────────────────────────────
HR=$(printf '═%.0s' $(seq 1 79))
HR_THIN=$(printf '─%.0s' $(seq 1 79))

echo
cyan "$HR"
cyan "  $PR_ID"
cyan "$HR"

# ── no state yet ──────────────────────────────────────────────────────────────
if [ ! -f "$STATE" ]; then
  yellow "No state.json yet — this PR hasn't been triaged."
  echo
  echo "To start:"
  echo "  /data-engineer-plugin:address-pr $PR_NUM       # triage + spawn cs"
  echo "  /data-engineer-plugin:fix-pr     $PR_NUM       # triage inside this pane"
  echo
  cyan "$HR"
  echo
  exit 0
fi

# ── load state ────────────────────────────────────────────────────────────────
PHASE=$(jq -r '.phase // 0' "$STATE")
PHASE_NAME=$(jq -r '.phase_name // "fresh"' "$STATE")
PR_TITLE=$(jq -r '.pr_title // empty' "$STATE")
PR_URL=$(jq -r '.pr_url // empty' "$STATE")
TICKET=$(jq -r '.ticket_id // empty' "$STATE")
SRC=$(jq -r '.source_branch // empty' "$STATE")
TGT=$(jq -r '.target_branch // "master"' "$STATE")
TRIAGE_SHA=$(jq -r '.head_sha_at_triage // empty' "$STATE")
WT=$(jq -r '.worktree_path // empty' "$STATE")
OT_TOTAL=$(jq -r '.open_threads_total // 0' "$STATE")
ADDR_DONE=$(jq -r '.addressed // 0' "$STATE")
DEFERRED_N=$(jq -r '[.decisions[]? | select(.action == "deferred")] | length' "$STATE" 2>/dev/null || echo 0)
LAST_VOTE=$(jq -r '.last_known_vote // empty' "$STATE")
FETCHED=$(jq -r '.comments_fetched_at // empty' "$STATE")

# ── header block ──────────────────────────────────────────────────────────────
[ -n "$PR_TITLE" ] && echo "  $PR_TITLE"
[ -n "$PR_URL" ]   && echo "  URL:        $PR_URL"
echo "  Ticket:     ${TICKET:-<none parsed>}"
echo "  Branch:     ${SRC:-?}  →  $TGT"
echo "  Triaged:    ${FETCHED:-?}   Last vote: ${LAST_VOTE:-?}"
echo

# ── phase ─────────────────────────────────────────────────────────────────────
case "$PHASE" in
  0) PHASE_COLOR="yellow"; PHASE_HINT="TRIAGE pending (run /fix-pr)" ;;
  1) PHASE_COLOR="cyan";   PHASE_HINT="ADDRESS pending: walk open threads with dev" ;;
  2) PHASE_COLOR="green";  PHASE_HINT="DONE — push manually, reply on ADO using the in-chat summary" ;;
  *) PHASE_COLOR="red";    PHASE_HINT="unknown phase $PHASE" ;;
esac
echo "  Phase:      $PHASE · $PHASE_NAME"
$PHASE_COLOR "              → $PHASE_HINT"
echo

# ── worktree health ───────────────────────────────────────────────────────────
echo "  Worktree:   ${WT:-<not yet created>}"
if [ -n "$WT" ] && [ -d "$WT" ]; then
  CURR_BRANCH=$(git -C "$WT" branch --show-current 2>/dev/null || echo "")
  CURR_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null || echo "")
  DIRTY_N=$(git -C "$WT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$CURR_BRANCH" != "$SRC" ]; then
    red    "              ⚠ on branch '$CURR_BRANCH' (expected '$SRC')"
  fi
  if [ "$DIRTY_N" -gt 0 ]; then
    yellow "              ⚠ $DIRTY_N uncommitted change(s)"
  fi
  if [ -n "$TRIAGE_SHA" ] && [ -n "$CURR_SHA" ]; then
    if [ "$TRIAGE_SHA" = "$CURR_SHA" ]; then
      echo "              HEAD: ${CURR_SHA:0:12} (same as triage — no new commits)"
    else
      DELTA=$(git -C "$WT" rev-list --count "$TRIAGE_SHA..HEAD" 2>/dev/null || echo "?")
      green  "              HEAD: ${CURR_SHA:0:12} (+$DELTA commits since triage ${TRIAGE_SHA:0:12})"
    fi
  fi
else
  [ -n "$WT" ] && red "              ⚠ path does not exist on disk"
fi
echo

# ── threads ──────────────────────────────────────────────────────────────────
echo "$HR_THIN"
echo "  Open threads"
echo "$HR_THIN"
UNDECIDED_N=$((OT_TOTAL - ADDR_DONE - DEFERRED_N))
[ "$UNDECIDED_N" -lt 0 ] && UNDECIDED_N=0
printf "  Total:      %2d\n"          "$OT_TOTAL"
printf "  Addressed:  %2d  (applied + reply)\n" "$ADDR_DONE"
printf "  Deferred:   %2d\n"          "$DEFERRED_N"
printf "  Undecided:  %2d\n"          "$UNDECIDED_N"
echo

# ── top undecided threads ─────────────────────────────────────────────────────
# Read from state.open_threads, filtered against state.decisions.
# A thread is "undecided" when it's in open_threads and NOT in decisions[thread_id].
if [ "$BRIEF" -eq 0 ]; then
  TOP=$(jq -r '
    (.open_threads // []) as $ot |
    (.decisions // []) as $dec |
    ($dec | map(.thread_id)) as $done_ids |
    $ot[] | select(.id as $id | $done_ids | index($id) | not) |
    "  \(.id)  \(.file_path // "general")\(if .line then ":\(.line)" else "" end)\(if .reviewer then " · \(.reviewer)" else "" end)"
  ' "$STATE" 2>/dev/null | head -3)
  if [ -n "$TOP" ]; then
    echo "$HR_THIN"
    echo "  Undecided threads (top 3 of $UNDECIDED_N remaining)"
    echo "$HR_THIN"
    echo "$TOP"
    echo
  fi
fi

# ── suggested next action ─────────────────────────────────────────────────────
echo "$HR_THIN"
echo "  Suggested next action"
echo "$HR_THIN"
case "$PHASE" in
  0)
    echo "  Run the TRIAGE phase. Inside this cs pane:"
    echo "    Apply the address-pr-comments skill, then:"
    echo "    bash \$CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh $PR_ID"
    ;;
  1)
    # First undecided open_thread.
    NEXT=$(jq -c '
      (.open_threads // []) as $ot |
      (.decisions // []) as $dec |
      ($dec | map(.thread_id)) as $done_ids |
      [$ot[] | select(.id as $id | $done_ids | index($id) | not)] |
      first // empty
    ' "$STATE" 2>/dev/null)
    echo "  Consultative ADDRESS loop — present in chat, dev decides, you apply."
    if [ -n "$NEXT" ] && [ "$NEXT" != "null" ]; then
      NEXT_ID=$(jq -r '.id // empty' <<<"$NEXT")
      NEXT_FILE=$(jq -r '.file_path // "general"' <<<"$NEXT")
      NEXT_LINE=$(jq -r '.line // empty' <<<"$NEXT")
      NEXT_EXCERPT=$(jq -r '.comment_excerpt // empty' <<<"$NEXT" | head -c 90)
      echo "    Next:  $NEXT_ID  ·  $NEXT_FILE${NEXT_LINE:+:$NEXT_LINE}"
      [ -n "$NEXT_EXCERPT" ] && echo "           “$NEXT_EXCERPT…”"
      echo "    1. Read state.open_threads[] entry for $NEXT_ID"
      echo "    2. Read each skill listed under .relevant_skills (cross-plugin OK)"
      echo "    3. Print thread block in chat (excerpt + file:line + proposed approach)"
      echo "    4. Ask dev:  approve / different / reply: <text> / skip / show alternatives / show related code"
      echo "    5. On approve+code → edit in worktree → commit → append decision (applied)"
      echo "       On approve+reply or 'reply: <text>' → append decision (reply), no commit"
      echo "       On skip → append decision (deferred)"
      echo "    Dev can say 'approve all' at start to fall through to autonomous mode."
    else
      echo "    All threads decided. Run the gate to finalize ADDRESS:"
    fi
    echo "    State (jq-readable):"
    echo "      .notes/state.json   .open_threads  /  .decisions"
    echo "    Gate:  bash \$CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh $PR_ID"
    ;;
  2)
    echo "  Phase 2 reached — your work in this cs pane is done."
    echo "    Push:  git -C $WT push origin $SRC"
    echo "    Reply on ADO using each decision's reply_text / deferred_reason"
    echo "    (see the end-of-ADDRESS summary that was printed in chat)."
    echo
    echo "  If reviewer comes back with more:"
    echo "    /data-engineer-plugin:fix-pr $PR_ID --refresh"
    ;;
esac

echo
cyan "$HR"
echo
