#!/usr/bin/env bash
# data-engineer-plugin · PR phase exit gate
#
# Called by /data-engineer-plugin:fix-pr after the model claims a phase
# is done. Validates the on-disk artifacts the phase requires, then
# atomically advances pr_notes/<PR_ID>/state.json to the next phase.
#
# Two phases (PRs aren't 7-stage scrapers):
#
#   0 → 1   TRIAGE      pr_packet.json cached; state.open_threads[]
#                       written with every active ADO thread
#   1 → 2   ADDRESS     every open_threads entry has a decision
#                       (applied / reply / deferred); applied decisions
#                       have real commit_sha in triage..HEAD; worktree
#                       is clean
#
# Phase 2 is terminal *for this command*. fix-pr prints an in-chat
# summary at the end of ADDRESS (no handoff.md file). Push + ADO
# comment-replies are intentionally human actions; fix-pr does not
# automate them.
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
    # TRIAGE done: pr_packet.json cached; state.json has all the
    # canonical fields populated AND an open_threads array listing
    # every active ADO thread.
    check_file_nonempty "$PR_DIR/pr_packet.json" "pr_packet.json"
    check_state_field   '.pr_id'                 "pr_id"
    check_state_field   '.pr_url'                "pr_url"
    check_state_field   '.source_branch'         "source_branch"
    check_state_field   '.head_sha_at_triage'    "head_sha_at_triage"
    # open_threads[] must exist (may be empty for a PR with no comments,
    # but the array MUST be present). Reject the old categorized_comments
    # shape outright so stale triage outputs surface here.
    HAS_OT=$(jq -r 'has("open_threads")' "$STATE" 2>/dev/null || echo false)
    if [ "$HAS_OT" != "true" ]; then
      FAILS=$((FAILS+1)); FAIL_MSGS+=("state.open_threads missing — triage didn't write it")
    fi
    if jq -e 'has("categorized_comments")' "$STATE" >/dev/null 2>&1; then
      FAILS=$((FAILS+1))
      FAIL_MSGS+=("state.categorized_comments is the old shape — TRIAGE must emit open_threads[] only (no classification)")
    fi
    # open_threads_total must match the array length.
    OT_EXPECT=$(jq -r '.open_threads_total // 0' "$STATE")
    OT_IN_ARRAY=$(jq -r '.open_threads | length // 0' "$STATE" 2>/dev/null || echo 0)
    if [ "$OT_EXPECT" != "$OT_IN_ARRAY" ]; then
      FAILS=$((FAILS+1))
      FAIL_MSGS+=("open_threads_total ($OT_EXPECT) doesn't match open_threads[] length ($OT_IN_ARRAY)")
    fi
    ;;
  1)
    check_state_field '.worktree_path' "worktree_path"
    WT=$(jq -r '.worktree_path // empty' "$STATE")
    if [ -n "$WT" ] && [ ! -d "$WT" ]; then
      FAILS=$((FAILS+1)); FAIL_MSGS+=("worktree_path doesn't exist on disk: $WT")
    fi
    # Every open_threads entry must have a decision (applied/reply/deferred).
    UNDECIDED=$(jq -r '
      (.open_threads // []) as $ot |
      (.decisions // []) as $dec |
      [$ot[] | .id] - [$dec[] | .thread_id] | length
    ' "$STATE" 2>/dev/null || echo 0)
    if [ "$UNDECIDED" -gt 0 ]; then
      FAILS=$((FAILS+1))
      FAIL_MSGS+=("$UNDECIDED open thread(s) have no decision in state.decisions[]")
    fi
    # state.addressed should equal count(applied) + count(reply).
    EXPECT_ADDR=$(jq -r '[.decisions[]? | select(.action == "applied" or .action == "reply")] | length' "$STATE" 2>/dev/null || echo 0)
    GOT_ADDR=$(jq -r '.addressed // 0' "$STATE")
    if [ "$GOT_ADDR" != "$EXPECT_ADDR" ]; then
      FAILS=$((FAILS+1))
      FAIL_MSGS+=("state.addressed ($GOT_ADDR) doesn't match count of applied+reply decisions ($EXPECT_ADDR)")
    fi
    # Every reply decision must have non-empty reply_text.
    BAD_REPLIES=$(jq -r '[.decisions[]? | select(.action == "reply" and ((.reply_text // "") == "")) | .thread_id] | join(", ")' "$STATE" 2>/dev/null)
    if [ -n "$BAD_REPLIES" ] && [ "$BAD_REPLIES" != "null" ]; then
      FAILS=$((FAILS+1))
      FAIL_MSGS+=("reply decision(s) with empty reply_text: $BAD_REPLIES")
    fi
    if [ -n "$WT" ] && [ -d "$WT" ]; then
      TRIAGE_SHA=$(jq -r '.head_sha_at_triage // empty' "$STATE")
      CURR_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null || echo "")
      # New commits required only if at least one decision is "applied".
      APPLIED_COUNT=$(jq -r '[.decisions[]? | select(.action == "applied")] | length' "$STATE" 2>/dev/null || echo 0)
      if [ "$APPLIED_COUNT" -gt 0 ]; then
        if [ -n "$TRIAGE_SHA" ] && [ -n "$CURR_SHA" ] && [ "$TRIAGE_SHA" = "$CURR_SHA" ]; then
          FAILS=$((FAILS+1))
          FAIL_MSGS+=("no new commits since triage (HEAD still at $TRIAGE_SHA) but $APPLIED_COUNT applied decision(s) recorded — commit your edits")
        fi
      fi
      DIRTY=$(git -C "$WT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      if [ "$DIRTY" -gt 0 ]; then
        FAILS=$((FAILS+1))
        FAIL_MSGS+=("worktree has $DIRTY uncommitted change(s); commit or discard before completing ADDRESS")
      fi
      # Every applied decision must reference a real commit between triage..HEAD.
      # Blocks the failure mode where the model fabricates decisions in
      # one synthetic burst without actually committing the work.
      if [ -n "$TRIAGE_SHA" ] && [ -n "$CURR_SHA" ] && [ "$TRIAGE_SHA" != "$CURR_SHA" ]; then
        REAL_SHAS=$(git -C "$WT" rev-list "$TRIAGE_SHA..HEAD" 2>/dev/null || echo "")
        # For each applied decision, check its commit_sha is present AND non-empty.
        MISSING=$(jq -r '[.decisions[]? | select(.action == "applied" and ((.commit_sha // "") == "")) | .thread_id] | join(", ")' "$STATE" 2>/dev/null)
        if [ -n "$MISSING" ] && [ "$MISSING" != "null" ]; then
          FAILS=$((FAILS+1))
          FAIL_MSGS+=("applied decision(s) with no commit_sha: $MISSING — every applied thread must record the real commit it landed in")
        fi
        # Check each declared commit_sha actually exists in triage..HEAD.
        while IFS= read -r sha; do
          [ -z "$sha" ] && continue
          if ! grep -q "^$sha\$" <<<"$REAL_SHAS"; then
            TID=$(jq -r --arg s "$sha" '.decisions[] | select(.commit_sha == $s) | .thread_id' "$STATE" 2>/dev/null | head -1)
            FAILS=$((FAILS+1))
            FAIL_MSGS+=("decision $TID claims commit_sha=$sha, but that SHA isn't in $TRIAGE_SHA..HEAD — fabricated or wrong worktree?")
          fi
        done < <(jq -r '.decisions[]? | select(.action == "applied") | .commit_sha // empty' "$STATE" 2>/dev/null)
      fi
    fi
    ;;
  *)
    die "Unknown FROM phase: $FROM (valid: 0..1)"
    ;;
esac

# ── per-phase NEXT-step guidance on failure ───────────────────────────────────
next_phase_guide() {
  local from="$1"
  case "$from" in
    0)
      cat <<'EOF'
NEXT — Phase 1 (TRIAGE): fetch PR comments and list every open thread.
  • Apply the address-pr-comments skill (SKILL.md has the full recipe)
  • Fetch the PR with az:
      az repos pr show         --id <N> --output json
      az repos pr list-comments --id <N> --output json
    Combine into .notes/pr_packet.json
  • Filter ADO threads: keep status=active; drop fixed/wontFix/closed/
    byDesign/pending. For each kept thread, append to state.open_threads:
      { id: "T-1" (sequential),
        thread_id: <ADO numeric>,
        file_path, line, reviewer, comment_excerpt, thread_url,
        status: "active",
        relevant_skills: ["api-scraper:scraper-rules", ...] }
  • NO classification (no MF/NIT/Q tags). The dev decides per thread
    during ADDRESS what each one warrants.
  • Also set state.json: pr_id, pr_url, source_branch, target_branch,
    head_sha_at_triage, ticket_id (parsed DAT-NNN if found),
    open_threads_total, addressed: 0, last_known_vote,
    comments_fetched_at, decisions: []
  • NO markdown files written. The model presents per-thread blocks
    directly in chat during ADDRESS.
  • Re-run: bash $CLAUDE_PLUGIN_ROOT/scripts/pr-stage-complete.sh <PR_ID>
EOF
      ;;
    1)
      cat <<'EOF'
NEXT — Phase 2 (ADDRESS): consultative loop, in-chat.
  • Walk state.open_threads[] one thread at a time (in array order)
  • Skip threads already in state.decisions[] (resume safe)
  • For each undecided thread:
      1. Print the block in chat: comment_excerpt, file:line, reviewer,
         your proposed approach (1 paragraph) — code change OR reply
         text OR defer suggestion. Open question if any.
      2. Read each skill in .relevant_skills (cross-plugin). Resolve via:
            ls $HOME/.claude-work/plugins/cache/<plugin>/<plugin>/*/skills/<name>/SKILL.md
      3. Ask dev: approve / different: <text> / reply: <text> /
         skip / show alternatives / show related code
      4. On approve+code: edit in worktree → commit
            ("review: address T-N (...)")
         → append decision { thread_id, action:"applied", commit_sha,
            applied_summary, dev_note?, decided_at } → bump state.addressed
      5. On approve+reply or `reply: <text>`: append
            { thread_id, action:"reply", reply_text, decided_at }
         → bump state.addressed (no commit needed)
      6. On skip: append
            { thread_id, action:"deferred", deferred_reason, decided_at }
         Does NOT bump state.addressed. Gate refuses Phase 2 until every
         open_threads entry has a decision.
  • Worktree must end clean. New commits required only if any decision
    is "applied" — pure reply/deferred runs need no commits.
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
  *) echo "unknown" ;;
esac)
jq --argjson phase "$TO" --arg name "$PHASE_NAME" --arg ts "$(now_iso)" \
   '. + {phase: $phase, phase_name: $name, advanced_at: $ts}' "$STATE" > "$TMP" && mv "$TMP" "$STATE"

green "PR Phase $FROM → $TO complete for $PR_ID (advanced to phase $TO / $PHASE_NAME)"
if [ "$TO" -lt 2 ]; then
  echo "  → Re-run pr-stage-complete.sh $PR_ID to validate the Phase $TO → $((TO+1)) gate."
else
  echo "  → Phase 2 is terminal for fix-pr. Print the end-of-ADDRESS summary in chat, then push + reply manually."
fi
