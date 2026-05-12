#!/usr/bin/env bash
# data-engineer-plugin · launch-pr-batch.sh
#
# Spawns one claude-squad instance per PR in a batch so the user can
# advance them in parallel from cs-work.
#
# For each PR in pr_notes/_batch/<BATCH_ID>/batch.json:
#   1. Resolve source branch + worktree path
#   2. Create the git worktree (origin/<source_branch> → fresh checkout)
#      at <worktree-parent>/<repo>-pr-NNNN/ if it doesn't already exist.
#      If it does, fetch + reset to origin/<source_branch> so the
#      reviewer's latest pushes are picked up.
#   3. Create a tmux session `claudesquad_PR-NNNN` running claude in the
#      worktree, with `/data-engineer-plugin:fix-pr PR-NNNN` queued
#   4. Inject an instance entry into ~/.claude-squad/state.json
#      (is_existing_branch=true so cs attaches rather than recreates)
#
# Usage:
#   launch-pr-batch.sh <BATCH_ID> [--dry-run] [--force] [--only PR-NNNN[,...]]
#
# Exits 0 on success (incl. "all already spawned"). Exits 1 on any
# per-PR failure (other PRs still get tried).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/_env.sh"
require_env DATA_ENG_WORK_ROOT
require_cmd jq tmux git

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

# ── claude-squad locations ────────────────────────────────────────────────────
CS_DIR="$HOME/.claude-squad"
CS_STATE="$CS_DIR/state.json"
CS_CONFIG="$CS_DIR/config.json"
CLAUDE_BIN=$(jq -r '.default_program // "claude"' "$CS_CONFIG" 2>/dev/null || echo "claude")
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

mkdir -p "$CS_DIR"
[ -f "$CS_STATE" ] || echo '{"help_screens_seen":0,"instances":[]}' > "$CS_STATE"

CS_RUNNING=0
pgrep -x claude-squad >/dev/null 2>&1 && CS_RUNNING=1

# ── pick PRs ──────────────────────────────────────────────────────────────────
# batch.json: .prs[] = {pr_id, source_branch, target_branch, head_sha, ticket_id?}
mapfile -t ALL_PRS < <(jq -r '.prs[]?.pr_id // empty' "$BATCH_FILE")
[ "${#ALL_PRS[@]}" -eq 0 ] && die "batch.json has no .prs[]"

declare -a PRS
if [ -n "$ONLY" ]; then
  IFS=',' read -r -a FILTER <<<"$ONLY"
  for p in "${ALL_PRS[@]}"; do
    for f in "${FILTER[@]}"; do
      # Normalize filter form: 1234 / #1234 / PR-1234
      fn=$(canonicalize_pr "$f" 2>/dev/null || echo "$f")
      [ "$p" = "$fn" ] && PRS+=("$p") && break
    done
  done
else
  PRS=("${ALL_PRS[@]}")
fi

[ "${#PRS[@]}" -eq 0 ] && { yellow "No PRs to launch."; exit 0; }

cyan "Launching ${#PRS[@]} PR(s) for batch $BATCH_ID"
[ "$DRY_RUN" -eq 1 ] && yellow "  (DRY RUN — no worktree/tmux/state writes)"
[ "$CS_RUNNING" -eq 1 ] && yellow "  ⚠ claude-squad is currently running; restart cs-work after this to see new instances"
echo

REPO_BASENAME=$(basename "$REPO")
LAUNCHED=()
SKIPPED=()
FAILED=()
declare -a HAS_WORKTREE

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

# Fetch once for the whole batch so the worktree creates land on the
# latest reviewer pushes.
if [ "$DRY_RUN" -eq 0 ]; then
  cyan "Fetching origin before any worktree creation..."
  git -C "$REPO" fetch origin 2>&1 | sed 's/^/  /' || yellow "  fetch failed — proceeding with cached refs"
  echo
fi

