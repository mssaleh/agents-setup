#!/usr/bin/env bash
# The piped one-liner fetches its own payload and then behaves like a clone.
#
# Piped to bash the script arrives on stdin, so $0 is "bash", BASH_SOURCE is
# empty, and there are no manifests beside it. Everything below runs that way.
# The archive is served over file://, so no test here reaches the network.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_bootstrap
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

root=$(sandbox_new); sandbox_env "$root"
trap 'sandbox_rm "$root"' EXIT

# The payload archive has one top-level directory, the shape GitHub's
# /archive/refs/heads/main.tar.gz has and --strip-components=1 expects.
src="$root/payload-src"; mkdir -p "$src"
cp -R "$REPO_DIR" "$src/agents-setup"
rm -rf "$src/agents-setup/.git"
tar -czf "$root/payload.tar.gz" -C "$src" agents-setup
export REPO_ARCHIVE_URL="file://$root/payload.tar.gz"

# Its own TMPDIR, so the payload directory can be counted before and after.
export TMPDIR="$root/tmp"; mkdir -p "$TMPDIR"

export MANIFEST_DIR="$root/manifests"; mkdir -p "$MANIFEST_DIR"
printf 'acme/pack\talpha,beta\tselect\n' > "$MANIFEST_DIR/skills.tsv"
printf 'devtools\tstdio\tdevtools-mcp@latest\tclaude-code,codex\n' > "$MANIFEST_DIR/mcp.tsv"
printf 'claude-code\twidgets\tacme/widgets\twidget\n' > "$MANIFEST_DIR/plugins.tsv"

. "$REPO_DIR/lib/log.sh"; . "$REPO_DIR/lib/manifest.sh"
. "$REPO_DIR/lib/agentcfg.sh"; . "$REPO_DIR/lib/skills.sh"

# piped <args…> — hand the script to bash on stdin, exactly as curl does.
piped() { bash -s -- "$@" < "$REPO_DIR/sync.sh" 2>&1; }

# --- the help text comes from the payload, not from BASH_SOURCE ---
out=$(piped --help); status=$?
assert_eq       "piped --help exits zero"      "$status" "0"
assert_contains "piped --help lists the flags" "$out" "--prune-plugin-cache"
assert_contains "piped --help shows the one-liner" "$out" "| bash"

# --- a piped run converges the host the same way a clone does ---
out=$(piped); status=$?
assert_contains "the payload is announced" "$out" "fetching temporary payload from file://"
assert_eq       "piped run exits clean"    "$status" "0"
# Every pass has to run: a child that read the script's stdin would take the
# rest of it with it, and the run would stop wherever that happened.
assert_contains "skills pass ran"  "$out" "skills: store, prune, mirror"
assert_contains "mcp pass ran"     "$out" "mcp: servers into every agent"
assert_contains "plugins pass ran" "$out" "plugins: allowlist only"
assert_contains "verify pass ran"  "$out" "verify: read back"
assert_eq "the store is filled" "$(store_skill_names | tr '\n' ' ')" "alpha beta "
agent_mcp_invalidate
assert_eq "the servers are installed" "$(agent_mcp_names codex | tr '\n' ' ')" "devtools "

# --- and it is idempotent through the pipe too ---
out=$(piped)
assert_contains "a second piped run converges" "$out" "converged — nothing to change"
assert_eq "a second piped run applies no deltas" "$(grep -c '^~' <<< "$out")" "0"

# --- the refresh is the one child not inside a redirected loop ---
# Everywhere else stdin is already the loop's input; here it is the script
# still being read from the pipe, so an unclosed descriptor takes the rest of
# the run with it and the summary never prints.
out=$(piped --only skills --update)
assert_contains "--update through the pipe reaches the refresh" "$out" "refreshing every installed skill"
assert_contains "--update through the pipe runs to the end"     "$out" "── summary ──"

# --- the payload is temporary ---
assert_eq "no payload survives the run" \
  "$(find "$TMPDIR" -maxdepth 1 -name 'agents-setup.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- an unreachable payload fails loudly rather than running on nothing ---
out=$(REPO_ARCHIVE_URL="file://$root/absent.tar.gz" piped --only verify); status=$?
assert_eq       "a missing payload exits non-zero" "$status" "1"
assert_contains "a missing payload says so"        "$out" "could not download the payload"

# --- run from the checkout, nothing is fetched ---
out=$("$REPO_DIR/sync.sh" --only verify 2>&1)
assert_absent "a checkout run fetches no payload" "$out" "fetching temporary payload"

test_summary
