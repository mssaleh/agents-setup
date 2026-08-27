#!/usr/bin/env bash
# lib/verify.sh — read back what each agent reads, never a receipt this repo
# wrote: a receipt proves the script ran, not that the host converged.
#
# Every list goes through `unplanned` first, so a dry run reports what it would
# leave unfixed rather than repeating the plan back as failures.
# shellcheck shell=bash

verify_dry_run_notice() {
  [[ -n "${DRY_RUN:-}" ]] || return 0
  info "dry run: what follows is what this run would leave unfixed, not the host as it stands"
}

verify_store() {
  local name missing unwanted broken invalid outside local_names stray=""
  missing=$(comm -23 <(manifest_skill_names) <(store_skill_names))
  # The lock minus the manifest, split by whether the payload is still there.
  unwanted=$(comm -13 <(manifest_skill_names) <(lock_skill_names))
  local_names=$(store_local_names)
  # Only a fetched directory can be repaired; an empty one nobody fetched is theirs.
  invalid=$(comm -12 <(store_invalid_names) <(lock_skill_names))

  problem_list "store: declared skills missing" "$(unplanned "$missing" 'skill:')"
  problem_list "store: undeclared skills present" \
    "$(unplanned "$(comm -12 <(printf '%s\n' "$unwanted") <(store_all_names))" 'unskill:')"
  problem_list "lock: undeclared entries with no payload" \
    "$(unplanned "$(comm -23 <(printf '%s\n' "$unwanted") <(store_all_names))" 'unskill:')"
  problem_list "store: directories with no SKILL.md, which no agent loads" \
    "$(unplanned "$(unplanned "$invalid" 'skill:')" 'unskill:')"

  # Outside what the manifest is authoritative over, and worth seeing once a run.
  [[ -n "$local_names" ]] \
    && info "not installed from a source, left alone: $(oneline "$local_names")"

  # Serves whatever that path holds under the declared name. Reported, not
  # replaced: pointing a skill at a working copy is a real thing to do.
  outside=""
  while IFS= read -r name; do
    [[ -n "$name" && -L "$AGENTS_STORE/$name" ]] || continue
    outside="$outside$name -> $(readlink "$AGENTS_STORE/$name")
"
  done < <(manifest_skill_names)
  problem_list "store: entries symlinked out of the store" "$outside"

  # Reported, not removed: the store is shared with `skills`.
  for name in "$AGENTS_STORE"/*; do
    [[ -e "$name" ]] || continue
    [[ -d "$name" ]] && continue
    stray="$stray${name##*/}
"
  done
  problem_list "store: files that are not skill directories" "$stray"

  broken="$missing$unwanted$invalid$outside$stray"
  [[ -z "$broken" ]] \
    && ok "store matches the manifest ($(store_skill_names | wc -l | tr -d ' ') skills)"
  return 0
}

# -ef against its own payload: a link to a different skill still resolves and
# still has a SKILL.md, so a presence check passes while the agent loads the
# wrong thing under that name.
verify_mirrors() {
  local agent dir name link count total absent noskill elsewhere dangling want unfixed
  want=$(mirror_set)
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

    # Only links the mirror pass does not own; the rest are in `absent` already.
    while IFS= read -r link; do
      [[ -n "$link" && ! -e "$link" ]] || continue
      name=$(basename "$link")
      grep -qxF "$name" <<< "$want" && continue
      dangling="$dangling$name
"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)
    problem_list "$agent: dangling links" "$(unplanned "$dangling" "unmirror:$agent:")"

    # The tally describes the host now, which on a covered dry run reads as a
    # failure for work not yet attempted.
    if ((count == total)); then
      ok "$agent: all $total skills resolve to a SKILL.md"
    elif [[ -n "$unfixed" || -z "${DRY_RUN:-}" ]]; then
      warn "$agent: only $count of $total skills resolve to a SKILL.md"
    fi
  done

  # OpenCode reads the store itself; the check is that it is on the path it globs.
  if [[ "$AGENTS_STORE" == "$HOME/.agents/skills" ]]; then
    ok "opencode: reads $AGENTS_STORE directly, no mirror required"
  else
    warn "opencode: globs ~/.agents/skills, but the store is $AGENTS_STORE"
  fi
  return 0
}

# Presence of the name proves nothing: a server that kept its name while its URL
# was overwritten is the defect being checked for.
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

    # Before filtering: a row the run would fix is neither a problem nor a success.
    unfixed="$missing$wrong"
    missing=$(mcp_unplanned "$name" "$missing")
    wrong=$(mcp_unplanned "$name" "$wrong")

    [[ -n "$missing" ]] && problem "mcp: '$name' absent from $missing"
    [[ -n "$wrong" ]]   && problem "mcp: '$name' in $wrong points elsewhere ($detail)"
    [[ -z "$unfixed" ]] && ok "mcp: '$name' resolves to $target in $agents"
  done < <(manifest_rows "$MANIFEST_DIR/mcp.tsv")
  return 0
}

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
