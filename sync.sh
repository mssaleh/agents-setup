#!/usr/bin/env bash
# sync.sh — converge this host's coding agents onto the manifests.
#
# Idempotent. Every pass compares the manifest against what the agent binary
# actually reads and applies only the difference, so a settled host prints no
# deltas and writes nothing.
#
# Usage:
#   ./sync.sh                      converge everything, then verify
#   ./sync.sh --dry-run            report what would change, change nothing
#   ./sync.sh --only skills        run one pass (skills | mcp | plugins | verify)
#   ./sync.sh --update             also pull upstream changes into installed skills
#   ./sync.sh --prune-plugin-cache also delete abandoned marketplace clones
#
# Environment:
#   AGENTS_HOME   shared skill store root      (default ~/.agents)
#   CLAUDE_HOME   Claude Code state            (default ~/.claude)
#   CODEX_HOME    Codex state                  (default ~/.codex)
#   SKILLS_CLI_VERSION / ADD_MCP_CLI_VERSION   pin the npm CLIs (default latest)

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST_DIR=${MANIFEST_DIR:-$REPO_DIR/manifests}

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/manifest.sh
. "$REPO_DIR/lib/manifest.sh"
# shellcheck source=lib/agentcfg.sh
. "$REPO_DIR/lib/agentcfg.sh"
# shellcheck source=lib/skills.sh
. "$REPO_DIR/lib/skills.sh"
# shellcheck source=lib/mcp.sh
. "$REPO_DIR/lib/mcp.sh"
# shellcheck source=lib/plugins.sh
. "$REPO_DIR/lib/plugins.sh"
# shellcheck source=lib/verify.sh
. "$REPO_DIR/lib/verify.sh"

ONLY=""
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0; }

while (($#)); do
  case "$1" in
    --dry-run)            DRY_RUN=1 ;;
    --update)             UPDATE_SKILLS=1 ;;
    --only)               ONLY="${2:-}"; shift ;;
    --only=*)             ONLY="${1#*=}" ;;
    --prune-plugin-cache) PRUNE_PLUGIN_CACHE=1 ;;
    -h|--help)            usage ;;
    *)                    fail "unknown argument: $1" ;;
  esac
  shift
done
export DRY_RUN=${DRY_RUN:-}
export PRUNE_PLUGIN_CACHE=${PRUNE_PLUGIN_CACHE:-}
export UPDATE_SKILLS=${UPDATE_SKILLS:-}

selected() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

command -v npx >/dev/null 2>&1 || fail "npx is required (node)"
command -v awk >/dev/null 2>&1 || fail "awk is required"

# Nothing runs against a manifest that cannot mean what it says.
manifest_validate || fail "fix the manifests above before running"

[[ -n "$DRY_RUN" ]] && info "dry run — no files will be written"

pass_skills() {
  skills_install
  skills_prune
  [[ -n "$UPDATE_SKILLS" ]] && skills_refresh
  skills_mirror
}

pass_mcp() {
  mcp_converge
  mcp_report_project_scope
  mcp_report_undeclared
}

pass_plugins() {
  plugins_converge
  plugins_report_undeclared
  plugins_report_orphan_cache
}

pass_verify() {
  verify_dry_run_notice
  verify_store
  verify_mirrors
  verify_mcp
  verify_plugins
}

selected skills  && stage "skills: store, prune, mirror"        pass_skills
selected mcp     && stage "mcp: servers into every agent"       pass_mcp
selected plugins && stage "plugins: allowlist only"             pass_plugins
selected verify  && stage "verify: read back what each agent reads" pass_verify

agents_color bold; printf '\n── summary ──\n'; agents_color reset
if ((DELTAS == 0)); then
  ok "converged — nothing to change"
else
  info "$DELTAS change(s) $([[ -n "$DRY_RUN" ]] && printf 'pending' || printf 'applied')"
fi
if ((PROBLEMS > 0)); then
  warn "$PROBLEMS unresolved problem(s) above"
  exit 1
fi
exit 0
