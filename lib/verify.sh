#!/usr/bin/env bash
# lib/verify.sh — check the result against each agent's own configuration.
#
# Every check reads what the agent reads: the store on disk, the links in the
# agent's skills directory, the server names in the agent's config file. Nothing
# here consults a receipt this repo wrote, because a receipt only proves the
# repo ran, not that the host converged.
#
# Under --dry-run the passes applied nothing, so each check would find exactly
# what the plan is about to fix and report the whole plan back as failures. Each
# list is therefore filtered through `unplanned` first, leaving the findings the
# run would *not* have resolved — which is the only part worth reading before
# committing to a real run. On a real run the ledger is inert and every check
# reads the host.
# shellcheck shell=bash

verify_dry_run_notice() {
  [[ -n "${DRY_RUN:-}" ]] || return 0
  info "dry run: what follows is what this run would leave unfixed, not the host as it stands"
}

# verify_store — the store holds exactly the declared skills, and each one is
# actually a skill. A directory with the right name is not enough: without a
# SKILL.md no agent will load it, and counting directories reports that as
# converged while every agent silently ignores the entry.
verify_store() {
  local name missing extra broken invalid outside stray=""
  # Required, not declared: a `keep` row names a hand-authored skill that lives
  # on one machine, so its absence anywhere else is not a defect.
  missing=$(comm -23 <(manifest_required_names) <(store_skill_names))
  extra=$(comm -13 <(manifest_skill_names) <(store_skill_names))
  invalid=$(store_invalid_names)

  problem_list "store: declared skills missing" "$(unplanned "$missing" 'skill:')"
  problem_list "store: undeclared skills present" "$(unplanned "$extra" 'unskill:')"
  problem_list "lock: undeclared entries" \
    "$(unplanned "$(comm -13 <(manifest_skill_names) <(lock_skill_names))" 'unskill:')"
  problem_list "store: directories with no SKILL.md, which no agent loads" \
    "$(unplanned "$(unplanned "$invalid" 'skill:')" 'unskill:')"

  # A declared entry substituted by a symlink out of the store serves whatever
  # that path contains, under the declared name, while the lock still records
  # the source it was fetched from. Reported rather than replaced: pointing a
  # skill at a working copy is a real thing to do — it just should not be
  # silent. No pass acts on it, so it survives into a dry run's output, which
  # is the point.
  outside=""
  while IFS= read -r name; do
    [[ -n "$name" && -L "$AGENTS_STORE/$name" ]] || continue
    outside="$outside$name -> $(readlink "$AGENTS_STORE/$name")
"
  done < <(manifest_skill_names)
  problem_list "store: entries symlinked out of the store" "$outside"

  # Anything in the store that is not a skill directory is somebody's stray
  # file. It is reported rather than removed: the store is shared with `skills`.
  for name in "$AGENTS_STORE"/*; do
    [[ -e "$name" ]] || continue
    [[ -d "$name" ]] && continue
    stray="$stray${name##*/}
"
  done
  problem_list "store: files that are not skill directories" "$stray"

  # The count is what the store holds, not what the manifest names: a `keep`
  # row for a skill written on another machine is declared and legitimately
  # absent here, so counting rows would claim a payload that is not there.
  broken="$missing$extra$invalid$outside$stray"
  [[ -z "$broken" ]] \
    && ok "store matches the manifest ($(store_skill_names | wc -l | tr -d ' ') skills)"
  return 0
}

