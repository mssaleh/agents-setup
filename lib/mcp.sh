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

# mcp_stdio_version <target> — the version a package spec pins, if any.
# A leading @scope is not a version.
mcp_stdio_version() {
  case "$1" in
    @*/*@*) printf '%s\n' "${1##*@}" ;;
    @*/*)   ;;
    *@*)    printf '%s\n' "${1##*@}" ;;
  esac
}

# mcp_stdio_identity <target> — the package a stdio target runs.
#
# The runner is stripped before a target reaches here; what can remain is the
# directory the binary was installed into and the version it was resolved at.
# Neither is the server. A global install run straight from ~/.npm/…/bin and
# `npx -y that-package@latest` are one MCP server started two ways.
mcp_stdio_identity() {
  local t="$1"
  case "$t" in /*|~/*|./*|../*) t=${t##*/} ;; esac
  case "$t" in
    @*/*@*) t=${t%@*} ;;
    @*/*)   ;;
    *@*)    t=${t%@*} ;;
  esac
  printf '%s\n' "$t"
}

# mcp_stdio_matches <declared> <configured> — is the row satisfied?
#
# The manifest decides how strictly. A row that pins a version means it, and
# anything else is wrong. `@latest`, or a bare package name, does not name a
# version at all, so any invocation of that package satisfies it — including
# the one already on the host. Rewriting a working local binary into an npx
# call is churn: measured here, npx costs 0.2–0.6 s per launch over running
# the installed binary, and buys nothing the manifest asked for.
mcp_stdio_matches() {
  local want="$1" got="$2" v
  [[ "$want" == "$got" ]] && return 0
  v=$(mcp_stdio_version "$want")
  [[ -n "$v" && "$v" != latest ]] && return 1
  [[ "$(mcp_stdio_identity "$want")" == "$(mcp_stdio_identity "$got")" ]]
}

# mcp_target_matches <transport> <declared> <configured> — one comparison for
# either kind. A URL is compared whole: every character of it is the address.
mcp_target_matches() {
  if [[ "$1" == stdio ]]; then mcp_stdio_matches "$2" "$3"; else [[ "$2" == "$3" ]]; fi
}

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
    if [[ "$kind" != "$want_kind" ]] || ! mcp_target_matches "$transport" "$target" "$actual"; then
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
    while IFS= read -r f; do [[ -n "$f" ]] && plan "mcp:$f:$name"; done \
      < <(printf '%s\n' "$fix" | tr ',' '\n')
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

# mcp_duplicates <agent> — "<name>\t<target>\t<row it duplicates>" for every
# configured server whose target a manifest row already installs under another
# name. This is the name collision from the other side: nothing is overwritten
# and nothing needs repairing, the agent simply opens the same endpoint twice
# and offers every tool on it twice.
mcp_duplicates() {
  local agent="$1" name got target dup
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    got=$(agent_mcp_target "$agent" "$name")
    target=${got#*$'\t'}; target=${target%$'\t'*}
    dup=$(manifest_rows "$MANIFEST_DIR/mcp.tsv" \
          | awk -F'\t' -v t="$target" '$3 == t { print $1; exit }')
    [[ -n "$dup" ]] && printf '%s\t%s\t%s\n' "$name" "$target" "$dup"
  done < <(comm -13 <(manifest_mcp_names) <(agent_mcp_names "$agent"))
  return 0
}

# mcp_prune_duplicates — remove those, on request only.
#
# Opt-in because it deletes configuration this repo did not write. It is
# narrow: only a server whose target a declared row already installs, so
# nothing that provides something of its own is ever a candidate.
#
# It runs before the converge pass, so a declared server caught by the
# substring rule below would be reinstalled in the same run rather than left
# missing until the next one.
mcp_prune_duplicates() {
  [[ -n "${PRUNE_DUPLICATE_MCP:-}" ]] || return 0
  local agent name target dup collide
  for agent in claude-code codex opencode; do
    while IFS=$'\t' read -r name target dup; do
      [[ -n "$name" ]] || continue
      # `add-mcp remove` matches `serverName.includes(query)`, so a name that
      # is a substring of another configured one would take that with it, and
      # -y accepts every match without asking.
      collide=$(agent_mcp_names "$agent" | grep -F "$name" | grep -vxF "$name")
      if [[ -n "$collide" ]]; then
        warn "$agent: leaving '$name' — add-mcp removes on a substring match and would take $(oneline "$collide") too; remove it by hand"
        continue
      fi
      delta "$agent: removing '$name', a second name for $dup's endpoint"
      add_mcp_cli remove "$name" -g -a "$agent" -y
      agent_mcp_invalidate
    done < <(mcp_duplicates "$agent")
  done
}

# mcp_report_undeclared — servers an agent has that the manifest does not.
#
# Not removed: Codex's node_repl is injected by the ChatGPT desktop app and
# removing it would break the in-app browser.
mcp_report_undeclared() {
  local agent name extra dups
  for agent in claude-code codex opencode; do
    dups=$(mcp_duplicates "$agent" | cut -f1)
    while IFS=$'\t' read -r name target dup; do
      [[ -n "$name" ]] || continue
      warn "$agent: '$name' is a second name for $target, which the manifest installs as '$dup' — the agent connects twice and every tool appears twice; --prune-duplicate-mcp removes it"
    done < <(mcp_duplicates "$agent")

    extra=$(comm -13 <(manifest_mcp_names) <(agent_mcp_names "$agent"))
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      grep -qxF "$name" <<< "$dups" && continue
      info "$agent: '$name' configured but not declared (left alone)"
    done <<< "$extra"
  done
  return 0
}

# mcp_report_variants — a row satisfied by a different invocation of the same
# package. Nothing to repair, but the host is not running what the manifest
# literally says, and that should not be silent.
mcp_report_variants() {
  local row name transport target agents agent got actual
  while IFS= read -r row; do
    transport=$(manifest_field "$row" 2); [[ "$transport" == stdio ]] || continue
    name=$(manifest_field "$row" 1)
    target=$(manifest_field "$row" 3)
    agents=$(manifest_field "$row" 4)
    while IFS= read -r agent; do
      [[ -n "$agent" ]] || continue
      got=$(agent_mcp_target "$agent" "$name"); [[ -n "$got" ]] || continue
      actual=${got#*$'\t'}; actual=${actual%$'\t'*}
      [[ "$actual" == "$target" ]] && continue
      mcp_stdio_matches "$target" "$actual" || continue
      info "$agent: '$name' runs $actual — the package $target names, started another way"
    done < <(printf '%s\n' "$agents" | tr ',' '\n')
  done < <(manifest_rows "$MANIFEST_DIR/mcp.tsv")
  return 0
}
