#!/usr/bin/env bash
# lib/manifest.sh — read the tab-separated manifests under manifests/.
# shellcheck shell=bash

# manifest_rows <file> — emit data rows, dropping comments and blank lines.
# Only a line whose first non-blank character is '#' is a comment, so a '#' may
# appear inside a URL without truncating the row.
manifest_rows() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing manifest: $file"
  grep -vE '^[[:space:]]*(#|$)' "$file"
}

# manifest_field <row> <n> — the nth tab-separated field.
manifest_field() {
  printf '%s' "$1" | cut -f "$2"
}

# manifest_skill_names — every skill name the manifest declares, sorted.
# This is the set the store may hold: anything outside it is pruned.
manifest_skill_names() {
  manifest_rows "$MANIFEST_DIR/skills.tsv" | cut -f2 | tr ',' '\n' \
    | sed 's/[[:space:]]//g' | grep -v '^$' | sort -u
}

# manifest_required_names — the names a source can supply, sorted.
#
# A `keep` row names a skill written by hand: there is nothing to fetch it
# from, and it exists on the machine it was written on rather than all of them.
# So it belongs in the set that survives pruning and gets mirrored, and not in
# the set that is installed or reported missing.
manifest_required_names() {
  manifest_rows "$MANIFEST_DIR/skills.tsv" | awk -F'\t' '$3 != "keep" { print $2 }' \
    | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$' | sort -u
}

# manifest_kept_names — the hand-authored names, sorted.
manifest_kept_names() {
  manifest_rows "$MANIFEST_DIR/skills.tsv" | awk -F'\t' '$3 == "keep" { print $2 }' \
    | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$' | sort -u
}

# manifest_mcp_names — every MCP server name declared, sorted.
manifest_mcp_names() {
  manifest_rows "$MANIFEST_DIR/mcp.tsv" | cut -f1 | sort -u
}

# manifest_mcp_agents <name> — the agent list for one server.
manifest_mcp_agents() {
  manifest_rows "$MANIFEST_DIR/mcp.tsv" | awk -F'\t' -v n="$1" '$1 == n { print $4; exit }'
}

# manifest_validate — refuse to act on a manifest that cannot mean what it says.
#
# Every one of these used to fail late or not at all: a duplicated row installed
# the same server twice and reported it twice; a row whose mode was `select\r`
# was accepted until the day a skill from it went missing, because the mode is
# only read when there is something to fetch; a stray tab or a missing column
# silently shifted every field one to the left.
manifest_validate() {
  local bad problems=0
  local skills="$MANIFEST_DIR/skills.tsv" mcp="$MANIFEST_DIR/mcp.tsv" plugins="$MANIFEST_DIR/plugins.tsv"

  # A CR survives into the last field and compares unequal to everything.
  # No -U: GNU's flag only means anything on MS-DOS, and BSD grep gives the
  # same letter a different job.
  bad=$(grep -l $'\r' "$skills" "$mcp" "$plugins" 2>/dev/null || true)
  [[ -n "$bad" ]] && { problem "manifest has CRLF line endings: $(oneline "$bad")"; problems=1; }

  bad=$(manifest_rows "$skills" | awk -F'\t' 'NF != 3 { print NR": "NF" fields" }')
  [[ -n "$bad" ]] && { problem "skills.tsv needs 3 tab-separated fields: $bad"; problems=1; }
  bad=$(manifest_rows "$mcp" | awk -F'\t' 'NF != 4 { print NR": "NF" fields" }')
  [[ -n "$bad" ]] && { problem "mcp.tsv needs 4 tab-separated fields: $bad"; problems=1; }
  bad=$(manifest_rows "$plugins" | awk -F'\t' 'NF != 4 { print NR": "NF" fields" }')
  [[ -n "$bad" ]] && { problem "plugins.tsv needs 4 tab-separated fields: $bad"; problems=1; }

  bad=$(manifest_rows "$skills" | awk -F'\t' '$3 !~ /^(select|whole|keep)$/ { print $1" ("$3")" }')
  [[ -n "$bad" ]] && { problem "skills.tsv mode must be select, whole or keep: $bad"; problems=1; }
  # A keep row has nothing to fetch from, so a source on it would be read by
  # nobody and would look like the row still installs something.
  bad=$(manifest_rows "$skills" | awk -F'\t' '$3 == "keep" && $1 != "-" { print $1 }')
  [[ -n "$bad" ]] && { problem "skills.tsv keep rows take source '-': $(oneline "$bad")"; problems=1; }
  bad=$(manifest_rows "$mcp" | awk -F'\t' '$2 !~ /^(stdio|http|sse)$/ { print $1" ("$2")" }')
  [[ -n "$bad" ]] && { problem "mcp.tsv transport must be stdio, http or sse: $bad"; problems=1; }

  bad=$(manifest_rows "$mcp" | cut -f4 | tr ',' '\n' | sort -u \
        | grep -vxE 'claude-code|codex|opencode' || true)
  [[ -n "$bad" ]] && { problem "mcp.tsv names agents with no installer: $(oneline "$bad")"; problems=1; }

  # A duplicate is never intentional: the second row is either dead weight or a
  # disagreement with the first, and both read as converged.
  bad=$(manifest_skill_names_raw | sort | uniq -d)
  [[ -n "$bad" ]] && { problem "skills.tsv declares a skill twice: $(oneline "$bad")"; problems=1; }
  bad=$(manifest_rows "$mcp" | cut -f1 | sort | uniq -d)
  [[ -n "$bad" ]] && { problem "mcp.tsv declares a server twice: $(oneline "$bad")"; problems=1; }
  bad=$(manifest_rows "$plugins" | awk -F'\t' '{print $4"@"$2}' | sort | uniq -d)
  [[ -n "$bad" ]] && { problem "plugins.tsv declares a plugin twice: $(oneline "$bad")"; problems=1; }

  ((problems)) && return 1
  return 0
}

# manifest_skill_names_raw — declared names *with* duplicates, for validation.
manifest_skill_names_raw() {
  manifest_rows "$MANIFEST_DIR/skills.tsv" | cut -f2 | tr ',' '\n' \
    | sed 's/[[:space:]]//g' | grep -v '^$'
}
