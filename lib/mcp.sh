#!/usr/bin/env bash
# lib/mcp.sh — install every declared MCP server into every declared agent.
#
# `add-mcp` writes each agent's own config format: ~/.claude.json for Claude
# Code, config.toml for Codex, opencode.jsonc for OpenCode. Two things are set
# here rather than left to the command line:
#
#   the name    a server is identified by its manifest row, so the same name
#               cannot be reused for a different URL
#   the scope   -g, because `claude mcp add` defaults to *project* scope and a
#               server added from a project directory is invisible elsewhere
#
# A row is satisfied only when the agent's config resolves that name to the
# declared target. Checking the name alone is what lets a collision survive.
# shellcheck shell=bash

add_mcp_cli() { run npx -y "add-mcp@${ADD_MCP_CLI_VERSION:-latest}" "$@"; }

# agent_flags <comma-separated agents> — expand to repeated `-a` arguments.
# add-mcp declares `-a, --agent <agent>` with an array default, so it collects
# repetitions; a joined list is rejected outright as "Invalid agents".
agent_flags() {
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] && printf -- '-a\n%s\n' "$agent"
  done < <(printf '%s\n' "$1" | tr ',' '\n')
}

# mcp_expected_kind <transport> — how the agents record this transport.
# Every remote transport is a URL entry; only stdio names a command.
mcp_expected_kind() { [[ "$1" == stdio ]] && printf 'stdio\n' || printf 'remote\n'; }

# mcp_row_state <name> <transport> <target> <agents> — classify each agent as
# ok / missing / wrong, and echo the two actionable lists.
#
#   "<missing agents>|<wrong agents>|<what the wrong ones point at>"
# The three lists are strings rather than arrays because a settled host leaves
# all three empty, and bash 3.2 — the bash macOS ships — treats "${empty[@]}"
# under `set -u` as an unbound variable. Joining as we go also drops the
# subshell each `IFS=,` expansion needed.
mcp_row_state() {
  local name="$1" transport="$2" target="$3" agents="$4"
  local want_kind got kind rest actual on agent missing="" wrong="" detail=""
  want_kind=$(mcp_expected_kind "$transport")
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    got=$(agent_mcp_target "$agent" "$name")
    if [[ -z "$got" ]]; then
      missing="${missing:+$missing,}$agent"; continue
    fi
    kind=${got%%$'\t'*}; rest=${got#*$'\t'}
    actual=${rest%$'\t'*}; on=${rest##*$'\t'}
    # A server switched off is configured but does not run, so it is no more
    # satisfied than one pointing at the wrong URL.
    if [[ "$kind" != "$want_kind" || "$actual" != "$target" ]]; then
      wrong="${wrong:+$wrong,}$agent"; detail="${detail:+$detail; }$agent → $kind:$actual"
    elif [[ "$on" == false ]]; then
      wrong="${wrong:+$wrong,}$agent"; detail="${detail:+$detail; }$agent → disabled"
    fi
  done < <(printf '%s\n' "$agents" | tr ',' '\n')
  printf '%s|%s|%s\n' "$missing" "$wrong" "$detail"
}

# mcp_converge — install where a server is absent, and reinstall where it points
# somewhere the manifest does not declare.
#
# Only the agents that need work are named, so a settled host performs no writes
# and the delta count stays meaningful.
mcp_converge() {
  local row name transport target agents state missing wrong detail flags f fix
  while IFS= read -r row; do
    name=$(manifest_field "$row" 1)
    transport=$(manifest_field "$row" 2)
    target=$(manifest_field "$row" 3)
    agents=$(manifest_field "$row" 4)

    state=$(mcp_row_state "$name" "$transport" "$target" "$agents")
    missing=${state%%|*}; state=${state#*|}
    wrong=${state%%|*}; detail=${state#*|}

    [[ -n "$wrong" ]] && warn "$name in $wrong does not match the manifest ($detail)"
    fix="$missing${missing:+${wrong:+,}}$wrong"
    if [[ -z "$fix" ]]; then
      ok "$name correct in $agents"
      continue
    fi
    delta "installing $name into $fix"
    # ${flags[@]+"${flags[@]}"} rather than "${flags[@]}": bash 3.2 calls an
    # empty array unbound under `set -u`.
    flags=(); while IFS= read -r f; do flags+=("$f"); done < <(agent_flags "$fix")
    case "$transport" in
      stdio)    add_mcp_cli "$target" -n "$name" -g ${flags[@]+"${flags[@]}"} -y ;;
      http|sse) add_mcp_cli "$target" -n "$name" -t "$transport" -g ${flags[@]+"${flags[@]}"} -y ;;
      *)        fail "unknown transport '$transport' for $name in mcp.tsv" ;;
    esac
    agent_mcp_invalidate
  done < <(manifest_rows "$MANIFEST_DIR/mcp.tsv")
}

# mcp_report_project_scope — name Claude Code servers that exist only inside one
# directory. Reported, never edited: a project-scoped server may be deliberate,
# and the fix is a manifest row.
mcp_report_project_scope() {
  local name path shadowed=0
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" ]] || continue
    if manifest_mcp_names | grep -qxF "$name"; then
      warn "claude: '$name' is also project-scoped under $path — the user-scope entry is the one this repo manages"
    else
      warn "claude: '$name' exists only under $path; add it to mcp.tsv to make it global"
    fi
    shadowed=$((shadowed + 1))
  done < <(claude_project_mcp)
  ((shadowed == 0)) && ok "no project-scoped Claude MCP servers"
  return 0
}

# mcp_report_undeclared — servers an agent has that the manifest does not.
# Not removed: Codex's node_repl is injected by the ChatGPT desktop app and
# removing it would break the in-app browser.
mcp_report_undeclared() {
  local agent name extra
  for agent in claude-code codex opencode; do
    extra=$(comm -13 <(manifest_mcp_names) <(agent_mcp_names "$agent"))
    while IFS= read -r name; do
      [[ -n "$name" ]] && info "$agent: '$name' configured but not declared (left alone)"
    done <<< "$extra"
  done
  return 0
}