# verify_mirrors — a mirrored skill must resolve to *its own* payload in the
# store, not merely to something that has a SKILL.md. A link left pointing at a
# different skill still resolves, so a presence check passes while the agent
# loads the wrong skill under that name — the same mistake as checking an MCP
# server by name instead of by target.
verify_mirrors() {
  local agent dir name link count total absent noskill elsewhere dangling want unfixed
  # A kept skill is mirrored where it exists and nowhere else, so it is checked
  # only on the machine that has it.
  want=$(cat <(manifest_required_names) \
             <(comm -12 <(manifest_kept_names) <(store_skill_names)) | sort -u)
  total=$(printf '%s\n' "$want" | grep -c .)

  for agent in $SKILL_MIRROR_AGENTS; do
    dir=$(agent_skills_dir "$agent") || { problem "no skills directory known for $agent"; continue; }
    [[ -d "$dir" ]] || { problem "$agent: no skills directory at $dir"; continue; }

    count=0; absent=""; noskill=""; elsewhere=""; dangling=""
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      link="$dir/$name"
      if [[ ! -e "$link" ]]; then
        absent="$absent$name
"
      elif [[ ! -f "$link/SKILL.md" ]]; then
        noskill="$noskill$name
"
      elif [[ ! "$link" -ef "$AGENTS_STORE/$name" ]]; then
        elsewhere="$elsewhere$name -> $(readlink "$link" 2>/dev/null || printf 'a local copy')
"
      else
        count=$((count + 1))
      fi
    done <<< "$want"

    unfixed="$(unplanned "$absent" "mirror:$agent:")$(unplanned "$noskill" "mirror:$agent:")"
    problem_list "$agent: skills missing or dangling" "$(unplanned "$absent" "mirror:$agent:")"
    problem_list "$agent: skills with no SKILL.md"    "$(unplanned "$noskill" "mirror:$agent:")"
    problem_list "$agent: skills resolving to something other than the store" \
      "$(unplanned "$elsewhere" "mirror:$agent:")"
    unfixed="$unfixed$(unplanned "$elsewhere" "mirror:$agent:")"

    # Only links the mirror pass does not own: a declared name that dangles is
    # already in `absent` above, and reporting it twice makes one broken link
    # look like two.
    while IFS= read -r link; do
      [[ -n "$link" && ! -e "$link" ]] || continue
      name=$(basename "$link")
      grep -qxF "$name" <<< "$want" && continue
      dangling="$dangling$name
"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)
    problem_list "$agent: dangling links" "$(unplanned "$dangling" "unmirror:$agent:")"

    # The tally describes the host now. On a dry run whose plan accounts for
    # every gap, "0 of 4 resolve" is true and useless: it reads as a failure
    # for work that has not been attempted yet.
    if ((count == total)); then
      ok "$agent: all $total skills resolve to a SKILL.md"
    elif [[ -n "$unfixed" || -z "${DRY_RUN:-}" ]]; then
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
  local row name transport target agents state unfixed missing wrong detail
  while IFS= read -r row; do
    name=$(manifest_field "$row" 1)
    transport=$(manifest_field "$row" 2)
    target=$(manifest_field "$row" 3)
    agents=$(manifest_field "$row" 4)

    state=$(mcp_row_state "$name" "$transport" "$target" "$agents")
    missing=${state%%|*}; state=${state#*|}
    wrong=${state%%|*}; detail=${state#*|}

    # Whether the row was satisfied before any filtering: a row the run would
    # fix is neither a problem nor a success, and the plan already named it.
    unfixed="$missing$wrong"
    # Filtering is per agent, so a row half of which the run would fix reports
    # only the other half.
    missing=$(mcp_unplanned "$name" "$missing")
    wrong=$(mcp_unplanned "$name" "$wrong")

    [[ -n "$missing" ]] && problem "mcp: '$name' absent from $missing"
    [[ -n "$wrong" ]]   && problem "mcp: '$name' in $wrong points elsewhere ($detail)"
    [[ -z "$unfixed" ]] && ok "mcp: '$name' resolves to $target in $agents"
  done < <(manifest_rows "$MANIFEST_DIR/mcp.tsv")
  return 0
}

# mcp_unplanned <server> <comma-separated agents> — those the run would not fix.
mcp_unplanned() {
  local name="$1" agent out=""
  [[ -n "$2" ]] || return 0
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    planned "mcp:$agent:$name" && continue
    out="${out:+$out,}$agent"
  done < <(printf '%s\n' "$2" | tr ',' '\n')
  printf '%s' "$out"
}

verify_plugins() {
  local row marketplace plugin
  while IFS= read -r row; do
    marketplace=$(manifest_field "$row" 2)
    plugin=$(manifest_field "$row" 4)
    if claude_installed_plugins | grep -qxF "$plugin@$marketplace"; then
      ok "plugin: $plugin@$marketplace installed"
    elif ! planned "plugin:$plugin@$marketplace"; then
      problem "plugin: $plugin@$marketplace declared but not installed"
    fi
  done < <(manifest_rows "$MANIFEST_DIR/plugins.tsv")
  return 0
}
