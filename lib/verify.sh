#!/usr/bin/env bash
# lib/verify.sh — check the result against each agent's own configuration.
#
# Every check reads what the agent reads: the store on disk, the links in the
# agent's skills directory, the server names in the agent's config file. Nothing
# here consults a receipt this repo wrote, because a receipt only proves the
# repo ran, not that the host converged.
# shellcheck shell=bash

# verify_dry_run_notice — a dry run applies nothing, so verification necessarily
# reports the host as it stands. Without this the problem list reads as though
# the run itself failed.
verify_dry_run_notice() {
  [[ -n "${DRY_RUN:-}" ]] || return 0
  info "dry run: the checks below describe the host as it is now, not as this run would leave it"
}

# verify_store — the store holds exactly the declared skills, and each one is
# actually a skill. A directory with the right name is not enough: without a
# SKILL.md no agent will load it, and counting directories reports that as
# converged while every agent silently ignores the entry.
verify_store() {
  local name missing extra broken=0 stray f
  missing=$(comm -23 <(manifest_skill_names) <(store_skill_names))
  while IFS= read -r name; do
    [[ -n "$name" ]] && problem "store: declared skill '$name' is missing"
  done <<< "$missing"

  extra=$(comm -13 <(manifest_skill_names) <(store_skill_names))
  while IFS= read -r name; do
    [[ -n "$name" ]] && problem "store: undeclared skill '$name' present"
  done <<< "$extra"

  extra=$(comm -13 <(manifest_skill_names) <(lock_skill_names))
  while IFS= read -r name; do
    [[ -n "$name" ]] && problem "lock: undeclared entry '$name'"
  done <<< "$extra"

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    problem "store: '$name' is a directory with no SKILL.md, so no agent loads it"
    broken=1
  done < <(store_invalid_names)

  # A declared entry substituted by a symlink out of the store serves whatever
  # that path contains, under the declared name, while the lock still records
  # the source it was fetched from. Reported rather than replaced: pointing a
  # skill at a working copy is a real thing to do — it just should not be silent.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ -L "$AGENTS_STORE/$name" ]] || continue
    problem "store: '$name' is a symlink to $(readlink "$AGENTS_STORE/$name"), not the payload from its source"
    broken=1
  done < <(manifest_skill_names)

  # Anything in the store that is not a skill directory is somebody's stray
  # file. It is reported rather than removed: the store is shared with `skills`.
  for f in "$AGENTS_STORE"/*; do
    [[ -e "$f" ]] || continue
    [[ -d "$f" ]] && continue
    stray=1; problem "store: '${f##*/}' is not a skill directory"
  done

  [[ -z "$missing$extra" && -z "${stray:-}" ]] && ((broken == 0)) \
    && ok "store matches the manifest ($(manifest_skill_names | wc -l | tr -d ' ') skills)"
  return 0
}

# verify_mirrors — a mirrored skill must resolve to *its own* payload in the
# store, not merely to something that has a SKILL.md. A link left pointing at a
# different skill still resolves, so a presence check passes while the agent
# loads the wrong skill under that name — the same mistake as checking an MCP
# server by name instead of by target.
verify_mirrors() {
  local agent dir name link count
  for agent in $SKILL_MIRROR_AGENTS; do
    dir=$(agent_skills_dir "$agent") || { problem "no skills directory known for $agent"; continue; }
    [[ -d "$dir" ]] || { problem "$agent: no skills directory at $dir"; continue; }

    count=0
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      link="$dir/$name"
      if [[ ! -e "$link" ]]; then
        problem "$agent: '$name' is missing or dangling"
      elif [[ ! -f "$link/SKILL.md" ]]; then
        problem "$agent: '$name' has no SKILL.md"
      elif [[ ! "$link" -ef "$AGENTS_STORE/$name" ]]; then
        problem "$agent: '$name' resolves to $(readlink "$link" 2>/dev/null || printf 'a local copy'), not the store's $name"
      else
        count=$((count + 1))
      fi
    done < <(manifest_skill_names)

    while IFS= read -r link; do
      [[ -n "$link" && ! -e "$link" ]] && problem "$agent: dangling link $(basename "$link")"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)

    local total; total=$(manifest_skill_names | wc -l | tr -d ' ')
    if ((count == total)); then
      ok "$agent: all $total skills resolve to a SKILL.md"
    else
      warn "$agent: only $count of $total skills resolve to a SKILL.md"
    fi
  done

  # OpenCode reads AGENTS_STORE itself; the check is that the store is on the
  # path it globs, not that a mirror exists.
  if [[ "$AGENTS_STORE" == "$HOME/.agents/skills" ]]; then
    ok "opencode: reads $AGENTS_STORE directly, no mirror required"
  else
    warn "opencode: globs ~/.agents/skills, but the store is $AGENTS_STORE"
  fi
  return 0
}

# verify_mcp — a row is satisfied only when the agent resolves the name to the
# declared target. Presence of the name proves nothing: a server that kept its
# name while its URL was overwritten is exactly the defect being checked for.
verify_mcp() {
  local row name transport target agents state missing wrong detail
  while IFS= read -r row; do
    name=$(manifest_field "$row" 1)
    transport=$(manifest_field "$row" 2)
    target=$(manifest_field "$row" 3)
    agents=$(manifest_field "$row" 4)

    state=$(mcp_row_state "$name" "$transport" "$target" "$agents")
    missing=${state%%|*}; state=${state#*|}
    wrong=${state%%|*}; detail=${state#*|}

    [[ -n "$missing" ]] && problem "mcp: '$name' absent from $missing"
    [[ -n "$wrong" ]]   && problem "mcp: '$name' in $wrong points elsewhere ($detail)"
    [[ -z "$missing$wrong" ]] && ok "mcp: '$name' resolves to $target in $agents"
  done < <(manifest_rows "$MANIFEST_DIR/mcp.tsv")
  return 0
}

verify_plugins() {
  local row marketplace plugin
  while IFS= read -r row; do
    marketplace=$(manifest_field "$row" 2)
    plugin=$(manifest_field "$row" 4)
    if claude_installed_plugins | grep -qxF "$plugin@$marketplace"; then
      ok "plugin: $plugin@$marketplace installed"
    else
      problem "plugin: $plugin@$marketplace declared but not installed"
    fi
  done < <(manifest_rows "$MANIFEST_DIR/plugins.tsv")
  return 0
}
