#!/usr/bin/env bash
# lib/manifest.sh — read the tab-separated manifests under manifests/.
# shellcheck shell=bash

# Only a leading # is a comment, so a URL fragment survives.
manifest_rows() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing manifest: $file"
  grep -vE '^[[:space:]]*(#|$)' "$file"
}

manifest_field() {
  printf '%s' "$1" | cut -f "$2"
}

# Authoritative over what a source installed, and nothing else — store_local_names
# is what decides scope.
manifest_skill_names() {
  manifest_rows "$MANIFEST_DIR/skills.tsv" | cut -f2 | tr ',' '\n' \
    | sed 's/[[:space:]]//g' | grep -v '^$' | sort -u
}

manifest_mcp_names() {
  manifest_rows "$MANIFEST_DIR/mcp.tsv" | cut -f1 | sort -u
}

manifest_mcp_agents() {
  manifest_rows "$MANIFEST_DIR/mcp.tsv" | awk -F'\t' -v n="$1" '$1 == n { print $4; exit }'
}

# Up front, because each of these otherwise fails late or not at all: a bad mode
# is only read when something needs fetching, and a duplicate reads as converged.
manifest_validate() {
  local bad problems=0
  local skills="$MANIFEST_DIR/skills.tsv" mcp="$MANIFEST_DIR/mcp.tsv" plugins="$MANIFEST_DIR/plugins.tsv"

  # A CR survives into the last field. No -U: BSD grep gives it another meaning.
  bad=$(grep -l $'\r' "$skills" "$mcp" "$plugins" 2>/dev/null || true)
  [[ -n "$bad" ]] && { problem "manifest has CRLF line endings: $(oneline "$bad")"; problems=1; }

  bad=$(manifest_rows "$skills" | awk -F'\t' 'NF != 3 { print NR": "NF" fields" }')
  [[ -n "$bad" ]] && { problem "skills.tsv needs 3 tab-separated fields: $bad"; problems=1; }
  bad=$(manifest_rows "$mcp" | awk -F'\t' 'NF != 4 { print NR": "NF" fields" }')
  [[ -n "$bad" ]] && { problem "mcp.tsv needs 4 tab-separated fields: $bad"; problems=1; }
  bad=$(manifest_rows "$plugins" | awk -F'\t' 'NF != 4 { print NR": "NF" fields" }')
  [[ -n "$bad" ]] && { problem "plugins.tsv needs 4 tab-separated fields: $bad"; problems=1; }

  bad=$(manifest_rows "$skills" | awk -F'\t' '$3 != "select" && $3 != "whole" { print $1" ("$3")" }')
  [[ -n "$bad" ]] && { problem "skills.tsv mode must be select or whole: $bad"; problems=1; }
  bad=$(manifest_rows "$mcp" | awk -F'\t' '$2 !~ /^(stdio|http|sse)$/ { print $1" ("$2")" }')
  [[ -n "$bad" ]] && { problem "mcp.tsv transport must be stdio, http or sse: $bad"; problems=1; }

  # Codex has no SSE client: it POSTs to a row's URL whatever the label says,
  # and a GET-only endpoint answers 404 at startup rather than here.
  bad=$(manifest_rows "$mcp" | awk -F'\t' '$2 == "sse" && index("," $4 ",", ",codex,") { print $1 }')
  [[ -n "$bad" ]] && { problem "mcp.tsv sends an sse row to codex, which has no SSE client: $(oneline "$bad")"; problems=1; }

  bad=$(manifest_rows "$mcp" | cut -f4 | tr ',' '\n' | sort -u \
        | grep -vxE 'claude-code|codex|opencode' || true)
  [[ -n "$bad" ]] && { problem "mcp.tsv names agents with no installer: $(oneline "$bad")"; problems=1; }

  bad=$(manifest_skill_names_raw | sort | uniq -d)
  [[ -n "$bad" ]] && { problem "skills.tsv declares a skill twice: $(oneline "$bad")"; problems=1; }
  bad=$(manifest_rows "$mcp" | cut -f1 | sort | uniq -d)
  [[ -n "$bad" ]] && { problem "mcp.tsv declares a server twice: $(oneline "$bad")"; problems=1; }
  bad=$(manifest_rows "$plugins" | awk -F'\t' '{print $4"@"$2}' | sort | uniq -d)
  [[ -n "$bad" ]] && { problem "plugins.tsv declares a plugin twice: $(oneline "$bad")"; problems=1; }

  ((problems)) && return 1
  return 0
}

# With duplicates, for validation.
manifest_skill_names_raw() {
  manifest_rows "$MANIFEST_DIR/skills.tsv" | cut -f2 | tr ',' '\n' \
    | sed 's/[[:space:]]//g' | grep -v '^$'
}
