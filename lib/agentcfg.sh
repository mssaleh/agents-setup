#!/usr/bin/env bash
# lib/agentcfg.sh — read what each agent has actually configured.
#
# Verification reads the agent's own config, never a receipt this repo wrote.
# The three agents store MCP servers in three formats, so everything is
# normalised once into `agent <TAB> name <TAB> kind <TAB> target <TAB> enabled`.
#
# Comparing the target rather than the name is the point. A name collision —
# the same `mcp add <name>` run with three different URLs — leaves one server
# holding a name that describes none of them, and a name-only check calls that
# converged. `enabled` matters for the same reason: a server present with the
# right URL and `enabled = false` does not run.
#
# The files are read directly rather than through each agent's `mcp list`: those
# commands health-check every server, so they need the network and take seconds,
# and `claude mcp get` omits the target entirely for a server disabled in the
# current project.
# shellcheck shell=bash

# Every one of these is the same path on macOS and Linux: the agents and the
# two CLIs derive them from the home directory, not from a platform config
# location. Two of them are asymmetric on purpose. Claude Code and the skills
# CLI both take the configuration home from CLAUDE_CONFIG_DIR, so the skills
# directory follows it; `add-mcp` writes ~/.claude.json whatever that variable
# says, so the config file does not.
CLAUDE_CONFIG=${CLAUDE_CONFIG:-$HOME/.claude.json}
CLAUDE_HOME=${CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}
CODEX_HOME=${CODEX_HOME:-$HOME/.codex}

# OpenCode's global config is whichever of these two exists, and add-mcp
# creates the .jsonc when neither does. Reading a fixed .jsonc on a host whose
# file is .json finds no servers at all, which reads as "every row missing" and
# reinstalls all of them on every run.
opencode_config_path() {
  local dir="$HOME/.config/opencode"
  [[ -f "$dir/opencode.jsonc" ]] && { printf '%s\n' "$dir/opencode.jsonc"; return; }
  [[ -f "$dir/opencode.json" ]]  && { printf '%s\n' "$dir/opencode.json"; return; }
  printf '%s\n' "$dir/opencode.jsonc"
}
OPENCODE_CONFIG=${OPENCODE_CONFIG:-$(opencode_config_path)}

MCP_TABLE_CACHE=""

