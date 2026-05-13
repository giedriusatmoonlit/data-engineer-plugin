#!/usr/bin/env bash
# data-engineer-plugin · launch-pr-batch.sh
#
# Spawns ONE Cursor window per batch with a multi-root workspace
# containing all the per-PR worktrees. After Cursor loads, the launcher
# fires `cursor --open-url vscode://anthropic.claude-code/open?prompt=…`
# once per PR so each lands in a fresh Claude Code chat tab prefilled
# with `/data-engineer-plugin:fix-pr PR-NNNN`. The URI handler doesn't
# auto-submit; user hits Enter per tab.
#
# Per-batch artifacts under $BATCH_DIR (DATA_ENG_WORK_ROOT/pr_notes/_batch/<BATCH_ID>/):
#   - batch.json              existing batch-prep output
#   - batch.code-workspace    multi-root workspace + auto-fire tasks
#
# For each PR:
#   1. Resolve source branch + worktree path.
#   2. Create / refresh the git worktree at <worktree-parent>/<repo>-pr-NNNN/.
#   3. Pre-accept the project trust dialog (~/.claude.json).
#   4. Initialize / refresh the worktree's .notes/state.json.
#
# Usage:
#   launch-pr-batch.sh <BATCH_ID> [--dry-run] [--force] [--only PR-NNNN[,...]]
#
# Exits 0 on success. Exits 1 on any per-PR failure (other PRs still tried).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/_env.sh"
require_env DATA_ENG_WORK_ROOT
require_cmd jq git cursor

# ── arg parsing ───────────────────────────────────────────────────────────────
BATCH_ID="${1:-}"
[ -n "$BATCH_ID" ] || { red "usage: $0 <BATCH_ID> [--dry-run] [--force] [--only PR-NNNN[,PR-MMMM...]]"; exit 2; }
shift
DRY_RUN=0
FORCE=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    --only)    ONLY="${2:-}"; shift 2 ;;
    *)         red "unknown arg: $1"; exit 2 ;;
  esac
done

BATCH_DIR=$(pr_batch_dir "$BATCH_ID")
BATCH_FILE=$(pr_batch_file "$BATCH_ID")
[ -f "$BATCH_FILE" ] || die "No batch.json at $BATCH_FILE"

REPO=$(repo_root)
[ -n "$REPO" ] || die "No repo root resolved (set DATA_ENG_REPO_ROOT or SCRAPER_REPO_ROOT)"
[ -d "$REPO" ] || die "Repo root doesn't exist: $REPO"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_CONFIG_DIR_FWD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Safety net: verify data-engineer-plugin is enabled in the forwarded dir.
verify_plugin_enabled() {
  local dir="$1"
  [ -f "$dir/settings.json" ] || return 1
  jq -e '.enabledPlugins["data-engineer-plugin@data-engineer-plugin"] // false |
         select(. == true)' "$dir/settings.json" >/dev/null 2>&1
}
if ! verify_plugin_enabled "$CLAUDE_CONFIG_DIR_FWD"; then
  yellow "Note: data-engineer-plugin not enabled in $CLAUDE_CONFIG_DIR_FWD/settings.json"
  found=""
  for cand in "$HOME/.claude-work" "$HOME/.claude"; do
    [ "$cand" = "$CLAUDE_CONFIG_DIR_FWD" ] && continue
    if verify_plugin_enabled "$cand"; then
      found="$cand"; break
    fi
  done
  if [ -n "$found" ]; then
    yellow "  → switching to $found (data-engineer-plugin enabled there)"
    CLAUDE_CONFIG_DIR_FWD="$found"
  else
    red "  → no candidate dir has the plugin enabled; spawned sessions"
    red "     will fail with 'Unknown command'. Run /plugin install"
    red "     data-engineer-plugin in your master session first."
  fi
fi

mkdir -p "$BATCH_DIR"

# ── pick PRs ──────────────────────────────────────────────────────────────────
# batch.json: .prs[] = {pr_id, source_branch, target_branch, head_sha, ticket_id?}
mapfile -t ALL_PRS < <(jq -r '.prs[]?.pr_id // empty' "$BATCH_FILE")
[ "${#ALL_PRS[@]}" -eq 0 ] && die "batch.json has no .prs[]"

declare -a PRS
if [ -n "$ONLY" ]; then
  IFS=',' read -r -a FILTER <<<"$ONLY"
  for p in "${ALL_PRS[@]}"; do
    for f in "${FILTER[@]}"; do
      fn=$(canonicalize_pr "$f" 2>/dev/null || echo "$f")
      [ "$p" = "$fn" ] && PRS+=("$p") && break
    done
  done
