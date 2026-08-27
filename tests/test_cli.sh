#!/usr/bin/env bash
# The entry point's flags do what they say, and nothing more.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_cli
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

root=$(sandbox_new); sandbox_env "$root"
trap 'sandbox_rm "$root"' EXIT

export MANIFEST_DIR="$root/manifests"; mkdir -p "$MANIFEST_DIR"
printf 'acme/pack\talpha\tselect\n' > "$MANIFEST_DIR/skills.tsv"
printf 'devtools\tstdio\tdevtools-mcp@latest\tclaude-code,codex\n' > "$MANIFEST_DIR/mcp.tsv"
printf 'claude-code\twidgets\tacme/widgets\twidget\n' > "$MANIFEST_DIR/plugins.tsv"

# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/manifest.sh
. "$REPO_DIR/lib/manifest.sh"
# shellcheck source=lib/agentcfg.sh
. "$REPO_DIR/lib/agentcfg.sh"
# shellcheck source=lib/skills.sh
. "$REPO_DIR/lib/skills.sh"

# --- --only runs one pass and leaves the others alone ---
out=$("$REPO_DIR/sync.sh" --only skills 2>&1)
assert_contains "--only skills runs the skills pass" "$out" "skills: store, prune, mirror"
assert_absent   "--only skills skips mcp"            "$out" "mcp: servers into every agent"
assert_absent   "--only skills skips plugins"        "$out" "plugins: allowlist only"
agent_mcp_invalidate
assert_eq "--only skills wrote no MCP config" "$(agent_mcp_names claude-code | wc -l | tr -d ' ')" "0"
assert_eq "--only skills did fill the store"  "$(store_skill_names | tr '\n' ' ')" "alpha "

out=$("$REPO_DIR/sync.sh" --only verify 2>&1)
assert_contains "--only verify runs verification" "$out" "verify: read back"
assert_absent   "--only verify changes nothing"   "$out" "~ "

# --- an unknown flag is refused, not ignored ---
out=$("$REPO_DIR/sync.sh" --nonsense 2>&1); status=$?
assert_eq       "unknown flag exits non-zero" "$status" "1"
assert_contains "unknown flag is named"       "$out" "unknown argument: --nonsense"

# --- --help does not touch the host ---
before=$(find "$root/home" -newer "$root/state/lock" 2>/dev/null | wc -l)
out=$("$REPO_DIR/sync.sh" --help 2>&1); status=$?
assert_eq       "--help exits zero" "$status" "0"
assert_contains "--help lists the flags" "$out" "--prune-plugin-cache"
assert_absent   "--help stops before the code" "$out" "set -uo pipefail"
assert_eq "--help wrote nothing" "$(find "$root/home" -newer "$root/state/lock" 2>/dev/null | wc -l)" "$before"

# --- --update refreshes what is already installed; a plain run does not ---
"$REPO_DIR/sync.sh" --only skills >/dev/null 2>&1
: > "$SANDBOX/calls/npx"
"$REPO_DIR/sync.sh" --only skills >/dev/null 2>&1
assert_absent "a settled run does not call skills update" "$(cat "$SANDBOX/calls/npx")" "update"
assert_absent "a settled run does not re-add"             "$(cat "$SANDBOX/calls/npx")" "add"

: > "$SANDBOX/calls/npx"
out=$("$REPO_DIR/sync.sh" --only skills --update 2>&1)
assert_contains "--update calls upstream update" "$(cat "$SANDBOX/calls/npx")" "update -g -y"
assert_contains "--update reports itself as a change" "$out" "refreshing every installed skill"

# --- --dry-run reports work without doing it ---
rm -rf "$AGENTS_STORE/alpha"
out=$("$REPO_DIR/sync.sh" --dry-run 2>&1); status=$?
assert_contains "dry run says what it is reporting" "$out" "would leave unfixed"
assert_eq "dry run left the store empty" "$(store_skill_names | wc -l | tr -d ' ')" "0"
# Verification must not repeat the plan back as failures.
assert_absent   "dry run does not report what it would fix" "$out" "declared skills missing"
assert_contains "dry run says the plan is complete" "$out" "the plan covers everything"
assert_eq       "a dry run whose plan is complete exits zero" "$status" "0"

# --- ...and still reports what the plan does not cover ---
: > "$AGENTS_STORE/NOTES.md"
out=$("$REPO_DIR/sync.sh" --dry-run 2>&1); status=$?
assert_contains "dry run reports what it cannot fix" "$out" "not skill directories: NOTES.md"
assert_absent   "an incomplete plan does not claim completeness" "$out" "the plan covers everything"
assert_eq       "an incomplete plan exits non-zero" "$status" "1"
rm -f "$AGENTS_STORE/NOTES.md"

# --- a satisfied host exits zero and says so ---
"$REPO_DIR/sync.sh" >/dev/null 2>&1
out=$("$REPO_DIR/sync.sh" 2>&1); status=$?
assert_eq       "converged run exits zero" "$status" "0"
assert_contains "converged run says so"    "$out" "converged — nothing to change"

test_summary
