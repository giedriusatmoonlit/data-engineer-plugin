#!/usr/bin/env bash
# data-engineer-plugin · respawn-proc.sh
#
# Replacement for the old respawn-cs-pane.sh. Two failure modes are covered:
#
#   1. Single mprocs process died (claude crashed inside a still-running
#      mprocs window). Tell the running mprocs server to restart the
#      named proc via `mprocs --ctl restart-proc`.
#
#   2. Whole mprocs window/server is gone (kill, reboot, etc.). Spawn a
#      fresh wezterm window with `mprocs --config <batch>/mprocs.yaml`.
#      autostart: true in the yaml means the named proc starts on its own.
#
# Discovery: a per-batch mprocs.yaml is the source of truth. The script
# scans both plugin batch roots for a proc named <TITLE>:
#   - DATA_ENG_WORK_ROOT/pr_notes/_batch/<BATCH>/mprocs.yaml     (PR-NNNN)
#   - SCRAPER_WORK_ROOT/checkpoints/_batch/<BATCH>/mprocs.yaml   (DAT-NNN)
#
# A running batch keeps its allocated TCP port in <BATCH_DIR>/mprocs.port.
# We probe that port; if it answers, send a --ctl restart; else respawn.
#
# Usage:
#   respawn-proc.sh <TITLE> [--dry-run]
#   respawn-proc.sh --all-dead [--dry-run]    # respawn every batch with no live server
#
# Exits 0 on success, 1 on any per-target failure.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/_env.sh"
require_cmd jq mprocs

DRY_RUN=0
ALL_DEAD=0
TARGETS=()
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

# ── batch root discovery ──────────────────────────────────────────────────────
batch_roots() {
  local roots=()
  [ -n "${DATA_ENG_WORK_ROOT:-}" ] && roots+=("$DATA_ENG_WORK_ROOT/pr_notes/_batch")
  [ -n "${SCRAPER_WORK_ROOT:-}" ] && roots+=("$SCRAPER_WORK_ROOT/checkpoints/_batch")
  printf '%s\n' "${roots[@]}"
}

# Find every batch dir (one level under each root) that has an mprocs.yaml.
list_batch_dirs() {
  for root in $(batch_roots); do
    [ -d "$root" ] || continue
    for d in "$root"/*/; do
      [ -f "$d/mprocs.yaml" ] && echo "${d%/}"
    done
  done
}

# Locate the batch dir that contains a proc named <TITLE> in its mprocs.yaml.
batch_dir_for_title() {
  local title="$1"
  for d in $(list_batch_dirs); do
    if grep -qE "^  \"$title\":" "$d/mprocs.yaml" 2>/dev/null; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

# Is the mprocs server for $1 (batch dir) reachable?
mprocs_server_alive() {
  local dir="$1"
  local port_file="$dir/mprocs.port"
  [ -f "$port_file" ] || return 1
  local port
  port=$(cat "$port_file")
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  # Try to open a TCP connection via bash's /dev/tcp. Non-zero exit if dead.
  (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null && exec 3>&- 3<&- && return 0
  return 1
}

# Send a restart-proc ctl. Mprocs identifies procs by index, but the YAML
# accepts a name lookup via {c: restart-proc, proc: "<name>"} in recent
# versions. We try the name form first; on failure, we surface a hint.
mprocs_restart_proc() {
  local dir="$1" title="$2"
  local port
  port=$(cat "$dir/mprocs.port")
  local payload="{c: restart-proc, proc: \"$title\"}"
  if mprocs --server "127.0.0.1:$port" --ctl "$payload" >/dev/null 2>&1; then
    return 0
  fi
  # Fallback ctl shape used by older mprocs builds.
  payload="restart-proc:{name: \"$title\"}"
  mprocs --server "127.0.0.1:$port" --ctl "$payload" >/dev/null 2>&1
}

# Re-launch a whole batch in a new wezterm window.
respawn_batch_window() {
  local dir="$1"
  local yaml="$dir/mprocs.yaml"
  local port
  port=$(mprocs_allocate_port "$dir/mprocs.port")
  local cmd="mprocs --config $(printf %q "$yaml") --server 127.0.0.1:$port"
  if [ "$DRY_RUN" -eq 1 ]; then
    yellow "  [dry-run] wezterm_spawn $dir → $cmd"
    return 0
  fi
  wezterm_spawn "$dir" "$cmd"
}

# ── --all-dead path ───────────────────────────────────────────────────────────
if [ "$ALL_DEAD" -eq 1 ]; then
  [ "${#TARGETS[@]}" -eq 0 ] || die "--all-dead is exclusive with explicit titles"
  cyan "Scanning batch dirs for mprocs windows with no live server..."
  dead_count=0
  for d in $(list_batch_dirs); do
    if mprocs_server_alive "$d"; then
      green "  alive: $d"
    else
      yellow "  dead:  $d"
      respawn_batch_window "$d" || red "    respawn failed for $d"
      dead_count=$((dead_count+1))
    fi
  done
  echo
  cyan "── Summary ──  respawned ${dead_count} batch window(s)"
  exit 0
fi

[ "${#TARGETS[@]}" -eq 0 ] && die "Usage: $0 <TITLE>... | --all-dead | --dry-run"

# ── per-target path ───────────────────────────────────────────────────────────
RESTARTED=()
RESPAWNED=()
FAILED=()

for TITLE in "${TARGETS[@]}"; do
  echo "── $TITLE ──"
  BATCH_DIR=$(batch_dir_for_title "$TITLE" || true)
  if [ -z "$BATCH_DIR" ]; then
    red "  no batch mprocs.yaml lists proc '$TITLE'"
    FAILED+=("$TITLE (not found in any batch)")
    continue
  fi
  echo "  batch:  $BATCH_DIR"

  if mprocs_server_alive "$BATCH_DIR"; then
    PORT=$(cat "$BATCH_DIR/mprocs.port")
    echo "  server: 127.0.0.1:$PORT  (alive)"
    if [ "$DRY_RUN" -eq 1 ]; then
      green "  [dry-run] would --ctl restart-proc → $TITLE"
      RESTARTED+=("$TITLE")
      continue
    fi
    if mprocs_restart_proc "$BATCH_DIR" "$TITLE"; then
      green "  restart-proc sent"
      RESTARTED+=("$TITLE")
    else
      yellow "  restart-proc ctl failed — focus the proc in the mprocs TUI and press 'r' manually"
      yellow "  (alternative: kill the mprocs window, then re-run this script for full respawn)"
      FAILED+=("$TITLE (ctl failed)")
    fi
  else
    yellow "  server: dead — spawning fresh wezterm window for the whole batch"
    if respawn_batch_window "$BATCH_DIR"; then
      green "  wezterm respawn ok (autostart will boot $TITLE)"
      RESPAWNED+=("$TITLE")
    else
      red "  wezterm respawn failed"
      FAILED+=("$TITLE (wezterm failed)")
    fi
  fi
done

echo
cyan "── Summary ──"
echo "  Restarted: ${#RESTARTED[@]}   ${RESTARTED[*]:-}"
echo "  Respawned: ${#RESPAWNED[@]}   ${RESPAWNED[*]:-}"
echo "  Failed:    ${#FAILED[@]}   ${FAILED[*]:-}"

[ "${#FAILED[@]}" -gt 0 ] && exit 1 || exit 0