else
  PRS=("${ALL_PRS[@]}")
fi

[ "${#PRS[@]}" -eq 0 ] && { yellow "No PRs to launch."; exit 0; }

cyan "Launching ${#PRS[@]} PR(s) for batch $BATCH_ID"
[ "$DRY_RUN" -eq 1 ] && yellow "  (DRY RUN — no worktree/workspace/Cursor writes)"
echo

REPO_BASENAME=$(basename "$REPO")
LAUNCHED=()
SKIPPED=()
FAILED=()
HAS_WORKTREE=()

# ── pre-flight: dirty tree guard (lazy) ───────────────────────────────────────
dirty_check_done=0
ensure_clean_tree() {
  [ "$dirty_check_done" -eq 1 ] && return 0
  if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    red "Need to create a worktree, but main repo at $REPO is dirty."
    red "Commit/stash/discard first, then re-run:"
    git -C "$REPO" status --short >&2
    return 1
  fi
  dirty_check_done=1
}

if [ "$DRY_RUN" -eq 0 ]; then
  cyan "Fetching origin before any worktree creation..."
  git -C "$REPO" fetch origin 2>&1 | sed 's/^/  /' || yellow "  fetch failed — proceeding with cached refs"
  echo
fi

# ── per-PR loop ───────────────────────────────────────────────────────────────
for PR_ID in "${PRS[@]}"; do
  echo "── $PR_ID ──"
  PR_NUM="${PR_ID#PR-}"

  PR_ROW=$(jq -c --arg p "$PR_ID" '.prs[]? | select(.pr_id == $p)' "$BATCH_FILE")
  if [ -z "$PR_ROW" ]; then
    red "  $PR_ID not in batch.json — skip"
    FAILED+=("$PR_ID (not in batch)")
    continue
  fi
  SRC_BRANCH=$(jq -r '.source_branch // empty' <<<"$PR_ROW")
  TICKET=$(jq -r '.ticket_id // empty' <<<"$PR_ROW")
  PR_URL=$(jq -r '.pr_url // empty' <<<"$PR_ROW")

  if [ -z "$SRC_BRANCH" ]; then
    red "  no source_branch — skip (re-run /address-pr to refresh batch)"
    FAILED+=("$PR_ID (no source branch)")
    continue
  fi

  WT_PATH="$(worktree_parent)/${REPO_BASENAME}-pr-${PR_NUM}"

  echo "  source:    $SRC_BRANCH"
  echo "  ticket:    ${TICKET:-<none>}"
  echo "  worktree:  $WT_PATH"

  if [ "$DRY_RUN" -eq 1 ]; then
    green "  [dry-run] would create worktree + register in workspace tasks"
    LAUNCHED+=("$PR_ID")
    continue
  fi

  # 1. worktree
  if [ -d "$WT_PATH" ]; then
    yellow "  worktree exists — fetching latest origin/$SRC_BRANCH"
    git -C "$WT_PATH" fetch origin "$SRC_BRANCH" 2>&1 | sed 's/^/    /' || true
    BEHIND=$(git -C "$WT_PATH" rev-list --count "HEAD..origin/$SRC_BRANCH" 2>/dev/null || echo 0)
    [ "$BEHIND" -gt 0 ] && yellow "    worktree is $BEHIND commit(s) behind origin/$SRC_BRANCH — review before pushing"
  else
    if ! ensure_clean_tree; then
      FAILED+=("$PR_ID (main repo dirty, can't create worktree)")
      continue
    fi
    if git -C "$REPO" rev-parse --verify "$SRC_BRANCH" >/dev/null 2>&1; then
      git -C "$REPO" worktree add "$WT_PATH" "$SRC_BRANCH" >/dev/null
      green "  worktree created on existing branch $SRC_BRANCH"
    else
      git -C "$REPO" worktree add "$WT_PATH" -b "$SRC_BRANCH" "origin/$SRC_BRANCH" >/dev/null
      green "  worktree created from origin/$SRC_BRANCH"
    fi
  fi
  BASE_SHA=$(git -C "$WT_PATH" rev-parse HEAD)
  HAS_WORKTREE+=("$PR_ID")

  # 2. trust-dialog pre-accept (idempotent jq edit of ~/.claude.json)
  ensure_trust_dialog_accepted "$WT_PATH"

  # 3. Initialize .notes/state.json (idempotent).
  init_pr_notes "$PR_ID"
  STATE_FILE=$(pr_state_file "$PR_ID")
  CREATED=$(now_iso)
  if [ ! -f "$STATE_FILE" ]; then
    jq -n --arg pid "$PR_ID" \
          --arg branch "$SRC_BRANCH" \
          --arg url "$PR_URL" \
          --arg ticket "$TICKET" \
          --arg wt "$WT_PATH" \
          --arg sha "$BASE_SHA" \
          --arg ts "$CREATED" \
          --arg bid "$BATCH_ID" \
        '{pr_id:$pid, pr_url:$url, ticket_id:$ticket,
          source_branch:$branch, target_branch:"master",
          worktree_path:$wt, head_sha_at_triage:$sha,
          phase:0, phase_name:"fresh",
          batch_id:$bid, launched_at:$ts,
          open_threads_total:0, addressed:0,
          awaiting_human:false,
          open_threads:[],
          resolved_threads:[],
          decisions:[]}' > "$STATE_FILE"
    green "  .notes/state.json initialized (phase 0)"
  else
    TMP=$(mktemp)
    jq --arg wt "$WT_PATH" --arg sha "$BASE_SHA" --arg ts "$CREATED" \
       '. + {worktree_path: $wt, launched_at: $ts} |
        if (.head_sha_at_triage // "") == "" then .head_sha_at_triage = $sha else . end' \
       "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
    green "  .notes/state.json refreshed (worktree_path)"
  fi

  LAUNCHED+=("$PR_ID")
done

# ── Cursor workspace file ─────────────────────────────────────────────────────
# Plain multi-root workspace. The launcher fires URIs from bash after
# spawning Cursor (below) instead of using tasks.json, so timing is
# deterministic. Leading-space-before-slash workaround: extension drops
# prompts starting with `/`, claude trims the space on submit.
WORKSPACE_FILE=""
if [ "${#HAS_WORKTREE[@]}" -gt 0 ]; then
  WORKSPACE_FILE="$BATCH_DIR/batch.code-workspace"
  if [ "$DRY_RUN" -eq 0 ]; then
    FOLDERS_JSON=$(
      for p in "${HAS_WORKTREE[@]}"; do
        n="${p#PR-}"
        jq -n --arg name "$p" --arg path "$(worktree_parent)/${REPO_BASENAME}-pr-${n}" \
          '{name: $name, path: $path}'
      done | jq -s .
    )
    jq -n --argjson folders "$FOLDERS_JSON" '
      {
        folders: $folders,
        settings: {
          "files.exclude": {"**/__pycache__": true, "**/.ipynb_checkpoints": true}
        }
      }' > "$WORKSPACE_FILE"
  fi
fi

# ── spawn Cursor on the batch workspace + fire one chat tab per PR ──────────
if [ "$DRY_RUN" -eq 0 ] && [ "${#LAUNCHED[@]}" -gt 0 ] && [ -n "$WORKSPACE_FILE" ]; then
  if command -v cursor >/dev/null 2>&1; then
    setsid -f cursor "$WORKSPACE_FILE" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    sleep 5
    green "Cursor spawned on $WORKSPACE_FILE"
    for p in "${HAS_WORKTREE[@]}"; do
      u=$(printf ' /data-engineer-plugin:fix-pr %s' "$p" | jq -sRr @uri)
      cursor --open-url "vscode://anthropic.claude-code/open?prompt=$u" >/dev/null 2>&1 \
        && green "  chat tab fired for $p" \
        || yellow "  chat tab fire failed for $p"
      sleep 5
    done
    green "Done — hit Enter in each chat tab to submit (URI handler doesn't auto-submit)"
  else
    yellow "cursor CLI not on PATH — open the workspace manually:"
    yellow "  $WORKSPACE_FILE"
  fi
elif [ "$DRY_RUN" -eq 1 ] && [ "${#LAUNCHED[@]}" -gt 0 ]; then
  cyan "── would spawn cursor (dry-run) ──"
  echo "  cursor $WORKSPACE_FILE"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
cyan "── Summary ──"
echo "  Launched: ${#LAUNCHED[@]}   ${LAUNCHED[*]:-}"
echo "  Skipped:  ${#SKIPPED[@]}   ${SKIPPED[*]:-}"
echo "  Failed:   ${#FAILED[@]}   ${FAILED[*]:-}"
echo

if [ -n "$WORKSPACE_FILE" ]; then
  echo
  cyan "Edit in Cursor (or any VS Code-compatible editor):"
  if command -v cursor >/dev/null 2>&1; then
    echo "    cursor $WORKSPACE_FILE     # all ${#HAS_WORKTREE[@]} PR(s) in one window"
  else
    yellow "  cursor CLI not on PATH:"
    echo "    $WORKSPACE_FILE"
  fi
fi

[ "${#FAILED[@]}" -gt 0 ] && exit 1 || exit 0
