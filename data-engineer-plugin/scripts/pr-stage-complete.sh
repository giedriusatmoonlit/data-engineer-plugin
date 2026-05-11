#!/usr/bin/env bash
# data-engineer-plugin · PR phase exit gate
#
# Called by /data-engineer-plugin:fix-pr after the model claims a phase
# is done. Validates the on-disk artifacts the phase requires, then
# atomically advances pr_notes/<PR_ID>/state.json to the next phase.
#
# Three phases (PRs aren't 7-stage scrapers):
#
#   0 → 1   TRIAGE      pr_packet.json + comments.md + plan.md written
#                       state.must_fix_total recorded
#   1 → 2   ADDRESS     every must-fix is [x] in comments.md
#                       commits exist since state.head_sha_at_triage
#                       worktree is clean (no uncommitted edits)
#   2 → 3   HANDOFF     handoff.md exists (developer's push checklist)
#
# Phase 3 is terminal *for this command*. Push + ADO comment-replies are
# intentionally human actions; fix-pr does not automate them.
#
# Usage:
#   pr-stage-complete.sh <PR_ID|NNNN|#NNNN>             # auto from state.phase
#   pr-stage-complete.sh <PR_ID> --from N --to M        # explicit
#   pr-stage-complete.sh <PR_ID> --check-only           # validate, don't advance
#
# Exit codes:
#   0  gate passed, state advanced (or check-only happy)
#   1  one or more gate checks failed; state NOT advanced
#   2  misuse / bad args / missing pr state.json

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/_env.sh"
require_env DATA_ENG_WORK_ROOT
require_cmd jq

PR_ARG=""
FROM=""
TO=""
CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from)       FROM="${2:?--from N}"; shift 2 ;;
    --to)         TO="${2:?--to M}";     shift 2 ;;
    --check-only) CHECK_ONLY=1;          shift   ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  [ -z "$PR_ARG" ] && PR_ARG="$1" || die "extra arg: $1"; shift ;;
  esac
done

[ -n "$PR_ARG" ] || die "Usage: $0 <PR_ID> [--from N --to M] [--check-only]"
PR_ID=$(canonicalize_pr "$PR_ARG") || die "Not a valid PR id: '$PR_ARG'"

STATE=$(pr_state_file "$PR_ID")
[ -f "$STATE" ] || die "No PR state.json at $STATE; run /data-engineer-plugin:address-pr first."

[ -z "$FROM" ] && FROM=$(jq -r '.phase // 0' "$STATE")
[ -z "$TO" ]   && TO=$((FROM + 1))

[[ "$FROM" =~ ^[0-9]+$ ]] || die "FROM not numeric: '$FROM'"
[[ "$TO"   =~ ^[0-9]+$ ]] || die "TO not numeric: '$TO'"
[ "$TO" -gt "$FROM" ]     || die "TO ($TO) must be > FROM ($FROM)"

PR_DIR=$(pr_dir "$PR_ID")
FAILS=0
declare -a FAIL_MSGS

check_file_nonempty() {
  local f="$1" desc="$2"
  if [ ! -f "$f" ]; then
    FAILS=$((FAILS+1)); FAIL_MSGS+=("missing $desc: $f")
  elif [ ! -s "$f" ]; then
    FAILS=$((FAILS+1)); FAIL_MSGS+=("empty $desc: $f")
  fi
}

check_state_field() {
  local jq_path="$1" desc="$2"
  local v
  v=$(jq -r "$jq_path // empty" "$STATE" 2>/dev/null)
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    FAILS=$((FAILS+1)); FAIL_MSGS+=("state.json missing field: $desc ($jq_path)")
  fi
}

# ── per-phase exit gates ─────────────────────────────────────────────────────
case "$FROM" in
  0)
    check_file_nonempty "$PR_DIR/pr_packet.json" "pr_packet.json"
    check_file_nonempty "$PR_DIR/comments.md"    "comments.md"
    check_file_nonempty "$PR_DIR/plan.md"        "plan.md"
    check_state_field   '.pr_id'                 "pr_id"
    check_state_field   '.pr_url'                "pr_url"
    check_state_field   '.source_branch'         "source_branch"
    check_state_field   '.head_sha_at_triage'    "head_sha_at_triage"
    check_state_field   '.must_fix_total'        "must_fix_total"
    ;;
  1)
    check_state_field '.worktree_path' "worktree_path"
    WT=$(jq -r '.worktree_path // empty' "$STATE")
    if [ -n "$WT" ] && [ ! -d "$WT" ]; then
      FAILS=$((FAILS+1)); FAIL_MSGS+=("worktree_path doesn't exist on disk: $WT")
    fi
    TOTAL=$(jq -r '.must_fix_total // 0' "$STATE")
    DONE=$(jq -r  '.must_fix_addressed // 0' "$STATE")
    if [ "$DONE" -lt "$TOTAL" ]; then
      FAILS=$((FAILS+1))
      FAIL_MSGS+=("must_fix_addressed ($DONE) < must_fix_total ($TOTAL) — finish the remaining items in comments.md")
    fi
    if [ -f "$PR_DIR/comments.md" ]; then
      OPEN_MF=$(grep -cE '^- \[ \] MF-' "$PR_DIR/comments.md" 2>/dev/null || echo 0)
      if [ "$OPEN_MF" -gt 0 ]; then
        FAILS=$((FAILS+1))
        FAIL_MSGS+=("comments.md still has $OPEN_MF unchecked must-fix item(s)")
      fi
    fi
    if [ -n "$WT" ] && [ -d "$WT" ]; then
      TRIAGE_SHA=$(jq -r '.head_sha_at_triage // empty' "$STATE")
      CURR_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null || echo "")
      if [ -n "$TRIAGE_SHA" ] && [ -n "$CURR_SHA" ] && [ "$TRIAGE_SHA" = "$CURR_SHA" ]; then
        FAILS=$((FAILS+1))
        FAIL_MSGS+=("no new commits since triage (HEAD still at $TRIAGE_SHA) — commit your edits before completing ADDRESS")
      fi
      DIRTY=$(git -C "$WT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      if [ "$DIRTY" -gt 0 ]; then
        FAILS=$((FAILS+1))
        FAIL_MSGS+=("worktree has $DIRTY uncommitted change(s); commit or discard before completing ADDRESS")
      fi
    fi
    ;;
  2)
    check_file_nonempty "$PR_DIR/handoff.md" "handoff.md"
    ;;
  *)
    die "Unknown FROM phase: $FROM (valid: 0..2)"
    ;;
