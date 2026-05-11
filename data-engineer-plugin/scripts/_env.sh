# data-engineer-plugin · shared helpers, sourced by other scripts.
#
# Intentionally NOT executable — `source` it with:
#   . "${CLAUDE_PLUGIN_ROOT:-$HOME/moonlit/data-engineer-plugin/data-engineer-plugin}/scripts/_env.sh"
#
# Provides: color helpers, env-var validation, PR-id validation, PR-path
# resolvers, session-id derivation, die/warn, jq guards. Idempotent —
# sourcing twice is safe.

# ── colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ] || [ "${DE_FORCE_COLOR:-0}" = "1" ]; then
  cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
  green()  { printf '\033[32m%s\033[0m\n' "$*"; }
  yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
  red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
else
  cyan()   { printf '%s\n' "$*"; }
  green()  { printf '%s\n' "$*"; }
  yellow() { printf '%s\n' "$*"; }
  red()    { printf '%s\n' "$*" >&2; }
fi

die()  { red "$*"; exit 1; }
warn() { yellow "$*"; }

# ── env validation ────────────────────────────────────────────────────────────
require_env() {
  local missing=()
  for v in "$@"; do
    [ -z "${!v:-}" ] && missing+=("$v")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "Missing required env var(s): ${missing[*]}.  Run install.sh."
  fi
}

require_cmd() {
  local missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "Missing required tool(s): ${missing[*]}.  See README → Prerequisites."
  fi
}

# ── PR id ─────────────────────────────────────────────────────────────────────
# Input forms: 1234 | PR-1234 | #1234 → canonical "PR-1234"
canonicalize_pr() {
  local raw="$1"
  raw="${raw#\#}"     # strip leading #
  raw="${raw#PR-}"    # strip leading PR-
  raw="${raw#pr-}"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "PR-$raw"
  else
    return 1
  fi
}

is_pr_id() {
  [[ "$1" =~ ^PR-[0-9]+$ ]]
}

require_pr_id() {
  is_pr_id "$1" || die "Not a valid PR id: '$1' (expected PR-NNNN or NNNN or #NNNN)"
}

# Numeric ADO PR id from canonical PR-NNNN.
pr_numeric() { echo "${1#PR-}"; }

# ── DAT id (optional, for cross-linking back to api-scraper context) ──────────
is_dat_id() {
  [[ "$1" =~ ^DAT-[0-9]+$ ]]
}

# Parse a DAT-NNN id from a free-form string (PR title, branch name, body).
# Returns the first match, empty if none.
parse_dat_from() {
  echo "$1" | grep -oE 'DAT-[0-9]+' | head -1 || true
}

# ── PR path resolvers ─────────────────────────────────────────────────────────
# All per-PR state lives INSIDE the worktree at <worktree>/.notes/. The
# path resolvers below derive that location from convention:
#
#   <worktree-parent>/<repo>-pr-NNNN/.notes/{state.json,pr_packet.json,
#                                            comments.md, plan.md, handoff.md}
#
# Why in-tree: notes live next to the code they're about. You see them
# from `ls`, Cursor's file tree, ripgrep. Surviving a `git worktree
# remove` is intentionally NOT a goal here — once a PR is shipped, the
# worktree (and its notes) are disposable. Batch metadata, which spans
# multiple PRs, stays under $DATA_ENG_WORK_ROOT.
#
# Env-var fallback chain for the worktree parent:
#   $DATA_ENG_WORKTREE_PARENT → $SCRAPER_WORKTREE_PARENT → $HOME/worktrees
# For the repo root used as base for the worktree:
#   $DATA_ENG_REPO_ROOT → $SCRAPER_REPO_ROOT

# Lowercase PR id (for worktree paths: {repo}-pr-NNNN).
pr_numeric_lower() { echo "${1#PR-}" | tr '[:upper:]' '[:lower:]'; }

worktree_parent() {
  echo "${DATA_ENG_WORKTREE_PARENT:-${SCRAPER_WORKTREE_PARENT:-$HOME/worktrees}}"
}
repo_root() {
  echo "${DATA_ENG_REPO_ROOT:-${SCRAPER_REPO_ROOT:-}}"
}
worktree_path_for_pr() {
  local pr_id="$1"   # PR-NNNN
  local repo
  repo=$(basename "$(repo_root)")
  [ -z "$repo" ] && die "Cannot resolve worktree path: neither DATA_ENG_REPO_ROOT nor SCRAPER_REPO_ROOT set"
  echo "$(worktree_parent)/${repo}-pr-$(pr_numeric "$pr_id")"
}
# Alias for readability in callers that think in "PR worktree" terms.
pr_worktree()     { worktree_path_for_pr "$1"; }

