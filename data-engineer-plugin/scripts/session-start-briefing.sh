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

PR_NUM=""
if [[ "$PWD" =~ -pr-([0-9]+)(/|$) ]]; then
  PR_NUM="${BASH_REMATCH[1]}"
fi

# Fallback: maybe Claude was launched from outside the worktree but with
# tmux session name = claudesquad_PR-NNNN. Check that next.
if [ -z "$PR_NUM" ] && [ -n "${TMUX:-}" ]; then
  TMUX_NAME=$(tmux display-message -p '#S' 2>/dev/null || echo "")
  if [[ "$TMUX_NAME" =~ ^claudesquad_PR-([0-9]+)$ ]]; then
    PR_NUM="${BASH_REMATCH[1]}"
  fi
fi

[ -z "$PR_NUM" ] && exit 0

# DATA_ENG_WORK_ROOT must be set for pr-status.sh to work. If it's not,
# print a tiny one-liner so the developer knows why they didn't get the
# usual briefing.
if [ -z "${DATA_ENG_WORK_ROOT:-}" ]; then
  echo "(data-engineer-plugin · DATA_ENG_WORK_ROOT not set — no PR briefing)"
  exit 0
fi

# Invoke the briefing. Capture its exit code but never propagate failure.
bash "$SCRIPT_DIR/pr-status.sh" "PR-$PR_NUM" 2>&1 || true
exit 0
