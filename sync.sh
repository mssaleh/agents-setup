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
#   ./sync.sh --prune-plugin-cache also delete abandoned marketplace clones
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
# curl is not a given: on Debian and Ubuntu it is Priority: optional while wget
# is Priority: standard. macOS ships curl and has no wget until Homebrew
# installs one, so either tool has to do. A file:// URL is copied rather than
# fetched, because curl reads that scheme and wget does not.
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
    # A failed wget leaves an empty file behind, which would then be unpacked
    # as a truncated archive.
    wget -q -O "$dest" "$url" < /dev/null && return 0
    rm -f "$dest"
    return 1
  fi
  printf 'agents-setup: neither curl nor wget is available to fetch the payload\n' >&2
  return 1
}

# ── Bootstrap ────────────────────────────────────────────────────────────
# Piped to bash, $0 is "bash" and BASH_SOURCE is empty, so there are no
# manifests next to the script and the payload has to be fetched. It goes to a
# temporary directory and is deleted on exit; everything this run changes is
# ordinary agent configuration under $HOME, and nothing there points back here.
#
# bash reads this script from the same stdin the one-liner is streaming, so a
# child that reads stdin would eat the rest of it. run() in lib/log.sh closes
# stdin for every child; the commands below run before it exists and close
# their own.
if [[ -z "${BASH_SOURCE[0]:-}" ]] \
  || [[ ! -f "$(dirname "${BASH_SOURCE[0]:-$0}")/manifests/skills.tsv" ]]; then
  _sync_tmp_base=${TMPDIR:-/tmp}; _sync_tmp_base=${_sync_tmp_base%/}
  _sync_payload_root=$(mktemp -d "${_sync_tmp_base}/agents-setup.XXXXXX") || {
    printf 'agents-setup: could not create a temporary directory\n' >&2; exit 1; }
  REPO_DIR="${_sync_payload_root}/payload"
  mkdir -p "$REPO_DIR"

  _sync_cleanup() {
    # The guard keeps an unexpectedly empty or altered variable from turning
    # cleanup into a broad deletion.
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
# The header above is the help text. It is read from the payload rather than
# from BASH_SOURCE, which is empty when the script arrived on stdin.
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$REPO_DIR/sync.sh"; exit 0; }

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
# An awk without POSIX character classes reads [[:space:]] as the set of those
# literal characters, so every config parse here would quietly misread instead
# of failing. macOS 13+ and every supported Linux ship one that has them.
awk 'BEGIN { exit !(" " ~ /[[:space:]]/) }' < /dev/null \
  || fail "this awk lacks POSIX character classes; install gawk or a newer one-true-awk"

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
  # A dry run has fixed nothing, so a problem here is one the plan does not
  # cover — the only part of a dry run that needs a decision.
  warn "$PROBLEMS problem(s) $([[ -n "$DRY_RUN" ]] && printf 'this run would not fix' || printf 'unresolved above')"
  exit 1
fi
[[ -n "$DRY_RUN" ]] && ((DELTAS > 0)) && ok "the plan covers everything verification found"
exit 0
