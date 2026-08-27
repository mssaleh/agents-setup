#!/usr/bin/env bash
# The MCP pass installs a server into every declared agent, and only where absent.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_mcp_pass
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

root=$(sandbox_new); sandbox_env "$root"
trap 'sandbox_rm "$root"' EXIT

export MANIFEST_DIR="$root/manifests"; mkdir -p "$MANIFEST_DIR"
printf 'acme/pack\talpha\tselect\n' > "$MANIFEST_DIR/skills.tsv"
{ printf 'devtools\tstdio\tdevtools-mcp@latest\tclaude-code,codex,opencode\n'
  printf 'docs\thttp\thttps://docs.example/mcp\tclaude-code,opencode\n'
} > "$MANIFEST_DIR/mcp.tsv"
printf "claude-code\twidgets\tacme/widgets\twidget\n" > "$MANIFEST_DIR/plugins.tsv"

. "$REPO_DIR/lib/log.sh"; . "$REPO_DIR/lib/manifest.sh"; . "$REPO_DIR/lib/agentcfg.sh"
. "$REPO_DIR/lib/mcp.sh"; . "$REPO_DIR/lib/plugins.sh"; . "$REPO_DIR/lib/verify.sh"

out=$(mcp_converge 2>&1)
assert_contains "installs devtools into all three" "$out" "installing devtools into claude-code,codex,opencode"
assert_eq "claude has both servers"   "$(agent_mcp_names claude-code | tr '\n' ' ')" "devtools docs "
assert_eq "codex has only devtools"   "$(agent_mcp_names codex       | tr '\n' ' ')" "devtools "
assert_eq "opencode has both"         "$(agent_mcp_names opencode    | tr '\n' ' ')" "devtools docs "

# Second run must write nothing: the manifest is checked against the agent config.
# Deltas are counted from the output, not the DELTAS variable: a command
# substitution runs in a subshell, so the caller's counter never moves.
out=$(mcp_converge 2>&1)
assert_eq "second run makes no changes" "$(grep -c '^~' <<< "$out")" "0"
assert_contains "second run reports presence" "$out" "docs correct in claude-code,opencode"

# One agent losing a server is repaired without touching the others.
sandbox_del_mcp codex devtools
agent_mcp_invalidate
out=$(mcp_converge 2>&1)
assert_contains "repairs only the agent that drifted" "$out" "installing devtools into codex"
assert_eq "exactly one change" "$(grep -c '^~' <<< "$out")" "1"

# A project-scoped Claude server is reported, never rewritten.
sandbox_set_project_mcp /tmp/proj stray http https://x
agent_mcp_invalidate
out=$(mcp_report_project_scope 2>&1)
assert_contains "names the project-only server" "$out" "'stray' exists only under /tmp/proj"
assert_eq "project config untouched" "$(claude_project_mcp)" "$(printf 'stray\t/tmp/proj')"

# An undeclared server is reported, not removed: Codex's node_repl is injected
# by the ChatGPT desktop app and removing it breaks the in-app browser.
sandbox_set_mcp codex node_repl stdio node-repl-pkg
agent_mcp_invalidate
out=$(mcp_report_undeclared 2>&1)
assert_contains "reports the undeclared server" "$out" "codex: 'node_repl' configured but not declared"
assert_contains "node_repl survives" "$(agent_mcp_names codex)" "node_repl"

# --- the name-collision defect this repo exists to prevent ---
# A server that kept its name while its target was overwritten must be repaired,
# and must never be reported as satisfied.
sandbox_set_mcp claude-code docs remote https://WRONG.example/mcp
agent_mcp_invalidate
out=$( { verify_mcp; } 2>&1 )
assert_contains "verify rejects a name pointing elsewhere" "$out" "'docs' in claude-code points elsewhere"
out=$(mcp_converge 2>&1)
assert_contains "converge warns about the mismatch" "$out" "does not match the manifest"
assert_contains "converge reinstalls the wrong one" "$out" "installing docs into claude-code"
assert_eq "target is repaired" "$(agent_mcp_target claude-code docs)" "$(printf 'remote\thttps://docs.example/mcp\ttrue')"
out=$( { verify_mcp; } 2>&1 )
assert_absent "verify is satisfied after repair" "$out" "points elsewhere"

# A stdio row is matched on the package, not on the npx runner in front of it.
assert_eq "stdio target normalises past npx" "$(agent_mcp_target codex devtools)" \
  "$(printf 'stdio\tdevtools-mcp@latest\ttrue')"

# --- a server present with the right URL but switched off is not satisfied ---
sandbox_set_mcp codex devtools stdio devtools-mcp@latest
# awk into a temporary file, because BSD sed needs an argument after -i and
# GNU sed refuses one.
awk '{ print }
     /^args = \[ "-y", "devtools-mcp@latest" \]$/ { print "enabled = false" }' \
  "$CODEX_HOME/config.toml" > "$CODEX_HOME/config.toml.new"
mv "$CODEX_HOME/config.toml.new" "$CODEX_HOME/config.toml"
agent_mcp_invalidate
out=$( { verify_mcp; } 2>&1 )
assert_contains "verify rejects a disabled server" "$out" "codex → disabled"
out=$(mcp_converge 2>&1)
assert_contains "converge reinstalls a disabled server" "$out" "installing devtools into codex"
agent_mcp_invalidate
out=$( { verify_mcp; } 2>&1 )
assert_absent "verify is satisfied once it is enabled" "$out" "disabled"

# A settled row has nothing to say. This is where the three lists in
# mcp_row_state are all empty at once, and bash 3.2 — the bash macOS ships —
# calls an empty array unbound under `set -u`, so an array here would print
# three errors per row on every macOS run while the value stayed correct.
err=$( { mcp_converge >/dev/null; } 2>&1 )
assert_eq "a converged mcp pass writes nothing to stderr" "$err" ""

# Plugins: install what is listed, report what is not, never uninstall.
out=$(plugins_converge 2>&1)
assert_contains "registers the marketplace" "$out" "registering marketplace widgets"
assert_contains "installs the plugin" "$out" "installing plugin widget@widgets"
out=$(plugins_converge 2>&1)
assert_eq "plugins converge is idempotent" "$(grep -c '^~' <<< "$out")" "0"

sandbox_add_plugin 'bloat@somewhere' 
out=$(plugins_report_undeclared 2>&1)
assert_contains "reports the undeclared plugin" "$out" "'bloat@somewhere' installed but not declared"
assert_contains "undeclared plugin is not uninstalled" "$(claude_installed_plugins)" "bloat@somewhere"

out=$( { verify_mcp; verify_plugins; } 2>&1 )
assert_absent "verification finds no problems" "$out" "✗"

test_summary
