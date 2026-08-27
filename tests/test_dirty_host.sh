#!/usr/bin/env bash
# A host that has never been converged, with everything it accumulated first.
# It has to read as a plan plus what the plan does not cover, and it must not
# delete a skill somebody wrote — the lock is what tells the two apart.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_dirty_host
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

root=$(sandbox_new); sandbox_env "$root"
trap 'sandbox_rm "$root"' EXIT

export MANIFEST_DIR="$root/manifests"; mkdir -p "$MANIFEST_DIR"
{ printf 'acme/pack\talpha,beta\tselect\n'
  printf 'acme/solo/deep\tgamma\twhole\n'
} > "$MANIFEST_DIR/skills.tsv"
{ printf 'devtools\tstdio\tdevtools-mcp@latest\tclaude-code,codex,opencode\n'
  printf 'docs\thttp\thttps://docs.example/mcp\tclaude-code,codex\n'
} > "$MANIFEST_DIR/mcp.tsv"
printf 'claude-code\twidgets\tacme/widgets\twidget\n' > "$MANIFEST_DIR/plugins.tsv"
export SKILLS_STUB_PROVIDES="acme/solo/deep=gamma"

. "$REPO_DIR/lib/log.sh"; . "$REPO_DIR/lib/manifest.sh"
. "$REPO_DIR/lib/agentcfg.sh"; . "$REPO_DIR/lib/skills.sh"

# --- the mess ---
# A payload, optionally recorded in the lock as fetched.
store_add() {
  mkdir -p "$AGENTS_STORE/$1"
  [[ "${3:-}" == bare ]] || printf -- '---\nname: %s\n---\n' "$1" > "$AGENTS_STORE/$1/SKILL.md"
  [[ "${2:-}" == lock ]] && printf '%s\n' "$1" >> "$SANDBOX/state/lock"
  return 0
}
store_add handmade                  # written here: no lock entry
store_add sketches "" bare          # written here, and not a skill yet
store_add leftover      lock        # fetched once, no longer declared
store_add halfwritten   lock bare   # fetched, truncated, no longer declared
printf 'orphan-one\norphan-two\n' >> "$SANDBOX/state/lock"   # payloads long gone
ln -sfn "$AGENTS_STORE/orphan-one" "$CODEX_HOME/skills/orphan-one"
ln -sfn "$AGENTS_STORE/gone" "$CLAUDE_HOME/skills/gone"
# A global binary instead of npx, and a second name for a declared endpoint.
sandbox_set_mcp claude-code devtools stdio /usr/local/bin/devtools-mcp
sandbox_set_mcp claude-code docs-alias remote https://docs.example/mcp
"$SANDBOX/bin/sandbox-render"

# --- the dry run ---
out=$("$REPO_DIR/sync.sh" --dry-run 2>&1); status=$?

assert_contains "plans the missing skills"      "$out" "fetching alpha beta"
assert_contains "plans the stale payload"       "$out" "removing undeclared skill leftover"
assert_contains "plans the truncated payload"   "$out" "removing undeclared skill halfwritten"
assert_contains "plans the orphan lock entry"   "$out" "removing undeclared skill orphan-one"
assert_contains "plans the agents that lack the server" "$out" "installing devtools into codex,opencode"
assert_contains "plans the plugin"              "$out" "installing plugin widget@widgets"

# The row names a package, not an invocation, so the installed binary satisfies
# it and rewriting it into an npx call would be churn.
assert_absent   "a local binary of the declared package is not rewritten" \
  "$out" "installing devtools into claude-code"
assert_contains "and what it actually runs is named" "$out" \
  "'devtools' runs /usr/local/bin/devtools-mcp"

