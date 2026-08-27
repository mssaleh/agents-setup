#!/usr/bin/env bash
# sync.sh — converge this host's coding agents onto the manifests.
#
# Idempotent. Every pass compares the manifest against what the agent binary
# actually reads and applies only the difference, so a settled host prints no
# deltas and writes nothing.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mssaleh/agents-setup/main/sync.sh | bash
#   curl -fsSL .../sync.sh | bash -s -- --dry-run
#   ./sync.sh                      converge everything, then verify
#   ./sync.sh --dry-run            report what would change, change nothing
#   ./sync.sh --only skills        run one pass (skills | mcp | plugins | verify)
#   ./sync.sh --update             also pull upstream changes into installed skills
#   ./sync.sh --prune-plugin-cache  also delete abandoned marketplace clones
#   ./sync.sh --prune-duplicate-mcp  also remove a second name for a declared endpoint
#
# Environment:
#   AGENTS_HOME   shared skill store root      (default ~/.agents)
#   CLAUDE_HOME   Claude Code state            (default $CLAUDE_CONFIG_DIR or ~/.claude)
#   CODEX_HOME    Codex state                  (default ~/.codex)
#   SKILLS_CLI_VERSION / ADD_MCP_CLI_VERSION   pin the npm CLIs (default latest)
#   REPO_ARCHIVE_URL   override the payload archive the one-liner streams
#   REPO_URL           clone that instead of streaming an archive (needs git)

set -uo pipefail

# ── Fetch the payload for the piped one-liner ────────────────────────────
# Either tool: curl is Priority: optional on Debian while wget is standard, and
# macOS has curl but no wget until Homebrew. file:// is copied — wget cannot
# read that scheme.
_sync_fetch() {
  local url="$1" dest="$2" path
  path=${url#file://}
  if [[ "$url" != "$path" && "$path" == /* ]]; then
    cp -- "$path" "$dest"
    return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest" < /dev/null
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    # A failed wget leaves an empty file to be unpacked as a truncated archive.
    wget -q -O "$dest" "$url" < /dev/null && return 0
    rm -f "$dest"
    return 1
  fi
  printf 'agents-setup: neither curl nor wget is available to fetch the payload\n' >&2
  return 1
}

# ── Bootstrap ────────────────────────────────────────────────────────────
# Piped to bash, BASH_SOURCE is empty and there are no manifests beside the
# script, so the payload is fetched to a temporary directory and deleted on exit.
# These commands run before run() exists, so they close their own stdin — bash is
# still reading the script from it.
if [[ -z "${BASH_SOURCE[0]:-}" ]] \
  || [[ ! -f "$(dirname "${BASH_SOURCE[0]:-$0}")/manifests/skills.tsv" ]]; then
  _sync_tmp_base=${TMPDIR:-/tmp}; _sync_tmp_base=${_sync_tmp_base%/}
  _sync_payload_root=$(mktemp -d "${_sync_tmp_base}/agents-setup.XXXXXX") || {
    printf 'agents-setup: could not create a temporary directory\n' >&2; exit 1; }
  REPO_DIR="${_sync_payload_root}/payload"
  mkdir -p "$REPO_DIR"

  _sync_cleanup() {
    # The guard keeps an altered variable from widening the deletion.
    case "${_sync_payload_root:-}" in
      "${_sync_tmp_base}"/agents-setup.*) rm -rf -- "${_sync_payload_root}" ;;
    esac
  }
  trap '_sync_cleanup' EXIT
  trap 'exit 130' HUP INT TERM

  if [[ -n "${REPO_URL:-}" ]]; then
    command -v git >/dev/null 2>&1 || {
      printf 'agents-setup: REPO_URL needs git; use REPO_ARCHIVE_URL without it\n' >&2; exit 1; }
    printf 'agents-setup: fetching temporary payload from %s\n' "$REPO_URL" >&2
    git clone --depth 1 "$REPO_URL" "$REPO_DIR" < /dev/null || {
      printf 'agents-setup: could not clone the payload\n' >&2; exit 1; }
  else
    REPO_ARCHIVE_URL=${REPO_ARCHIVE_URL:-https://github.com/mssaleh/agents-setup/archive/refs/heads/main.tar.gz}
    _sync_archive="${_sync_payload_root}/payload.tar.gz"
    printf 'agents-setup: fetching temporary payload from %s\n' "$REPO_ARCHIVE_URL" >&2
    _sync_fetch "$REPO_ARCHIVE_URL" "$_sync_archive" || {
      printf 'agents-setup: could not download the payload\n' >&2; exit 1; }
    tar -xzf "$_sync_archive" -C "$REPO_DIR" --strip-components=1 < /dev/null || {
      printf 'agents-setup: could not unpack the payload\n' >&2; exit 1; }
  fi
fi

REPO_DIR=${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}
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
# The header above is the help text, read from the payload: BASH_SOURCE is empty
# when the script arrived on stdin.
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$REPO_DIR/sync.sh"; exit 0; }

while (($#)); do
  case "$1" in
    --dry-run)            DRY_RUN=1 ;;
    --update)             UPDATE_SKILLS=1 ;;
    --only)               ONLY="${2:-}"; shift ;;
    --only=*)             ONLY="${1#*=}" ;;
    --prune-plugin-cache) PRUNE_PLUGIN_CACHE=1 ;;
    --prune-duplicate-mcp) PRUNE_DUPLICATE_MCP=1 ;;
    -h|--help)            usage ;;
    *)                    fail "unknown argument: $1" ;;
  esac
  shift
done
export DRY_RUN=${DRY_RUN:-}
export PRUNE_PLUGIN_CACHE=${PRUNE_PLUGIN_CACHE:-}
export PRUNE_DUPLICATE_MCP=${PRUNE_DUPLICATE_MCP:-}
export UPDATE_SKILLS=${UPDATE_SKILLS:-}

selected() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

command -v npx >/dev/null 2>&1 || fail "npx is required (node)"
command -v awk >/dev/null 2>&1 || fail "awk is required"
# A pre-2019 awk reads [[:space:]] as those literal characters, so every parser
# here would misread rather than fail.
awk 'BEGIN { exit !(" " ~ /[[:space:]]/) }' < /dev/null \
  || fail "this awk lacks POSIX character classes; install gawk or a newer one-true-awk"

manifest_validate || fail "fix the manifests above before running"

[[ -n "$DRY_RUN" ]] && info "dry run — no files will be written"

pass_skills() {
  skills_install
  skills_prune
  [[ -n "$UPDATE_SKILLS" ]] && skills_refresh
  skills_mirror
}

pass_mcp() {
  mcp_prune_duplicates
  mcp_converge
  mcp_report_variants
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
  warn "$PROBLEMS problem(s) $([[ -n "$DRY_RUN" ]] && printf 'this run would not fix' || printf 'unresolved above')"
  exit 1
fi
[[ -n "$DRY_RUN" ]] && ((DELTAS > 0)) && ok "the plan covers everything verification found"
exit 0