# json_mcp_block <file> <top-level key> — "name<TAB>kind<TAB>target<TAB>enabled"
# for every server under that key.
#
# Structure comes from brace depth, not from indentation. Both agents happen to
# write two-space JSON today, but a hand-edited or reformatted file is still the
# same document, and an indentation-based reader silently returns nothing for it
# — which reads as "every server is missing" and rewrites a file that was fine.
# Comments are skipped outside string literals, so opencode.jsonc is accepted.
json_mcp_block() {
  [[ -f "$1" ]] || return 0
  awk -v want="$2" '
    function flush(  i, rest, first) {
      if (name == "") return
      if (url != "") { printf "%s\tremote\t%s\t%s\n", name, url, enabled }
      else if (cmd != "" || na > 0) {
        # OpenCode packs runner and arguments into one "command" array, Claude
        # Code splits them across "command" and "args". Either way the runner is
        # not the identity: the package it runs is.
        first = 1
        if (cmd == "" && na > 0 && arg[1] ~ /^npx(\.cmd)?$/) first = 2
        rest = (cmd == "npx" || cmd == "npx.cmd") ? "" : cmd
        for (i = first; i <= na; i++) {
          if (arg[i] ~ /^-/) continue          # -y and friends are not the target
          rest = (rest == "" ? arg[i] : rest " " arg[i])
        }
        if (rest != "") printf "%s\tstdio\t%s\t%s\n", name, rest, enabled
      }
      name = ""; url = ""; cmd = ""; na = 0; enabled = "true"
    }
    # The field a value belongs to is the key most recently seen at this depth.
    # Deriving it here rather than at each call site is what keeps a minified
    # document correct: with no whitespace, `"url":"X","enabled":true}` closes
    # on the brace, and a caller-set field would still be pointing at "url".
    function value(v) {
      if (!inblock || depth != 3) return
      if (inarr) { arg[++na] = v; return }
      if (key[3] == "url") url = v
      else if (key[3] == "command") cmd = v
      else if (key[3] == "enabled") enabled = v
    }
    BEGIN { depth = 0; enabled = "true" }
    {
      line = $0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (instr) {
          if (c == "\\") { buf = buf substr(line, i, 2); i += 2; continue }
          if (c == "\"") { instr = 0; tok = buf; havetok = 1; i++; continue }
          buf = buf c; i++; continue
        }
        if (c == "\"") { instr = 1; buf = ""; i++; continue }
        if (c == "/" && substr(line, i+1, 1) == "/") break            # line comment
        if (c == "/" && substr(line, i+1, 1) == "*") { incomment = 1; i += 2; continue }
        if (incomment) { if (c == "*" && substr(line, i+1, 1) == "/") { incomment = 0; i += 2 } else i++; continue }
        if (c == ":") { key[depth] = tok; havetok = 0; expect = 1; i++; continue }
        if (c == "{") {
          depth++
          if (depth == 2 && key[1] == want) inblock = 1
          if (inblock && depth == 3) { name = key[2]; url = ""; cmd = ""; na = 0; enabled = "true" }
          expect = 0; havetok = 0; i++; continue
        }
        if (c == "}") {
          if (havetok && expect) { value(tok); havetok = 0 }
          if (inblock && depth == 3) flush()
          if (inblock && depth == 2) inblock = 0
          depth--; expect = 0; i++; continue
        }
        if (c == "[") { if (inblock && depth == 3) inarr = 1; i++; continue }
        if (c == "]") { if (havetok) { value(tok); havetok = 0 } inarr = 0; i++; continue }
        if (c == ",") { if (havetok) { value(tok); havetok = 0 } expect = 0; i++; continue }
        if (c ~ /[[:space:]]/) { i++; continue }
        # a bare token: true, false, a number
        j = i; bare = ""
        while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_.+-]/) { bare = bare substr(line, j, 1); j++ }
        if (bare != "") { tok = bare; havetok = 1; i = j; continue }
        i++
      }
      if (havetok && expect && !inarr) { value(tok); havetok = 0 }
      else if (havetok && inarr) { value(tok); havetok = 0 }
    }
    END { flush() }
  ' "$1"
}

