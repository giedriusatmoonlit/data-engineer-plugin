#!/usr/bin/env bash
# data-engineer-plugin · pr-status.sh
#
# Deterministic situational briefing for one PR. Prints a self-contained
# block telling the developer (and the model in the spawned cs pane):
#   - what PR this is (title, URL, branch, linked ticket)
#   - what phase we're at
#   - worktree health (exists? clean? on the right branch?)
#   - comment counts + top unaddressed must-fix items
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
MF_TOTAL=$(jq -r '.must_fix_total // 0' "$STATE")
MF_DONE=$(jq -r  '.must_fix_addressed // 0' "$STATE")
NIT_TOTAL=$(jq -r '.nits_total // 0' "$STATE")
Q_TOTAL=$(jq -r '.questions_total // 0' "$STATE")
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
  1) PHASE_COLOR="cyan";   PHASE_HINT="ADDRESS pending: edit + commit must-fix items" ;;
  2) PHASE_COLOR="cyan";   PHASE_HINT="HANDOFF pending: write handoff.md" ;;
  3) PHASE_COLOR="green";  PHASE_HINT="DONE — read handoff.md, push manually, reply on ADO" ;;
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

# ── comments ──────────────────────────────────────────────────────────────────
echo "$HR_THIN"
echo "  Comments"
echo "$HR_THIN"
printf "  Must-fix:   %2d/%-2d addressed\n"  "$MF_DONE" "$MF_TOTAL"
printf "  Nits:       %2d documented\n"       "$NIT_TOTAL"
printf "  Questions:  %2d open\n"             "$Q_TOTAL"
echo

# ── top unaddressed MFs ───────────────────────────────────────────────────────
if [ "$BRIEF" -eq 0 ] && [ -f "$PR_DIR/comments.md" ]; then
  TOP_MF=$(grep -E '^- \[ \] \*\*MF-' "$PR_DIR/comments.md" 2>/dev/null | head -3)
  if [ -n "$TOP_MF" ]; then
    echo "$HR_THIN"
    echo "  Unaddressed must-fix (top 3 of $((MF_TOTAL - MF_DONE)) remaining)"
    echo "$HR_THIN"
    while IFS= read -r line; do
      # Strip the markdown checkbox prefix; keep MF-N + the rest.
      cleaned=$(echo "$line" | sed -E 's/^- \[ \] \*\*(MF-[0-9]+)\*\* · /  \1  /; s/`//g')
      echo "$cleaned"
    done <<< "$TOP_MF"
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
    # Find the first unchecked MF + its proposed approach (if plan.md has one).
    NEXT_MF=""
    NEXT_FILE=""
    if [ -f "$PR_DIR/comments.md" ]; then
      NEXT_MF=$(grep -m1 -E '^- \[ \] \*\*MF-' "$PR_DIR/comments.md" 2>/dev/null \
        | sed -E 's/^- \[ \] \*\*(MF-[0-9]+)\*\*.*/\1/')
    fi
    if [ -n "$NEXT_MF" ] && [ -f "$PR_DIR/plan.md" ]; then
      # Pull the one-line summary from the plan.md heading for this MF.
      NEXT_FILE=$(grep -m1 -E "^## .*$NEXT_MF\b" "$PR_DIR/plan.md" 2>/dev/null \
        | sed -E "s/^## [0-9. ]*$NEXT_MF +[—-]+ +//")
    fi
    echo "  Consultative ADDRESS loop — propose to dev, then apply on approval."
    if [ -n "$NEXT_MF" ]; then
      echo "    Next:  $NEXT_MF${NEXT_FILE:+  ·  $NEXT_FILE}"
      echo "    1. Print $NEXT_MF block from plan.md (reviewer intent, code, proposed approach)"
      echo "    2. Read each skill listed under 'Relevant skills'"
      echo "    3. Ask dev:  approve / different / skip / show-alternatives / show-related-code"
      echo "    4. On approve → edit in worktree → commit → mark [x] → bump counter"
      echo "    Dev can say 'approve all' at the start to fall through to autonomous mode."
    else
      echo "    All MFs resolved or no MFs in plan."
    fi
    echo "    Files:"
    echo "      $PR_DIR/plan.md       proposals (per-MF approach + open questions)"
    echo "      $PR_DIR/comments.md   audit trail (Dev notes, Applied lines, checkboxes)"
    echo "      $WT                   worktree (edit here)"
    echo "    Gate:    bash \$CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh $PR_ID"
    ;;
  2)
    echo "  Write the developer's HANDOFF sheet:"
    echo "    Render $PR_DIR/handoff.md from"
    echo "       \$CLAUDE_PLUGIN_ROOT/skills/address-pr-comments/handoff.template.md"
    echo "    Gate:  bash \$CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh $PR_ID"
    ;;
  3)
    echo "  Phase 3 reached — your work in this cs pane is done."
    echo "    Read   $PR_DIR/handoff.md"
    echo "    Push:  git -C $WT push origin $SRC"
    echo "    Then reply to each thread on ADO using the drafts in handoff.md."
    echo
    echo "  If reviewer comes back with more:"
    echo "    /data-engineer-plugin:fix-pr $PR_ID --refresh"
    ;;
esac

echo
cyan "$HR"
echo