# Per-PR notes live INSIDE the worktree. These four resolvers compose
# from worktree_path_for_pr.
pr_dir()          { echo "$(worktree_path_for_pr "$1")/.notes"; }
pr_state_file()   { echo "$(pr_dir "$1")/state.json"; }
pr_packet_file()  { echo "$(pr_dir "$1")/pr_packet.json"; }
pr_comments_md()  { echo "$(pr_dir "$1")/comments.md"; }
pr_plan_md()      { echo "$(pr_dir "$1")/plan.md"; }
pr_handoff_md()   { echo "$(pr_dir "$1")/handoff.md"; }

# Batch metadata stays under DATA_ENG_WORK_ROOT — it spans multiple PRs
# and has no natural worktree home.
pr_batch_dir()    { echo "$DATA_ENG_WORK_ROOT/pr_notes/_batch/$1"; }
pr_batch_file()   { echo "$DATA_ENG_WORK_ROOT/pr_notes/_batch/$1/batch.json"; }

# Initialize a worktree's .notes/ dir + gitignore-exclude it from commits.
# Idempotent. Caller has already created the worktree.
init_pr_notes() {
  local pr_id="$1"
  local wt
  wt=$(worktree_path_for_pr "$pr_id")
  [ -d "$wt" ] || die "init_pr_notes: worktree not on disk: $wt"
  mkdir -p "$wt/.notes"
  # Per-worktree gitignore (no global pollution): .git/info/exclude.
  # The exclude file is in the LINKED git dir; resolve it via git itself.
  local gitdir
  # --absolute-git-dir is required: --git-dir alone returns ".git" relative
  # to cwd, which breaks the touch/append calls below.
  gitdir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || gitdir=""
  if [ -n "$gitdir" ]; then
    # Worktree-linked git dirs are under <main>/.git/worktrees/<name>/.
    # info/exclude there shadows the main repo's, scoped to this worktree.
    local exclude="$gitdir/info/exclude"
    mkdir -p "$gitdir/info"
    touch "$exclude"
    if ! grep -qxF '.notes/' "$exclude" 2>/dev/null; then
      printf '\n# data-engineer-plugin per-PR scratchpad\n.notes/\n' >> "$exclude"
    fi
  fi
}

# ── state.json helpers ────────────────────────────────────────────────────────
pr_state_get() {
  local pr_id="$1" path="$2"
  local f
  f=$(pr_state_file "$pr_id")
  [ -f "$f" ] || { echo ""; return; }
  jq -r "$path // empty" "$f" 2>/dev/null
}

# Atomic update. Usage:
#   pr_state_update PR-1234 --argjson phase 2 --arg ts "$(date -u +%FT%TZ)" \
#     '. + {phase: $phase, advanced_at: $ts}'
pr_state_update() {
  local pr_id="$1"; shift
  local f
  f=$(pr_state_file "$pr_id")
  [ -f "$f" ] || die "No state.json for $pr_id; cannot update."
  local expr="${@: -1}"
  local args=("${@:1:$(($#-1))}")
  local tmp
  tmp=$(mktemp)
  jq "${args[@]}" "$expr" "$f" > "$tmp" && mv "$tmp" "$f"
}

# ── session id (matches lock.sh / session-guard.sh) ───────────────────────────
session_id() {
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    echo "$CLAUDE_SESSION_ID"
  elif [ -n "${DE_FAKE_SESSION_ID:-}" ]; then
    echo "$DE_FAKE_SESSION_ID"
  elif [ -n "${TMUX_PANE:-}" ]; then
    echo "tmux$(echo "$TMUX_PANE" | tr -c 'A-Za-z0-9' '_')"
  elif [ -n "${PPID:-}" ] && [ "$PPID" != "1" ]; then
    echo "ppid-$PPID"
  else
    echo "default"
  fi
}

# ── now helpers ───────────────────────────────────────────────────────────────
now_iso()    { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch()  { date -u +%s; }