esac

# ── per-phase NEXT-step guidance on failure ───────────────────────────────────
next_phase_guide() {
  local from="$1"
  case "$from" in
    0)
      cat <<'EOF'
NEXT — Phase 1 (TRIAGE): fetch and categorize PR comments.
  • Apply the address-pr-comments skill (SKILL.md has the full recipe)
  • Fetch the PR with az:
      az repos pr show         --id <N> --output json
      az repos pr list-comments --id <N> --output json
    Combine into .notes/pr_packet.json (relative to the worktree)
  • Produce in <worktree>/.notes/:
      pr_packet.json    raw ADO response (cached for re-fetch diffing)
      comments.md       categorized: '- [ ] MF-N ...' must-fix /
                        '- [ ] NIT-N ...' nit / '- [ ] Q-N ...' question
      plan.md           per-MF blocks with Proposed approach + Open question
  • Set in .notes/state.json:
      pr_id, pr_url, source_branch, head_sha_at_triage, must_fix_total
  • Re-run: bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
EOF
      ;;
    1)
      cat <<'EOF'
NEXT — Phase 2 (ADDRESS): consultative loop — propose, ask, apply.
  • Walk .notes/plan.md one MF at a time
  • For each MF-N:
      1. Print the plan.md block (reviewer intent + code + Proposed approach)
      2. Read each skill listed under "Relevant skills" (cross-plugin)
      3. Ask dev: approve / different: <text> / skip / show-alternatives
      4. On approve: edit in worktree → commit ("review: address MF-N (...)")
                     → append 'Applied: ...' line to comments.md
                     → mark '- [x] MF-N'
                     → bump state.must_fix_addressed
  • Worktree must end clean (git status --porcelain empty)
  • NEW commits must exist since state.head_sha_at_triage
  • Nits = same loop (approve/skip only). Questions = reply text only.
  • Re-run: bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
EOF
      ;;
    2)
      cat <<'EOF'
NEXT — Phase 3 (HANDOFF): write the developer's push checklist.
  • Render .notes/handoff.md from the
    skills/address-pr-comments/handoff.template.md template. Fill in:
      - New commit SHAs since triage (one line each, with subject)
      - Per-MF mapping (commit → MF-N)
      - Nit summary (addressed in this round vs deferred)
      - Question reply DRAFTS (one per Q-N) for the developer to paste on ADO
      - Exact push command: git -C <worktree> push origin <source_branch>
      - Exact ADO thread URLs to reply on
  • This file is the human's takeover sheet. fix-pr never pushes and never
    replies to ADO threads — that's a deliberate stop-line.
  • Re-run: bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
EOF
      ;;
  esac
}

# ── report ────────────────────────────────────────────────────────────────────
if [ "$FAILS" -gt 0 ]; then
  red "PR Phase $FROM → $TO exit gate failed for $PR_ID ($FAILS issue(s)):"
  for m in "${FAIL_MSGS[@]}"; do red "  • $m"; done
  echo
  next_phase_guide "$FROM"
  echo
  red "State NOT advanced. Do the work above, then re-run."
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  green "PR Phase $FROM → $TO exit gate: OK (check-only; state not modified)"
  exit 0
fi

# Advance state.
TMP=$(mktemp)
PHASE_NAME=$(case "$TO" in
  1) echo "triaged" ;;
  2) echo "addressed" ;;
  3) echo "handed-off" ;;
  *) echo "unknown" ;;
esac)
jq --argjson phase "$TO" --arg name "$PHASE_NAME" --arg ts "$(now_iso)" \
   '. + {phase: $phase, phase_name: $name, advanced_at: $ts}' "$STATE" > "$TMP" && mv "$TMP" "$STATE"

green "PR Phase $FROM → $TO complete for $PR_ID (advanced to phase $TO / $PHASE_NAME)"
if [ "$TO" -lt 3 ]; then
  echo "  → Re-run pr-stage-complete.sh $PR_ID to validate the Phase $TO → $((TO+1)) gate."
else
  echo "  → Phase 3 is terminal for fix-pr. Read handoff.md, then push + reply manually."
fi
