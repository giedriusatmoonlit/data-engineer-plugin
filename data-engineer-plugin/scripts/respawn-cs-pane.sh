#!/usr/bin/env bash
# data-engineer-plugin · respawn-cs-pane.sh
#
# Re-create the tmux session for a cs-work instance whose pane died,
# without touching the cs state.json entry. Used when:
#   - The spawned claude crashed (hit a hook error, segfault, etc.)
#   - You manually quit cs (q) and want to come back to the same pane
#   - tmux was killed but cs state survived
#
# Looks up worktree_path + branch from ~/.claude-squad/state.json,
# spawns a new tmux session with full env propagation, waits for the
# input prompt (dismissing any MCP / folder-trust modals along the way),
# and queues the right slash command based on the title prefix:
#   PR-NNNN  → /data-engineer-plugin:fix-pr PR-NNNN
#   DAT-NNN  → /api-scraper:make-scraper DAT-NNN
#   anything else → no slash command, just open the pane
#
# Usage:
#   respawn-cs-pane.sh <TITLE>             # respawn one
#   respawn-cs-pane.sh --all-dead          # respawn every dead one
#   respawn-cs-pane.sh --dry-run [...]     # show what would happen
#
# Exits 0 on success, 1 on any per-pane failure.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/_env.sh"
require_cmd jq tmux

CS_STATE="$HOME/.claude-squad/state.json"
[ -f "$CS_STATE" ] || die "No cs state.json at $CS_STATE"

CLAUDE_CONFIG_DIR_FWD="${CLAUDE_CONFIG_DIR:-$HOME/.claude-work}"
CLAUDE_BIN=$(jq -r '.default_program // "claude"' "$HOME/.claude-squad/config.json" 2>/dev/null || echo "claude")

DRY_RUN=0
TARGETS=()
ALL_DEAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --all-dead) ALL_DEAD=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  TARGETS+=("$1"); shift ;;
  esac
done

# If --all-dead: enumerate cs titles whose claudesquad_<title> tmux session is gone.
if [ "$ALL_DEAD" -eq 1 ]; then
  if [ "${#TARGETS[@]}" -gt 0 ]; then
    die "--all-dead is exclusive with explicit titles"
  fi
  ALIVE=$(tmux list-sessions -F '#S' 2>/dev/null | sort || true)
  while IFS= read -r title; do
    [ -z "$title" ] && continue
    expected="claudesquad_$title"
    if ! echo "$ALIVE" | grep -qx "$expected"; then
      TARGETS+=("$title")
    fi
  done < <(jq -r '.instances[].title // empty' "$CS_STATE")
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    green "No dead cs entries. Everything's alive."
    exit 0
  fi
fi

[ "${#TARGETS[@]}" -eq 0 ] && die "Usage: $0 <TITLE>... | --all-dead | --dry-run"

cyan "Respawning ${#TARGETS[@]} pane(s)…"
[ "$DRY_RUN" -eq 1 ] && yellow "  (dry-run — no tmux changes)"
echo

FAILED=()
RESPAWNED=()
SKIPPED=()

