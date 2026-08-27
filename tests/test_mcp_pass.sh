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

# --- a stdio row names a package, not a way of starting it ---
# The runner is already stripped; the directory a binary was installed into and
# the version it resolved at are no more the server's identity than `npx` is.
assert_eq "a global binary is the package it runs" \
  "$(mcp_stdio_identity /Users/x/.npm/packages/bin/devtools-mcp)" "devtools-mcp"
assert_eq "so is a versioned package spec" \
  "$(mcp_stdio_identity devtools-mcp@1.2.3)" "devtools-mcp"
assert_eq "a scope is not a version" \
  "$(mcp_stdio_identity @acme/devtools-mcp)" "@acme/devtools-mcp"
assert_eq "and a scoped spec still loses only the version" \
  "$(mcp_stdio_identity @acme/devtools-mcp@2.0.0)" "@acme/devtools-mcp"

assert_eq "@latest is satisfied by the installed binary" \
  "$(mcp_stdio_matches 'devtools-mcp@latest' '/usr/local/bin/devtools-mcp' && echo yes)" "yes"
assert_eq "and by any version of the package" \
  "$(mcp_stdio_matches 'devtools-mcp@latest' 'devtools-mcp@0.4.1' && echo yes)" "yes"
assert_eq "but never by a different package" \
  "$(mcp_stdio_matches 'devtools-mcp@latest' '/usr/local/bin/other-mcp' || echo no)" "no"
# A row that pins a version means it: that is the only reason to write one.
assert_eq "a pinned row rejects another version" \
  "$(mcp_stdio_matches 'devtools-mcp@1.2.3' 'devtools-mcp@2.0.0' || echo no)" "no"
assert_eq "a pinned row rejects an unversioned binary" \
  "$(mcp_stdio_matches 'devtools-mcp@1.2.3' '/usr/local/bin/devtools-mcp' || echo no)" "no"
assert_eq "a pinned row accepts itself" \
  "$(mcp_stdio_matches 'devtools-mcp@1.2.3' 'devtools-mcp@1.2.3' && echo yes)" "yes"

# So a host already running the package is left alone, not rewritten.
sandbox_set_mcp claude-code devtools stdio /opt/homebrew/bin/devtools-mcp
agent_mcp_invalidate
out=$(mcp_converge 2>&1)
assert_eq "an installed binary is not rewritten" "$(grep -c '^~' <<< "$out")" "0"
out=$( { verify_mcp; } 2>&1 )
assert_absent "and verification is satisfied by it" "$out" "points elsewhere"
out=$(mcp_report_variants 2>&1)
assert_contains "what it actually runs is named" "$out" \
  "claude-code: 'devtools' runs /opt/homebrew/bin/devtools-mcp"

# A different package under the declared name is still the collision.
sandbox_set_mcp claude-code devtools stdio /opt/homebrew/bin/impostor-mcp
agent_mcp_invalidate
out=$( { verify_mcp; } 2>&1 )
assert_contains "a different package is rejected" "$out" "'devtools' in claude-code points elsewhere"
mcp_converge >/dev/null 2>&1
agent_mcp_invalidate
assert_eq "and repaired to the declared package" \
  "$(agent_mcp_target claude-code devtools)" "$(printf 'stdio\tdevtools-mcp@latest\ttrue')"

# --- a second name for a declared endpoint ---
sandbox_set_mcp claude-code docs-alias remote https://docs.example/mcp
agent_mcp_invalidate
assert_eq "the duplicate is found" "$(mcp_duplicates claude-code)" \
  "$(printf 'docs-alias\thttps://docs.example/mcp\tdocs')"
out=$(mcp_report_undeclared 2>&1)
assert_contains "it is called out, not just listed" "$out" "is a second name for"
assert_absent   "and not listed twice" "$out" "'docs-alias' configured but not declared"

PRUNE_DUPLICATE_MCP="" mcp_prune_duplicates >/dev/null 2>&1
agent_mcp_invalidate
assert_contains "nothing is removed without the flag" "$(agent_mcp_names claude-code)" "docs-alias"

out=$(PRUNE_DUPLICATE_MCP=1 mcp_prune_duplicates 2>&1)
assert_contains "with the flag it is removed" "$out" "removing 'docs-alias'"
agent_mcp_invalidate
assert_absent   "the duplicate is gone"          "$(agent_mcp_names claude-code)" "docs-alias"
assert_contains "the row it duplicated survives" "$(agent_mcp_names claude-code)" "docs"

# `add-mcp remove` matches on a substring of the server name and -y accepts
# every match, so removing 'doc' would take the declared 'docs' with it.
sandbox_set_mcp claude-code doc remote https://docs.example/mcp
agent_mcp_invalidate
out=$(PRUNE_DUPLICATE_MCP=1 mcp_prune_duplicates 2>&1)
assert_contains "a substring collision is refused, not risked" "$out" \
  "leaving 'doc' — add-mcp removes on a substring match"
agent_mcp_invalidate
assert_contains "so the declared server it would have taken survives" \
  "$(agent_mcp_names claude-code)" "docs"
assert_contains "and the duplicate is left to remove by hand" \
  "$(agent_mcp_names claude-code | grep -qxF doc && echo present)" "present"
sandbox_del_mcp claude-code doc

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
