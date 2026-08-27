#!/usr/bin/env bash
# lib/mcp.sh — install every declared MCP server into every declared agent.
#
# The name comes from the manifest row, never a command line, and -g is always
# passed: `claude mcp add` defaults to project scope, which is invisible
# elsewhere. A row is satisfied only when the agent resolves the name to the
# declared target.
# shellcheck shell=bash

add_mcp_cli() { run npx -y "add-mcp@${ADD_MCP_CLI_VERSION:-latest}" "$@"; }

# -a repeats; a comma-joined list is rejected as "Invalid agents".
agent_flags() {
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] && printf -- '-a\n%s\n' "$agent"
  done < <(printf '%s\n' "$1" | tr ',' '\n')
}

# Every remote transport is a URL entry; only stdio names a command.
mcp_expected_kind() { [[ "$1" == stdio ]] && printf 'stdio\n' || printf 'remote\n'; }

# A leading @scope is not a version.
mcp_stdio_version() {
  case "$1" in
    @*/*@*) printf '%s\n' "${1##*@}" ;;
    @*/*)   ;;
    *@*)    printf '%s\n' "${1##*@}" ;;
  esac
}

# The package a stdio target runs. The runner is already stripped; the install
# directory and the resolved version are the same kind of noise.
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

# A pinned version means it. @latest names no version, so any invocation of the
# package satisfies it — including the binary already installed on the host.
mcp_stdio_matches() {
  local want="$1" got="$2" v
  [[ "$want" == "$got" ]] && return 0
  v=$(mcp_stdio_version "$want")
  [[ -n "$v" && "$v" != latest ]] && return 1
  [[ "$(mcp_stdio_identity "$want")" == "$(mcp_stdio_identity "$got")" ]]
}

# A URL is compared whole: every character of it is the address.
mcp_target_matches() {
  if [[ "$1" == stdio ]]; then mcp_stdio_matches "$2" "$3"; else [[ "$2" == "$3" ]]; fi
}

# "<missing agents>|<wrong agents>|<what the wrong ones point at>". Strings, not
# arrays: bash 3.2 calls an empty array unbound under `set -u`, and a settled
# host leaves all three empty.
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
    # Switched off is configured and not running, so no more satisfied than wrong.
    if [[ "$kind" != "$want_kind" ]] || ! mcp_target_matches "$transport" "$target" "$actual"; then
      wrong="${wrong:+$wrong,}$agent"; detail="${detail:+$detail; }$agent → $kind:$actual"
    elif [[ "$on" == false ]]; then
      wrong="${wrong:+$wrong,}$agent"; detail="${detail:+$detail; }$agent → disabled"
    fi
  done < <(printf '%s\n' "$agents" | tr ',' '\n')
  printf '%s|%s|%s\n' "$missing" "$wrong" "$detail"
}

# When every agent that has the row starts the package the same way, the ones
# that lack it get that rather than the manifest spelling. Disagreement falls back.
mcp_host_target() {
  local name="$1" transport="$2" target="$3" agents="$4" agent got actual seen=""
  if [[ "$transport" == stdio ]]; then
    while IFS= read -r agent; do
      [[ -n "$agent" ]] || continue
      got=$(agent_mcp_target "$agent" "$name")
      [[ -n "$got" ]] || continue
      actual=${got#*$'\t'}; actual=${actual%$'\t'*}
      mcp_stdio_matches "$target" "$actual" || continue
      [[ -z "$seen" ]] && { seen="$actual"; continue; }
      [[ "$seen" == "$actual" ]] || { seen=""; break; }
    done < <(printf '%s\n' "$agents" | tr ',' '\n')
  fi
  printf '%s\n' "${seen:-$target}"
}

# Only the agents that need work are named, so a settled host writes nothing.
mcp_converge() {
  local row name transport target agents state missing wrong detail flags f fix use
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
    use=$(mcp_host_target "$name" "$transport" "$target" "$agents")
    if [[ "$use" == "$target" ]]; then
      delta "installing $name into $fix"
    else
      delta "installing $name into $fix as $use, which the other agents already run"
    fi
    while IFS= read -r f; do [[ -n "$f" ]] && plan "mcp:$f:$name"; done \
      < <(printf '%s\n' "$fix" | tr ',' '\n')
    flags=(); while IFS= read -r f; do flags+=("$f"); done < <(agent_flags "$fix")
    case "$transport" in
      stdio)    add_mcp_cli "$use" -n "$name" -g ${flags[@]+"${flags[@]}"} -y ;;
      http|sse) add_mcp_cli "$use" -n "$name" -t "$transport" -g ${flags[@]+"${flags[@]}"} -y ;;
      *)        fail "unknown transport '$transport' for $name in mcp.tsv" ;;
    esac
    agent_mcp_invalidate
  done < <(manifest_rows "$MANIFEST_DIR/mcp.tsv")
}

mcp_report_disabled_here() {
  local name declared off=""
  declared=$(manifest_mcp_names)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<< "$declared" && off="${off:+$off,}$name"
  done < <(claude_disabled_in "$PWD")
  [[ -n "$off" ]] \
    && info "claude: $off installed but switched off in $PWD — /mcp re-enables them"
  return 0
}

# Reported, never edited: a project-scoped server may be deliberate, and the fix
# is a manifest row.
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

# "<name>\t<target>\t<row it duplicates>" — a second name for an endpoint a row
# already installs. Nothing is overwritten; the agent just connects twice.
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

# Opt-in: it deletes configuration this repo did not write. Runs before converge,
# so anything caught by the substring rule below comes back in the same run.
mcp_prune_duplicates() {
  [[ -n "${PRUNE_DUPLICATE_MCP:-}" ]] || return 0
  local agent name target dup collide
  for agent in claude-code codex opencode; do
    while IFS=$'\t' read -r name target dup; do
      [[ -n "$name" ]] || continue
      # `add-mcp remove` matches serverName.includes(query) and -y takes every match.
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

# Not removed: Codex's node_repl is injected by the ChatGPT desktop app, and
# removing it breaks the in-app browser.
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

# Satisfied by another invocation of the same package: nothing to repair, but the
# host is not running what the row literally says.
mcp_report_variants() {
  local row name transport target agents agent got actual seen split where held
  while IFS= read -r row; do
    transport=$(manifest_field "$row" 2); [[ "$transport" == stdio ]] || continue
    name=$(manifest_field "$row" 1)
    target=$(manifest_field "$row" 3)
    agents=$(manifest_field "$row" 4)
    seen=""; split=""; where=""; held=""
    while IFS= read -r agent; do
      [[ -n "$agent" ]] || continue
      got=$(agent_mcp_target "$agent" "$name"); [[ -n "$got" ]] || continue
      actual=${got#*$'\t'}; actual=${actual%$'\t'*}
      mcp_stdio_matches "$target" "$actual" || continue
      held="${held:+$held,}$agent"
      where="${where:+$where; }$agent → $actual"
      if [[ -z "$seen" ]]; then seen="$actual"
      elif [[ "$seen" != "$actual" ]]; then split=1
      fi
    done < <(printf '%s\n' "$agents" | tr ',' '\n')
    if [[ -n "$split" ]]; then
      warn "'$name' is started differently by different agents ($where) — same server, so nothing here repairs it; pick one and install it into all of them"
    elif [[ -n "$seen" && "$seen" != "$target" ]]; then
      info "'$name' runs $seen in $held — the package $target names, started another way"
    fi
  done < <(manifest_rows "$MANIFEST_DIR/mcp.tsv")
  return 0
}
