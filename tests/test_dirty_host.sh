#!/usr/bin/env bash
# A host that has never been converged, with everything it accumulated first.
#
# This is the run that has to be readable: a plan, then the short list of things
# the plan does not cover. Verification used to repeat the plan back under ✗ —
# a hundred and thirty-one failures and a non-zero exit on a host where nothing
# was actually wrong — which buried the handful of findings that needed a
# decision.
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
  printf -- '-\thandmade\tkeep\n'          # written here, present on this host
  printf -- '-\telsewhere\tkeep\n'         # written on another machine
} > "$MANIFEST_DIR/skills.tsv"
{ printf 'devtools\tstdio\tdevtools-mcp@latest\tclaude-code,codex,opencode\n'
  printf 'docs\thttp\thttps://docs.example/mcp\tclaude-code,codex\n'
} > "$MANIFEST_DIR/mcp.tsv"
printf 'claude-code\twidgets\tacme/widgets\twidget\n' > "$MANIFEST_DIR/plugins.tsv"
export SKILLS_STUB_PROVIDES="acme/solo/deep=gamma"

. "$REPO_DIR/lib/log.sh"; . "$REPO_DIR/lib/manifest.sh"
. "$REPO_DIR/lib/agentcfg.sh"; . "$REPO_DIR/lib/skills.sh"

# --- the mess ---
# A hand-authored skill: in the store, in no lock, from no source repo.
mkdir -p "$AGENTS_STORE/handmade"
printf -- '---\nname: handmade\n---\n' > "$AGENTS_STORE/handmade/SKILL.md"
# A skill from some earlier experiment, and a truncated payload beside it.
mkdir -p "$AGENTS_STORE/leftover"; printf -- '---\nname: leftover\n---\n' > "$AGENTS_STORE/leftover/SKILL.md"
mkdir -p "$AGENTS_STORE/halfwritten"
# Lock entries whose payloads went years ago.
printf 'orphan-one\norphan-two\n' >> "$SANDBOX/state/lock"
# Links an agent kept after the payload moved.
ln -sfn "$AGENTS_STORE/orphan-one" "$CODEX_HOME/skills/orphan-one"
ln -sfn "$AGENTS_STORE/gone" "$CLAUDE_HOME/skills/gone"
# A declared server installed by hand at a different target, and a second name
# for one the manifest already installs.
sandbox_set_mcp claude-code devtools stdio /usr/local/bin/devtools-mcp
sandbox_set_mcp claude-code docs-alias remote https://docs.example/mcp
"$SANDBOX/bin/sandbox-render"

# --- the dry run ---
out=$("$REPO_DIR/sync.sh" --dry-run 2>&1); status=$?

# What it plans is the whole job.
assert_contains "plans the missing skills"    "$out" "fetching alpha beta"
assert_contains "plans the undeclared skill"  "$out" "removing undeclared skill leftover"
assert_contains "plans the orphan lock entry" "$out" "removing undeclared skill orphan-one"
assert_contains "plans the truncated payload" "$out" "removing undeclared skill halfwritten"
assert_contains "plans the wrong-target server" "$out" "installing devtools into"
assert_contains "plans the plugin"            "$out" "installing plugin widget@widgets"

# A hand-authored skill has no source row that could express it, so without a
# keep row prune deletes it and both agents stop loading it.
assert_absent "the hand-authored skill is not pruned" "$out" "removing undeclared skill handmade"
assert_contains "the hand-authored skill is mirrored" "$out" "linking handmade"
# ...and the one written on another machine is neither fetched nor missed.
assert_absent   "a kept skill absent here is not a failure" "$(grep '✗' <<< "$out")" "elsewhere"
assert_absent   "a kept skill absent here is not fetched"   "$out" "fetching elsewhere"
assert_contains "a kept skill absent here is reported once" "$out" "hand-authored, not on this host: elsewhere"

# Nothing is planned and unplanned in the same run.
assert_eq "no link is created and removed at once" \
  "$(grep -cE '^~ (claude-code|codex): removing (dangling|undeclared) link (alpha|beta|gamma|handmade)$' <<< "$out")" "0"

# A second name for a declared endpoint is called out, not merely listed.
assert_contains "a duplicate endpoint is named" "$out" \
  "'docs-alias' is a second name for https://docs.example/mcp"

# And verification reports only what the plan leaves behind — here, nothing.
assert_absent   "verification does not repeat the plan" "$out" "declared skills missing"
assert_absent   "verification does not repeat the mirror plan" "$out" "skills missing or dangling"
assert_absent   "verification does not repeat the mcp plan" "$out" "absent from"
assert_contains "the plan is reported as complete" "$out" "the plan covers everything"
assert_eq       "a complete plan exits zero" "$status" "0"

# --- the real run ---
out=$("$REPO_DIR/sync.sh" 2>&1); status=$?
assert_eq "the run exits clean" "$status" "0"
assert_eq "the store is exactly the manifest, less what is not on this host" \
  "$(store_skill_names | tr '\n' ' ')" "alpha beta gamma handmade "
assert_link "the hand-authored skill is linked into claude-code" "$CLAUDE_HOME/skills/handmade"
assert_link "the hand-authored skill is linked into codex"       "$CODEX_HOME/skills/handmade"
assert_missing "the truncated payload is gone" "$AGENTS_STORE/halfwritten"
assert_missing "the stale link is gone"        "$CLAUDE_HOME/skills/gone"
agent_mcp_invalidate
assert_eq "the server points where the manifest says" \
  "$(agent_mcp_target claude-code devtools)" "$(printf 'stdio\tdevtools-mcp@latest\ttrue')"
assert_contains "the duplicate is left alone, not removed" "$(agent_mcp_names claude-code)" "docs-alias"

# --- and it settles ---
out=$("$REPO_DIR/sync.sh" 2>&1); status=$?
assert_eq       "the second run exits clean" "$status" "0"
assert_contains "the second run converges"   "$out" "converged — nothing to change"
assert_eq "the second run applies no deltas" "$(grep -c '^~' <<< "$out")" "0"
assert_eq "the hand-authored skill survived" \
  "$([[ -f "$AGENTS_STORE/handmade/SKILL.md" ]] && echo yes)" "yes"
assert_contains "the duplicate is still called out" "$out" "is a second name for"

test_summary