for TITLE in "${TARGETS[@]}"; do
  echo "── $TITLE ──"

  # Pull the cs entry. .title may have a space ("pick uo") — match literal.
  ENTRY=$(jq -c --arg t "$TITLE" '.instances[]? | select(.title == $t)' "$CS_STATE")
  if [ -z "$ENTRY" ]; then
    red "  no cs entry with title '$TITLE'"
    FAILED+=("$TITLE (no cs entry)")
    continue
  fi

  WT_PATH=$(jq -r '.worktree.worktree_path // empty' <<<"$ENTRY")
  BRANCH=$(jq -r '.branch // empty' <<<"$ENTRY")
  TMUX_NAME="claudesquad_${TITLE}"

  if [ -z "$WT_PATH" ]; then
    red "  cs entry has no worktree_path"
    FAILED+=("$TITLE (no worktree_path)")
    continue
  fi
  if [ ! -d "$WT_PATH" ]; then
    red "  worktree gone from disk: $WT_PATH"
    FAILED+=("$TITLE (worktree missing)")
    continue
  fi

  echo "  branch:    $BRANCH"
  echo "  worktree:  $WT_PATH"
  echo "  tmux:      $TMUX_NAME"

  if tmux has-session -t "$TMUX_NAME" 2>/dev/null; then
    yellow "  tmux session already alive — skipping (use tmux kill-session first if you want a fresh boot)"
    SKIPPED+=("$TITLE")
    continue
  fi

  # Pick the slash command based on title prefix.
  SLASH=""
  case "$TITLE" in
    PR-*)   SLASH="/data-engineer-plugin:fix-pr $TITLE" ;;
    DAT-*)  SLASH="/api-scraper:make-scraper $TITLE" ;;
    *)      SLASH="" ;;
  esac
  echo "  command:   ${SLASH:-<none>}"

  if [ "$DRY_RUN" -eq 1 ]; then
    green "  [dry-run] would spawn tmux + queue '$SLASH'"
    RESPAWNED+=("$TITLE")
    continue
  fi

  # Spawn with full env propagation — same vars as launch-pr-batch.sh.
  tmux new-session -d -s "$TMUX_NAME" -c "$WT_PATH" \
    -e "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_FWD" \
    -e "DATA_ENG_WORK_ROOT=${DATA_ENG_WORK_ROOT:-}" \
    -e "DATA_ENG_REPO_ROOT=${DATA_ENG_REPO_ROOT:-}" \
    -e "DATA_ENG_WORKTREE_PARENT=${DATA_ENG_WORKTREE_PARENT:-}" \
    -e "SCRAPER_WORK_ROOT=${SCRAPER_WORK_ROOT:-}" \
    -e "SCRAPER_REPO_ROOT=${SCRAPER_REPO_ROOT:-}" \
    -e "SCRAPER_WORKTREE_PARENT=${SCRAPER_WORKTREE_PARENT:-}" \
    -e "ADO_ORG=${ADO_ORG:-}" \
    -e "ADO_PROJECT=${ADO_PROJECT:-}" \
    "$CLAUDE_BIN"

  tmux set-option -t "$TMUX_NAME" mouse on >/dev/null 2>&1 || true
  tmux set-option -t "$TMUX_NAME" focus-events on >/dev/null 2>&1 || true

  # Poll for input prompt; dismiss MCP / folder-trust modals if up.
  READY=0
  DISMISSED=()
  for _ in $(seq 1 30); do
    sleep 1
    PANE=$(tmux capture-pane -t "$TMUX_NAME" -p -S -40 2>/dev/null || true)
    if echo "$PANE" | grep -q 'New MCP server found in .mcp.json'; then
      tmux send-keys -t "$TMUX_NAME" Enter
      DISMISSED+=("mcp")
      sleep 1
      continue
    fi
    if echo "$PANE" | grep -qiE 'do you trust the files in this folder|trust this folder'; then
      tmux send-keys -t "$TMUX_NAME" Enter
      DISMISSED+=("trust")
      sleep 1
      continue
    fi
    if echo "$PANE" | grep -qE '^❯' && echo "$PANE" | grep -q 'auto mode'; then
      READY=1; break
    fi
  done

  [ "${#DISMISSED[@]}" -gt 0 ] && yellow "  dismissed: ${DISMISSED[*]}"

  if [ "$READY" -eq 0 ]; then
    yellow "  claude didn't reach input prompt in 30s — attach manually:"
    yellow "    tmux attach -t $TMUX_NAME"
    [ -n "$SLASH" ] && yellow "    then type: $SLASH"
  elif [ -n "$SLASH" ]; then
    tmux send-keys -t "$TMUX_NAME" Enter
    sleep 0.3
    tmux send-keys -t "$TMUX_NAME" "$SLASH"
    sleep 0.5
    tmux send-keys -t "$TMUX_NAME" Enter
    green "  respawned + queued: $SLASH"
  else
    green "  respawned (no slash command — unknown title prefix)"
  fi

  RESPAWNED+=("$TITLE")
done

echo
cyan "── Summary ──"
echo "  Respawned: ${#RESPAWNED[@]}   ${RESPAWNED[*]:-}"
echo "  Skipped:   ${#SKIPPED[@]}   ${SKIPPED[*]:-}"
echo "  Failed:    ${#FAILED[@]}   ${FAILED[*]:-}"
echo

if [ "${#RESPAWNED[@]}" -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if pgrep -x claude-squad >/dev/null 2>&1; then
    yellow "cs-work is currently running. Quit (q) and relaunch to refresh the previews:"
    echo "  q  →  cs-work"
  fi
fi

[ "${#FAILED[@]}" -gt 0 ] && exit 1 || exit 0