# toml_mcp_servers <file> — Codex. A bare table name stops at the first dot so
# the [mcp_servers.node_repl.env] sub-table is not mistaken for a server; a
# quoted name may contain dots.
toml_mcp_servers() {
  [[ -f "$1" ]] || return 0
  awk '
    function flush(  i, rest) {
      if (name == "") return
      if (url != "") { printf "%s\tremote\t%s\t%s\n", name, url, enabled }
      else if (cmd != "") {
        rest = (cmd == "npx" || cmd == "npx.cmd") ? "" : cmd
        for (i = 1; i <= n; i++) {
          if (args[i] ~ /^-/) continue
          rest = (rest == "" ? args[i] : rest " " args[i])
        }
        if (rest != "") printf "%s\tstdio\t%s\t%s\n", name, rest, enabled
      }
      name = ""; url = ""; cmd = ""; n = 0; enabled = "true"
    }
    BEGIN { enabled = "true" }
    /^[[:space:]]*\[/ {
      flush()
      if (match($0, /^[[:space:]]*\[mcp_servers\."[^"]+"\][[:space:]]*$/)) {
        name = $0; sub(/^[^"]*"/, "", name); sub(/"\][[:space:]]*$/, "", name)
      } else if (match($0, /^[[:space:]]*\[mcp_servers\.[^]."]+\][[:space:]]*$/)) {
        name = $0; sub(/^[[:space:]]*\[mcp_servers\./, "", name); sub(/\][[:space:]]*$/, "", name)
      }
      next
    }
    name == "" { next }
    match($0, /^[[:space:]]*url[[:space:]]*=[[:space:]]*"/)     { url = $0; sub(/^[^"]*"/, "", url); sub(/".*$/, "", url); next }
    match($0, /^[[:space:]]*command[[:space:]]*=[[:space:]]*"/) { cmd = $0; sub(/^[^"]*"/, "", cmd); sub(/".*$/, "", cmd); next }
    match($0, /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*/) {
      enabled = $0; sub(/^[^=]*=[[:space:]]*/, "", enabled); sub(/[[:space:]]*$/, "", enabled); next
    }
    match($0, /^[[:space:]]*args[[:space:]]*=[[:space:]]*\[/) {
      rest = $0; sub(/^[^[]*\[/, "", rest); sub(/\][[:space:]]*$/, "", rest)
      while (match(rest, /"[^"]*"/)) {
        args[++n] = substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
      }
      next
    }
    END { flush() }
  ' "$1"
}

# agent_mcp_table — one row per configured server, across every agent.
# Cached for the process: the passes ask about the same servers repeatedly.
agent_mcp_table() {
  if [[ -z "$MCP_TABLE_CACHE" ]]; then
    MCP_TABLE_CACHE=$(
      json_mcp_block "$CLAUDE_CONFIG" mcpServers | sed 's/^/claude-code\t/'
      toml_mcp_servers "$CODEX_HOME/config.toml" | sed 's/^/codex\t/'
      json_mcp_block "$OPENCODE_CONFIG" mcp | sed 's/^/opencode\t/'
    )
  fi
  printf '%s\n' "$MCP_TABLE_CACHE"
}

agent_mcp_invalidate() { MCP_TABLE_CACHE=""; }

agent_mcp_names() {
  agent_mcp_table | awk -F'\t' -v a="$1" '$1 == a && $2 != "" { print $2 }' | sort -u
}

# agent_mcp_target <agent> <name> — "kind<TAB>target<TAB>enabled", empty if absent.
agent_mcp_target() {
  agent_mcp_table | awk -F'\t' -v a="$1" -v n="$2" '$1 == a && $2 == n { print $3"\t"$4"\t"$5; exit }'
}

# claude_project_mcp — "<name>\t<project path>" per project-scoped server.
# These are what `claude mcp add` creates without --scope user: they work in one
# directory and are invisible everywhere else.
claude_project_mcp() {
  [[ -f "$CLAUDE_CONFIG" ]] || return 0
  awk '
    # Depth, not indentation, and not "have I seen projects yet": the top-level
    # mcpServers block sits after projects, so a reader that only latches on
    # never leaves and reports every user-scope server as belonging to whatever
    # key it saw last.
    #
    # A server name is key[4], read while inside the mcpServers object, so the
    # row is emitted when that name`s own object opens at depth 5. Keys deeper
    # than the current object are cleared on close: an empty "mcpServers": {}
    # would otherwise leave key[3] set and make the next unrelated object at
    # that depth look like a project`s server list.
    #
    #   depth 2  inside projects  — key[2] is a project path
    #   depth 4  inside a project — key[3] is mcpServers
    #   depth 5  a server object  — key[4] is its name
    {
      line = $0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (instr) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { instr = 0; tok = buf; i++; continue }
          buf = buf c; i++; continue
        }
        if (c == "\"") { instr = 1; buf = ""; i++; continue }
        if (c == "/" && substr(line, i+1, 1) == "/") break
        if (c == ":") { key[depth] = tok; i++; continue }
        if (c == "{") {
          depth++
          if (depth == 5 && key[1] == "projects" && key[3] == "mcpServers")
            printf "%s\t%s\n", key[4], key[2]
          i++; continue
        }
        if (c == "}") { for (d = depth; d <= 6; d++) key[d] = ""; depth--; i++; continue }
        i++
      }
    }
  ' "$CLAUDE_CONFIG"
}

agent_skills_dir() {
  case "$1" in
    claude-code) printf '%s\n' "$CLAUDE_HOME/skills" ;;
    codex)       printf '%s\n' "$CODEX_HOME/skills" ;;
    *)           return 1 ;;
  esac
}

# json_keys_at <file> <indent> — object keys at exactly that indentation.
json_keys_at() {
  [[ -f "$1" ]] || return 0
  sed -n "s/^ \{$2\}\"\([^\"]*\)\": [{[].*$/\1/p" "$1"
}

claude_installed_plugins() { json_keys_at "$CLAUDE_HOME/plugins/installed_plugins.json" 4; }
claude_known_marketplaces() { json_keys_at "$CLAUDE_HOME/plugins/known_marketplaces.json" 2; }
