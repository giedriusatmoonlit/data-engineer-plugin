#!/usr/bin/env bash
# data-engineer-plugin · SessionStart hook
#
# Fires whenever a Claude session starts (boot / resume / clear) in
# whatever shell Claude was launched in. If that shell's cwd looks like
# a PR worktree (matches `<...>-pr-NNNN`), print the deterministic
# pr-status briefing for that PR.
#
# In any other context — non-PR repo, $HOME, scratch dir — this is a
# silent no-op. The hook costs ~one regex check + nothing.
#
# How we know which PR:
#   1. cwd matches `*-pr-NNNN(/.*)?`     → PR id from the path
#   2. cwd doesn't match                  → no-op, exit 0
#
# This is deliberately stateless. We don't read the session lockfile
# (the lock is acquired by /fix-pr's preflight, AFTER the session has
# already started). We don't read state.json yet either — that's
# pr-status.sh's job and it handles the missing-state case.
#
# Wired in hooks/hooks.json under "SessionStart". Output goes to stdout
# and is shown to the user (and the model) as session context.

set -euo pipefail

# Only fire if both env vars + the script are present. We never want
# the hook to break a session — every failure path exits 0.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Dispatch by worktree shape:
#   *-pr-NNNN   → pr-status.sh PR-NNNN
#   *-dat-NNN   → issue-status.sh DAT-NNN
PR_NUM=""
DAT_NUM=""
if [[ "$PWD" =~ -pr-([0-9]+)(/|$) ]]; then
  PR_NUM="${BASH_REMATCH[1]}"
elif [[ "$PWD" =~ -dat-([0-9]+)(/|$) ]]; then
  DAT_NUM="${BASH_REMATCH[1]}"
fi

# Fallback: mprocs proc name (e.g. each launch-pr-batch.sh proc gets
# MPROCS_NAME = PR-NNNN injected into its env).
if [ -z "$PR_NUM" ] && [ -z "$DAT_NUM" ] && [ -n "${MPROCS_NAME:-}" ]; then
  if [[ "$MPROCS_NAME" =~ ^PR-([0-9]+)$ ]]; then
    PR_NUM="${BASH_REMATCH[1]}"
  elif [[ "$MPROCS_NAME" =~ ^DAT-([0-9]+)$ ]]; then
    DAT_NUM="${BASH_REMATCH[1]}"
  fi
fi

[ -z "$PR_NUM" ] && [ -z "$DAT_NUM" ] && exit 0

if [ -z "${DATA_ENG_WORK_ROOT:-}" ]; then
  echo "(data-engineer-plugin · DATA_ENG_WORK_ROOT not set — no briefing)"
  exit 0
fi

if [ -n "$PR_NUM" ]; then
  bash "$SCRIPT_DIR/pr-status.sh" "PR-$PR_NUM" 2>&1 || true
elif [ -n "$DAT_NUM" ]; then
  bash "$SCRIPT_DIR/issue-status.sh" "DAT-$DAT_NUM" 2>&1 || true
fi
exit 0