# Nothing the lock never fetched is touched. No manifest row mentions these.
assert_absent   "a skill written here is not pruned"  "$out" "removing undeclared skill handmade"
assert_absent   "a directory written here is not pruned" "$out" "removing undeclared skill sketches"
assert_contains "a skill written here is mirrored"    "$out" "linking handmade"
assert_contains "what was written here is named once" "$out" \
  "not installed from a source, left alone: handmade sketches"

assert_eq "no link is created and removed at once" \
  "$(grep -cE '^~ (claude-code|codex): removing (dangling|stale) link (alpha|beta|gamma|handmade)$' <<< "$out")" "0"

assert_contains "a duplicate endpoint is named" "$out" \
  "'docs-alias' is a second name for https://docs.example/mcp"

# Verification reports only what the plan leaves behind — here, nothing.
assert_absent   "verification does not repeat the plan"        "$out" "declared skills missing"
assert_absent   "verification does not repeat the mirror plan" "$out" "skills missing or dangling"
assert_absent   "verification does not repeat the mcp plan"    "$out" "absent from"
assert_absent   "a directory written here is not a failure"    "$(grep '✗' <<< "$out")" "sketches"
assert_contains "the plan is reported as complete" "$out" "the plan covers everything"
assert_eq       "a complete plan exits zero" "$status" "0"

# --- the real run ---
out=$("$REPO_DIR/sync.sh" 2>&1); status=$?
assert_eq "the run exits clean" "$status" "0"
assert_eq "the store is the manifest plus what was written here" \
  "$(store_skill_names | tr '\n' ' ')" "alpha beta gamma handmade "
assert_eq "and the directory written here is still there" \
  "$([[ -d "$AGENTS_STORE/sketches" ]] && echo yes)" "yes"
assert_link "the skill written here is linked into claude-code" "$CLAUDE_HOME/skills/handmade"
assert_link "the skill written here is linked into codex"       "$CODEX_HOME/skills/handmade"
assert_missing "the truncated payload is gone" "$AGENTS_STORE/halfwritten"
assert_missing "the stale link is gone"        "$CLAUDE_HOME/skills/gone"
agent_mcp_invalidate
assert_eq "the local binary is still the local binary" \
  "$(agent_mcp_target claude-code devtools)" "$(printf 'stdio\t/usr/local/bin/devtools-mcp\ttrue')"
assert_eq "and the agents that lacked it got the package" \
  "$(agent_mcp_target codex devtools)" "$(printf 'stdio\tdevtools-mcp@latest\ttrue')"
assert_contains "the duplicate is left alone without the flag" "$(agent_mcp_names claude-code)" "docs-alias"

# --- and it settles ---
out=$("$REPO_DIR/sync.sh" 2>&1); status=$?
assert_eq       "the second run exits clean" "$status" "0"
assert_contains "the second run converges"   "$out" "converged — nothing to change"
assert_eq "the second run applies no deltas" "$(grep -c '^~' <<< "$out")" "0"
assert_eq "what was written here survived" \
  "$([[ -f "$AGENTS_STORE/handmade/SKILL.md" && -d "$AGENTS_STORE/sketches" ]] && echo yes)" "yes"
assert_contains "the duplicate is still called out" "$out" "is a second name for"
assert_contains "and the flag that clears it is named" "$out" "--prune-duplicate-mcp"

# --- the duplicate, on request ---
out=$("$REPO_DIR/sync.sh" --prune-duplicate-mcp 2>&1); status=$?
assert_eq       "the removing run exits clean" "$status" "0"
assert_contains "it names what it removes" "$out" \
  "claude-code: removing 'docs-alias', a second name for docs's endpoint"
agent_mcp_invalidate
assert_absent   "the duplicate is gone"    "$(agent_mcp_names claude-code)" "docs-alias"
assert_contains "and the row it duplicated is not" "$(agent_mcp_names claude-code)" "docs"
assert_eq "the row it duplicated still resolves" \
  "$(agent_mcp_target claude-code docs)" "$(printf 'remote\thttps://docs.example/mcp\ttrue')"

test_summary