# ── per-PR loop ───────────────────────────────────────────────────────────────
for PR_ID in "${PRS[@]}"; do
  echo "── $PR_ID ──"
  PR_NUM="${PR_ID#PR-}"

  # Pull per-PR data from batch.json.
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
  TMUX_NAME="claudesquad_${PR_ID}"

  echo "  source:    $SRC_BRANCH"
  echo "  ticket:    ${TICKET:-<none>}"
  echo "  worktree:  $WT_PATH"
  echo "  tmux:      $TMUX_NAME"

  # --force: tear down existing tmux + cs state entry first.
  if [ "$FORCE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
      tmux kill-session -t "$TMUX_NAME" 2>/dev/null
      yellow "  --force: killed existing tmux $TMUX_NAME"
    fi
    if jq -e --arg t "$PR_ID" '.instances[] | select(.title == $t)' "$CS_STATE" >/dev/null 2>&1; then
      TMP=$(mktemp)
      jq --arg t "$PR_ID" '.instances = [.instances[] | select(.title != $t)]' \
        "$CS_STATE" > "$TMP" && mv "$TMP" "$CS_STATE"
      yellow "  --force: removed cs state entry for $PR_ID"
    fi
  fi

  if jq -e --arg t "$PR_ID" '.instances[] | select(.title == $t)' "$CS_STATE" >/dev/null 2>&1; then
    yellow "  already in cs state — skip (use --force to re-spawn)"
    SKIPPED+=("$PR_ID (already in cs)")
    [ -d "$WT_PATH" ] && HAS_WORKTREE+=("$PR_ID")
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    green "  [dry-run] would create worktree + tmux + cs entry"
    LAUNCHED+=("$PR_ID")
    continue
  fi

  # 1. worktree
  if [ -d "$WT_PATH" ]; then
    yellow "  worktree exists — fetching latest origin/$SRC_BRANCH"
    git -C "$WT_PATH" fetch origin "$SRC_BRANCH" 2>&1 | sed 's/^/    /' || true
    # Don't auto-reset — the developer may have local commits queued.
    # Just surface if behind:
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

  # 2. tmux session
  if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
    yellow "  tmux session exists — reusing"
  else
    # tmux does not inherit arbitrary env vars — every var needed inside
    # the spawned session must be passed with -e KEY=VAL. Without these,
    # session-guard.sh dies on `${DATA_ENG_WORK_ROOT:?...}` and bricks
    # every Bash tool call in the pane.
    tmux new-session -d -s "$TMUX_NAME" -c "$WT_PATH" \
      -e "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_FWD" \
      -e "DATA_ENG_WORK_ROOT=$DATA_ENG_WORK_ROOT" \
      -e "DATA_ENG_REPO_ROOT=${DATA_ENG_REPO_ROOT:-}" \
      -e "DATA_ENG_WORKTREE_PARENT=${DATA_ENG_WORKTREE_PARENT:-}" \
      -e "SCRAPER_REPO_ROOT=${SCRAPER_REPO_ROOT:-}" \
      -e "SCRAPER_WORKTREE_PARENT=${SCRAPER_WORKTREE_PARENT:-}" \
      -e "ADO_ORG=${ADO_ORG:-}" \
      -e "ADO_PROJECT=${ADO_PROJECT:-}" \
      "$CLAUDE_BIN"

    tmux set-option -t "$TMUX_NAME" mouse on >/dev/null 2>&1 || true
    tmux set-option -t "$TMUX_NAME" focus-events on >/dev/null 2>&1 || true

    # Poll for claude's input prompt. Along the way, dismiss any modal
    # prompts that come up in a fresh worktree:
    #   - .mcp.json approval ("New MCP server found")
    #   - folder-trust ("Do you trust the files in this folder")
    #   - "What's new" splash
    # All three are advanced by Enter selecting the first/default option,
    # which for MCP+trust is the "accept for this project" choice.
    READY=0
    DISMISSED=()
    for _ in $(seq 1 30); do
      sleep 1
      PANE=$(tmux capture-pane -t "$TMUX_NAME" -p -S -40 2>/dev/null || true)

      # MCP-server approval modal: Enter accepts option 1 ("use this and all future").
      if echo "$PANE" | grep -q 'New MCP server found in .mcp.json'; then
        tmux send-keys -t "$TMUX_NAME" Enter
        DISMISSED+=("mcp-approval")
        sleep 1
        continue
      fi

      # Folder-trust modal: Enter accepts the default ("yes, I trust").
      if echo "$PANE" | grep -qiE 'do you trust the files in this folder|trust this folder'; then
        tmux send-keys -t "$TMUX_NAME" Enter
        DISMISSED+=("folder-trust")
        sleep 1
        continue
      fi

      # Reached the input prompt — claude is ready for our slash command.
      if echo "$PANE" | grep -qE '^❯' && echo "$PANE" | grep -q 'auto mode'; then
        READY=1
        break
      fi
    done

    if [ "${#DISMISSED[@]}" -gt 0 ]; then
      yellow "  dismissed modal(s): ${DISMISSED[*]}"
    fi

    if [ "$READY" -eq 0 ]; then
      yellow "  tmux session created but claude didn't reach the input prompt in 30s"
      yellow "  attach manually:  tmux attach -t $TMUX_NAME"
      yellow "  then type:        /data-engineer-plugin:fix-pr $PR_ID"
    else
      # Dismiss any residual "What's new" splash with one Enter.
      tmux send-keys -t "$TMUX_NAME" Enter
      sleep 0.3
      tmux send-keys -t "$TMUX_NAME" "/data-engineer-plugin:fix-pr $PR_ID"
      sleep 0.5
      tmux send-keys -t "$TMUX_NAME" Enter
      green "  tmux session created + /data-engineer-plugin:fix-pr queued"
    fi
  fi

  # 3. inject into cs state.json
  CREATED=$(now_iso)
  TMP=$(mktemp)
  jq --arg title "$PR_ID" \
     --arg path "$REPO" \
     --arg branch "$SRC_BRANCH" \
     --arg program "$CLAUDE_BIN" \
     --arg wt_path "$WT_PATH" \
     --arg base_sha "$BASE_SHA" \
     --arg now "$CREATED" \
     '.instances += [{
       title: $title,
       path: $path,
       branch: $branch,
       status: 1,
       height: 0,
       width: 0,
       created_at: $now,
       updated_at: $now,
       auto_yes: false,
       program: $program,
       worktree: {
         repo_path: $path,
         worktree_path: $wt_path,
         session_name: $title,
         branch_name: $branch,
         base_commit_sha: $base_sha,
         is_existing_branch: true
       },
       diff_stats: {added: 0, removed: 0, content: ""}
     }]' "$CS_STATE" > "$TMP" && mv "$TMP" "$CS_STATE"
  green "  cs state.json updated"

  # 4. Initialize .notes/ in the worktree (idempotent) + gitignore it
  #    locally so it's never committed. Write a minimal state.json so
  #    fix-pr's preflight has something to read.
  init_pr_notes "$PR_ID"
  STATE_FILE=$(pr_state_file "$PR_ID")
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
    # State already exists (e.g. re-launch). Just refresh worktree_path
    # in case it moved; preserve everything else (especially head_sha_at_triage
    # and counters).
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
    jq -n --argjson folders "$FOLDERS_JSON" \
      '{folders: $folders, settings: {"files.exclude": {"**/__pycache__": true, "**/.ipynb_checkpoints": true}}}' \
      > "$WORKSPACE_FILE"
  fi
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
cyan "── Summary ──"
echo "  Launched: ${#LAUNCHED[@]}   ${LAUNCHED[*]:-}"
echo "  Skipped:  ${#SKIPPED[@]}   ${SKIPPED[*]:-}"
echo "  Failed:   ${#FAILED[@]}   ${FAILED[*]:-}"
echo

if [ "${#LAUNCHED[@]}" -gt 0 ]; then
  if [ "$CS_RUNNING" -eq 1 ]; then
    yellow "Restart cs-work to see the new instances (it only reads state.json at startup):"
  else
    green "Open cs-work to see the new instances:"
  fi
  echo "    cs-work"
  echo
  echo "  Or attach to a single tmux session directly:"
  for p in "${LAUNCHED[@]}"; do
    echo "    tmux attach -t claudesquad_$p"
  done
fi

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
