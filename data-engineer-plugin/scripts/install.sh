#!/usr/bin/env bash
# data-engineer-plugin · install.sh
#
# Light installer:
#   1. Verifies required tools (jq, git, az, wezterm, mprocs; lazygit + cursor soft)
#   2. Creates $DATA_ENG_WORK_ROOT (default $HOME/.data-engineer-work)
#      with pr_notes/ and pr_notes/_batch/ subdirs
#   3. Prints recommended shell exports if any env vars are missing
#   4. Optional: patch $CLAUDE_CONFIG_DIR/settings.json to install the
#      plugin via the marketplace (idempotent)
#
# Usage:
#   bash install.sh             # interactive
#   bash install.sh --check     # just probe + report; no writes

set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

cyan "── data-engineer-plugin install ──"

# 1. tools
hard_missing=()
soft_missing=()
for c in jq git az wezterm mprocs; do
  command -v "$c" >/dev/null 2>&1 || hard_missing+=("$c")
done
for c in lazygit cursor; do
  command -v "$c" >/dev/null 2>&1 || soft_missing+=("$c")
done
if [ ${#hard_missing[@]} -gt 0 ]; then
  red "Missing required tool(s): ${hard_missing[*]}"
  red "  jq:       https://stedolan.github.io/jq/"
  red "  git:      apt install git"
  red "  az:       https://docs.microsoft.com/cli/azure/install-azure-cli"
  red "  wezterm:  https://wezterm.org/installation.html  (or the latest .deb from"
  red "            https://github.com/wezterm/wezterm/releases)"
  red "  mprocs:   https://github.com/pvolok/mprocs/releases  (drop the binary in ~/.local/bin)"
  exit 1
fi
green "  hard deps: jq git az wezterm mprocs ✓"
if [ ${#soft_missing[@]} -gt 0 ]; then
  yellow "  soft deps missing (multi-repo git UI / Cursor workspace): ${soft_missing[*]}"
  yellow "    lazygit: https://github.com/jesseduffield/lazygit/releases"
  yellow "    cursor:  install the 'cursor' CLI helper from Cursor → Command Palette → 'Shell Command'"
else
  green "  soft deps: lazygit cursor ✓"
fi

# 2. work root
WORK="${DATA_ENG_WORK_ROOT:-$HOME/.data-engineer-work}"
if [ "$CHECK_ONLY" -eq 0 ]; then
  mkdir -p "$WORK/pr_notes/_batch"
  green "  work root: $WORK (created)"
else
  if [ -d "$WORK" ]; then
    green "  work root: $WORK ✓"
  else
    yellow "  work root: $WORK (would be created)"
  fi
fi

# 3. env-var recommendations
echo
cyan "── recommended exports ──"
[ -z "${DATA_ENG_WORK_ROOT:-}" ] && \
  echo "  export DATA_ENG_WORK_ROOT=$WORK"
if [ -z "${DATA_ENG_REPO_ROOT:-}" ] && [ -z "${SCRAPER_REPO_ROOT:-}" ]; then
  yellow "  DATA_ENG_REPO_ROOT not set (and SCRAPER_REPO_ROOT not set either)"
  yellow "  → /address-pr can't resolve a base repo to create worktrees from."
  yellow "  → set one in your shell rc:"
  echo "    export DATA_ENG_REPO_ROOT=\"\$HOME/path/to/your/Databricks\""
fi
if [ -z "${DATA_ENG_WORKTREE_PARENT:-}" ] && [ -z "${SCRAPER_WORKTREE_PARENT:-}" ]; then
  yellow "  DATA_ENG_WORKTREE_PARENT not set (falls back to \$HOME/worktrees)"
  echo "  export DATA_ENG_WORKTREE_PARENT=\"\$HOME/moonlit\"   # or wherever you keep checkouts"
fi
if [ -z "${ADO_ORG:-}" ] || [ -z "${ADO_PROJECT:-}" ]; then
  yellow "  ADO_ORG / ADO_PROJECT not set"
  yellow "  → az calls fall back to 'az devops configure --list' defaults"
  yellow "  → if those aren't set either, /address-pr's preflight will refuse"
  echo "    export ADO_ORG=moonlit-legal-technologies-bv"
  echo "    export ADO_PROJECT=Moonlit"
fi

# 4. az auth probe
echo
cyan "── az auth probe ──"
if az account show >/dev/null 2>&1; then
  green "  az account: $(az account show --query 'user.name' -o tsv 2>/dev/null || echo '?')"
else
  yellow "  az not authenticated. Run:"
  yellow "    az login        # for general Azure"
  yellow "    az devops login # for ADO PRs"
fi

# 5. plugin enable hint
echo
cyan "── plugin enable ──"
echo "  In your master claude session, run:"
echo "    /plugin marketplace add giedriusatmoonlit/data-engineer-plugin"
echo "    /plugin install data-engineer-plugin@data-engineer-plugin"
echo
echo "  Then sanity-check:"
echo "    /reload-plugins"
echo "    /data-engineer-plugin:address-pr --help"

echo
green "Install complete."
