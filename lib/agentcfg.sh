#!/usr/bin/env bash
# lib/agentcfg.sh — three config formats normalised to
# `agent <TAB> name <TAB> kind <TAB> target <TAB> enabled`.
#
# Parsed directly rather than through each agent's `mcp list`: those health-check
# every server, so they need the network and take seconds, and `claude mcp get`
# omits the target for a server disabled in the current project.
# shellcheck shell=bash

# Same paths on macOS and Linux — all homedir-derived. The asymmetry is upstream:
# Claude Code and `skills` honour CLAUDE_CONFIG_DIR, `add-mcp` writes
# ~/.claude.json regardless.
CLAUDE_CONFIG=${CLAUDE_CONFIG:-$HOME/.claude.json}
CLAUDE_HOME=${CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}
CODEX_HOME=${CODEX_HOME:-$HOME/.codex}

# add-mcp writes whichever of these exists, and creates the .jsonc when neither
# does. A fixed .jsonc on a .json host finds no servers, so every row reads as
# missing and is reinstalled every run.
opencode_config_path() {
  local dir="$HOME/.config/opencode"
  [[ -f "$dir/opencode.jsonc" ]] && { printf '%s\n' "$dir/opencode.jsonc"; return; }
  [[ -f "$dir/opencode.json" ]]  && { printf '%s\n' "$dir/opencode.json"; return; }
  printf '%s\n' "$dir/opencode.jsonc"
}
OPENCODE_CONFIG=${OPENCODE_CONFIG:-$(opencode_config_path)}

MCP_TABLE_CACHE=""

# Brace depth, not indentation: a reformatted or minified file is the same
# document, and an indentation reader returns nothing for it — which reads as
# every server missing. JSONC comments are skipped outside string literals.
json_mcp_block() {
  [[ -f "$1" ]] || return 0
  awk -v want="$2" '
    function flush(  i, rest, first) {
      if (name == "") return
      if (url != "") { printf "%s\tremote\t%s\t%s\n", name, url, enabled }
      else if (cmd != "" || na > 0) {
        # OpenCode packs runner and args into one "command" array, Claude Code
        # splits them. Either way the runner is not the identity.
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
    # The field is the key most recently seen at this depth. Derived here, not at
    # the call site: minified, `"url":"X","enabled":true}` closes on the brace.
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

# Codex. A bare table name stops at the first dot, so [mcp_servers.x.env] is not
# a server; a quoted name may contain dots.
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

# Cached: the passes ask about the same servers repeatedly.
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

# "kind<TAB>target<TAB>enabled", empty if absent.
agent_mcp_target() {
  agent_mcp_table | awk -F'\t' -v a="$1" -v n="$2" '$1 == a && $2 == n { print $3"\t"$4"\t"$5; exit }'
}

# "<name>\t<project path>" per project-scoped server — what `claude mcp add`
# creates without --scope user, working in one directory and nowhere else.
claude_project_mcp() {
  [[ -f "$CLAUDE_CONFIG" ]] || return 0
  awk '
    # depth 2 in projects: key[2] is the path. depth 4 in a project: key[3] is
    # mcpServers. depth 5: key[4] is the server name, so the row is emitted there.
    # The top-level mcpServers block sits after projects, so a reader that only
    # latches on never leaves. Deeper keys are cleared on close: an empty
    # "mcpServers": {} would otherwise leave key[3] set for the next object.
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

# Servers Claude Code has switched off for one directory. A different key from
# disabledMcpjsonServers, and invisible to a user-scope check: the server is
# configured, healthy, and does not run.
claude_disabled_in() {
  [[ -f "$CLAUDE_CONFIG" ]] || return 0
  awk -v want="$1" '
    {
      line = $0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (instr) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { instr = 0; tok = buf; if (emit) print tok; i++; continue }
          buf = buf c; i++; continue
        }
        if (c == "\"") { instr = 1; buf = ""; i++; continue }
        if (c == ":") { key[depth] = tok; i++; continue }
        if (c == "{") { depth++; i++; continue }
        if (c == "}") { for (d = depth; d <= 5; d++) key[d] = ""; depth--; i++; continue }
        if (c == "[") {
          emit = (depth == 3 && key[1] == "projects" && key[2] == want && key[3] == "disabledMcpServers")
          i++; continue
        }
        if (c == "]") { emit = 0; i++; continue }
        i++
      }
    }
  ' "$CLAUDE_CONFIG"
}

# Object keys at exactly that indentation.
json_keys_at() {
  [[ -f "$1" ]] || return 0
  sed -n "s/^ \{$2\}\"\([^\"]*\)\": [{[].*$/\1/p" "$1"
}

claude_installed_plugins() { json_keys_at "$CLAUDE_HOME/plugins/installed_plugins.json" 4; }
claude_known_marketplaces() { json_keys_at "$CLAUDE_HOME/plugins/known_marketplaces.json" 2; }
