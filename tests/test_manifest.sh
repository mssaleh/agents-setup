#!/usr/bin/env bash
# Manifests parse, and each declares what the audit found.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_manifest
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$REPO_DIR/lib/log.sh"
. "$REPO_DIR/lib/manifest.sh"
MANIFEST_DIR="$REPO_DIR/manifests"

assert_eq "skill names are unique" \
  "$(manifest_skill_names | wc -l | tr -d ' ')" \
  "$(manifest_skill_names | sort -u | wc -l | tr -d ' ')"
# The declared set is the required set plus the hand-authored one, with nothing
# in both: a name in both would be fetched and also exempted from being fetched.
assert_eq "declared skills are required plus kept" \
  "$(manifest_skill_names | wc -l | tr -d ' ')" \
  "$(( $(manifest_required_names | wc -l) + $(manifest_kept_names | wc -l) ))"
assert_eq "no name is both required and kept" \
  "$(comm -12 <(manifest_required_names) <(manifest_kept_names) | wc -l | tr -d ' ')" "0"
assert_eq "mcp.tsv declares 6 servers" "$(manifest_mcp_names | wc -l | tr -d ' ')" "6"
assert_eq "plugins.tsv declares 1 plugin" \
  "$(manifest_rows "$MANIFEST_DIR/plugins.tsv" | wc -l | tr -d ' ')" "1"

# A '#' inside a URL must not truncate the row.
tmp=$(mktemp); printf '# comment\n\nname\thttp\thttps://x/y#frag\tcodex\n' > "$tmp"
assert_eq "comments stripped, URL fragment kept" \
  "$(manifest_rows "$tmp" | cut -f3)" "https://x/y#frag"
rm -f "$tmp"

# Every skills row names a mode the installer implements.
bad=$(manifest_rows "$MANIFEST_DIR/skills.tsv" | awk -F'\t' '$3 !~ /^(select|whole|keep)$/')
assert_eq "every skills row uses a known mode" "$bad" ""
# A keep row has nothing to fetch from; a source on one would be read by nobody.
bad=$(manifest_rows "$MANIFEST_DIR/skills.tsv" | awk -F'\t' '$3 == "keep" && $1 != "-"')
assert_eq "every keep row takes source '-'" "$bad" ""

# Every mcp row names a transport the installer implements, and agents we support.
bad=$(manifest_rows "$MANIFEST_DIR/mcp.tsv" | awk -F'\t' '$2 !~ /^(stdio|http|sse)$/')
assert_eq "every mcp row uses a known transport" "$bad" ""
# The agents column is a closed set: an unknown token would be silently dropped
# by add-mcp, and Copilot CLI is deliberately excluded (no binary on this host).
bad=$(manifest_rows "$MANIFEST_DIR/mcp.tsv" | cut -f4 | tr ',' '\n' \
        | grep -vxE 'claude-code|codex|opencode' || true)
assert_eq "mcp agents are all supported targets" "$bad" ""
bad=$(manifest_rows "$MANIFEST_DIR/mcp.tsv" | cut -f4 | tr ',' '\n' | grep -c 'copilot' || true)
assert_eq "copilot is not an mcp target" "$bad" "0"


# --- the shipped manifests are valid ---
out=$(manifest_validate 2>&1); status=$?
assert_eq "the shipped manifests validate" "$status" "0"
assert_absent "no complaints about them" "$out" "✗"

# --- and a manifest that cannot mean what it says is refused up front ---
# Each of these used to pass: the duplicate installed twice and verified twice,
# and the bad mode was only read on the day a skill from that row went missing.
bad=$(mktemp -d); MANIFEST_DIR="$bad"
cp "$REPO_DIR/manifests/mcp.tsv" "$REPO_DIR/manifests/plugins.tsv" "$bad/"
cp "$REPO_DIR/manifests/skills.tsv" "$bad/"

printf 'acme/pack\talpha\tselect\r\n' >> "$bad/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "CRLF is refused" "$out" "CRLF line endings"

cp "$REPO_DIR/manifests/skills.tsv" "$bad/skills.tsv"
printf 'acme/pack\tfind-skills\tselect\n' >> "$bad/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "a skill declared twice is refused" "$out" "declares a skill twice: find-skills"

cp "$REPO_DIR/manifests/skills.tsv" "$bad/skills.tsv"
printf 'acme/pack\talpha\tsometimes\n' >> "$bad/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "an unknown mode is refused" "$out" "mode must be select, whole or keep"

cp "$REPO_DIR/manifests/skills.tsv" "$bad/skills.tsv"
printf 'acme/pack\talpha\tkeep\n' >> "$bad/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "a keep row with a source is refused" "$out" "keep rows take source '-'"

cp "$REPO_DIR/manifests/skills.tsv" "$bad/skills.tsv"
printf 'acme/pack\talpha\n' >> "$bad/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "a missing column is refused" "$out" "needs 3 tab-separated fields"

cp "$REPO_DIR/manifests/skills.tsv" "$bad/skills.tsv"
printf 'dup\thttp\thttps://a.example/mcp\tcodex\n' >> "$bad/mcp.tsv"
printf 'dup\thttp\thttps://b.example/mcp\tcodex\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "a server declared twice is refused" "$out" "declares a server twice: dup"

cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'x\tcarrier-pigeon\thttps://a.example\tcodex\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "an unknown transport is refused" "$out" "transport must be stdio, http or sse"

cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'y\thttp\thttps://a.example\tcodex,telepathy\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "an agent with no installer is refused" "$out" "names agents with no installer"

rm -rf "$bad"
MANIFEST_DIR="$REPO_DIR/manifests"

test_summary
