#!/usr/bin/env bash
# A full sync.sh run converges; the second run changes nothing.
#
# This is the property the repo exists to provide, so it is asserted end to end
# through the real entry point rather than by calling the passes directly.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_idempotence
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

root=$(sandbox_new); sandbox_env "$root"
trap 'sandbox_rm "$root"' EXIT

export MANIFEST_DIR="$root/manifests"; mkdir -p "$MANIFEST_DIR"
{ printf 'acme/pack\talpha,beta\tselect\n'
  printf 'acme/solo/deep\tgamma\twhole\n'
} > "$MANIFEST_DIR/skills.tsv"
{ printf 'devtools\tstdio\tdevtools-mcp@latest\tclaude-code,codex,opencode\n'
  printf 'docs\thttp\thttps://docs.example/mcp\tclaude-code,opencode\n'
} > "$MANIFEST_DIR/mcp.tsv"
printf 'claude-code\twidgets\tacme/widgets\twidget\n' > "$MANIFEST_DIR/plugins.tsv"
export SKILLS_STUB_PROVIDES="acme/solo/deep=gamma"

# sync.sh runs as a subprocess; the readers are sourced here so the assertions
# inspect the sandbox the same way verification does.
. "$REPO_DIR/lib/log.sh"; . "$REPO_DIR/lib/manifest.sh"
. "$REPO_DIR/lib/agentcfg.sh"; . "$REPO_DIR/lib/skills.sh"

# --- dry run on an empty host changes nothing but reports the work ---
out=$("$REPO_DIR/sync.sh" --dry-run 2>&1); status=$?
assert_contains "dry run announces itself" "$out" "dry run"
assert_contains "dry run reports pending work" "$out" "pending"
assert_eq "dry run created no skills" "$(store_skill_names | wc -l | tr -d ' ')" "0"
agent_mcp_invalidate
assert_eq "dry run left claude.json alone" "$(agent_mcp_names claude-code | wc -l | tr -d ' ')" "0"

# --- first real run converges ---
out=$("$REPO_DIR/sync.sh" 2>&1); status=$?
assert_eq "first run exits clean" "$status" "0"
assert_eq "store filled" "$(store_skill_names | tr '\n' ' ')" "alpha beta gamma "
assert_link "claude mirror built" "$CLAUDE_HOME/skills/beta"
assert_link "codex mirror built"  "$CODEX_HOME/skills/beta"
# sync.sh writes from a subprocess, so the reader's cache must be dropped first.
agent_mcp_invalidate
assert_eq "claude has both servers" "$(agent_mcp_names claude-code | tr '\n' ' ')" "devtools docs "
assert_eq "codex has devtools"      "$(agent_mcp_names codex       | tr '\n' ' ')" "devtools "
assert_contains "plugin installed"  "$(claude_installed_plugins)" "widget@widgets"

# --- second run is the actual assertion ---
out=$("$REPO_DIR/sync.sh" 2>&1); status=$?
assert_eq "second run exits clean" "$status" "0"
assert_contains "second run reports convergence" "$out" "converged — nothing to change"
assert_eq "second run applied no deltas" "$(grep -c '^~' <<< "$out")" "0"
assert_absent "second run found no problems" "$out" "unresolved problem"

# --- and it stays converged after the drift seen on the live host ---
rm -rf "$AGENTS_STORE/beta"                                  # lock entry, no payload
ln -sfn "$AGENTS_STORE/ghost" "$CODEX_HOME/skills/ghost"     # dangling mirror link
sandbox_del_mcp codex devtools                               # server lost to a rename

out=$("$REPO_DIR/sync.sh" 2>&1); status=$?
assert_eq "repair run exits clean" "$status" "0"
assert_contains "repairs the missing payload" "$out" "fetching beta"
assert_contains "repairs the dangling link"   "$out" "removing dangling link ghost"
assert_contains "repairs the lost server"     "$out" "installing devtools into codex"

out=$("$REPO_DIR/sync.sh" 2>&1)
assert_contains "converged again after repair" "$out" "converged — nothing to change"
assert_eq "no deltas after repair" "$(grep -c '^~' <<< "$out")" "0"

# --- an unsatisfiable manifest must fail loudly, not silently pass ---
printf 'acme/pack\talpha,beta\tselect\nacme/nonexistent\tphantom\tselect\n' > "$MANIFEST_DIR/skills.tsv"
out=$("$REPO_DIR/sync.sh" --only verify 2>&1); status=$?
assert_eq "verify fails on an unmet manifest" "$status" "1"
assert_contains "verify names the missing skill" "$out" "declared skill 'phantom' is missing"

test_summary
