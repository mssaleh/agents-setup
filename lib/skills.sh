#!/usr/bin/env bash
# lib/skills.sh — the shared skill store, mirrored into the agents that cannot
# read it. Claude Code reads ~/.claude/skills, Codex $CODEX_HOME/skills,
# OpenCode ~/.agents/skills directly.
#
# `skills add -a <agent>` writes the store only when that agent's skillsDir is
# `.agents/skills` — true for codex and opencode, not for claude-code, which
# gets a full copy that shadows the store. `universal` is the id that means the
# store and nothing else, so it is the only install target here.
# shellcheck shell=bash

AGENTS_HOME=${AGENTS_HOME:-$HOME/.agents}
AGENTS_STORE=${AGENTS_STORE:-$AGENTS_HOME/skills}
# Upstream getSkillLockPath(): $XDG_STATE_HOME/skills/, else ~/.agents/.
if [[ -z "${AGENTS_LOCK:-}" ]]; then
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    AGENTS_LOCK="$XDG_STATE_HOME/skills/.skill-lock.json"
  else
    AGENTS_LOCK="$AGENTS_HOME/.skill-lock.json"
  fi
fi

SKILL_STORE_AGENT=${SKILL_STORE_AGENT:-universal}
SKILL_MIRROR_AGENTS=${SKILL_MIRROR_AGENTS:-claude-code codex}

skills_cli() { run npx -y "skills@${SKILLS_CLI_VERSION:-latest}" "$@"; }

# `--skill a,b` is read as one skill named "a,b", matches nothing, and exits 0.
skill_flags() {
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf -- '-s\n%s\n' "$name"
  done < <(printf '%s\n' "$1" | tr ',' '\n')
}

# No agent loads a directory without a SKILL.md, so one is not a skill yet.
store_skill_names() {
  local d
  [[ -d "$AGENTS_STORE" ]] || return 0
  for d in "$AGENTS_STORE"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue   # an unmatched glob expands to itself
    d=${d%/}; printf '%s\n' "${d##*/}"
  done | sort
}

store_invalid_names() {
  local d
  [[ -d "$AGENTS_STORE" ]] || return 0
  for d in "$AGENTS_STORE"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/SKILL.md" ]] && continue
    d=${d%/}; printf '%s\n' "${d##*/}"
  done | sort
}

# Skill names sit at 4 spaces; "version" and "skills" at 2. Read only — every
# write to this file is left to `skills add` and `skills remove`.
lock_skill_names() {
  [[ -f "$AGENTS_LOCK" ]] || return 0
  sed -n 's/^    "\([^"]*\)": {$/\1/p' "$AGENTS_LOCK" | sort
}

store_all_names() { cat <(store_skill_names) <(store_invalid_names) | sort -u; }

# The lock records a source and sourceUrl for everything `skills add` fetched,
# so an entry it lacks was written here by hand. That is the line the manifest
# is authoritative up to, and it is read off the host rather than enumerated.
store_local_names() { comm -23 <(store_all_names) <(lock_skill_names); }

# `skills remove` enumerates the lock too, so it clears an entry whose payload
# is already gone.
skills_forget() {
  skills_cli remove -g -s "$1" -y || warn "could not remove $1"
}

# Only the missing names: `skills add` re-downloads and re-copies whatever it is
# given, so asking for everything rewrote the store on every run and reported no
# change. Refreshing what is present is skills_refresh.
skills_install() {
  local row source names mode want missing flags f
  local fetched=0
  while IFS= read -r row; do
    source=$(manifest_field "$row" 1)
    names=$(manifest_field "$row" 2)
    mode=$(manifest_field "$row" 3)

    want=$(printf '%s\n' "$names" | tr ',' '\n' | sed '/^$/d' | sort -u)
    missing=$(comm -23 <(printf '%s\n' "$want") <(store_skill_names))
    [[ -n "$missing" ]] || continue
    fetched=1

    delta "$source: fetching $(oneline "$missing")"
    while IFS= read -r f; do [[ -n "$f" ]] && plan "skill:$f"; done <<< "$missing"
    case "$mode" in
      select)
        # `paste -` names stdin, which BSD paste requires; ${flags[@]+…} keeps
        # bash 3.2 from calling an empty array unbound.
        flags=(); while IFS= read -r f; do flags+=("$f"); done < <(skill_flags "$(paste -sd, - <<< "$missing")")
        skills_cli add "$source" ${flags[@]+"${flags[@]}"} -a "$SKILL_STORE_AGENT" -g -y ;;
      whole)
        skills_cli add "$source" -a "$SKILL_STORE_AGENT" -g -y ;;
      *) fail "unknown mode '$mode' for $source in skills.tsv" ;;
    esac
  done < <(manifest_rows "$MANIFEST_DIR/skills.tsv")
  ((fetched)) || ok "store has every declared skill"
  return 0
}

# What the store holds, plus what install said it would fetch — under --dry-run
# nothing has been fetched yet, and `planned` is always false on a real run.
mirror_set() {
  local name out
  out=$(store_skill_names)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    planned "skill:$name" && out="$out
$name"
  done < <(manifest_skill_names)
  printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | sort -u
}

skills_refresh() {
  delta "refreshing every installed skill from upstream"
  skills_cli update -g -y || warn "skills update reported a failure"
}

# The lock minus the manifest: a payload no row wants, and an entry whose
# payload is gone. Anything the lock never fetched is out of scope.
skills_prune() {
  local extra name
  extra=$(comm -13 <(manifest_skill_names) <(lock_skill_names))
  [[ -n "$extra" ]] || { ok "no undeclared skills"; return 0; }
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    delta "removing undeclared skill $name"
    plan "unskill:$name"
    skills_forget "$name"
  done <<< "$extra"
}

# A real directory under a mirrored name is a stale full copy shadowing the
# store, so it is replaced. The sweep below skips exactly what this loop owns,
# so nothing is linked and unlinked in the same run.
skills_mirror() {
  local agent dir target name link mirrored
  mirrored=$(mirror_set)
  for agent in $SKILL_MIRROR_AGENTS; do
    dir=$(agent_skills_dir "$agent") || { warn "no skills directory known for $agent"; continue; }
    [[ -d "$(dirname "$dir")" ]] || { info "$agent not installed here, skipping"; continue; }
    [[ -d "$dir" ]] || { delta "creating $dir"; run mkdir -p "$dir"; }

    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      link="$dir/$name"; target="$AGENTS_STORE/$name"
      if [[ -L "$link" ]]; then
        [[ "$link" -ef "$target" ]] && continue
        delta "$agent: repointing $name at the store"
        run rm -f "$link"
      elif [[ -d "$link" ]]; then
        [[ -d "$target" ]] || { warn "$agent: $name is a local directory and the store has no such skill — left alone"; continue; }
        delta "$agent: replacing the copied $name with a link into the store"
        run rm -rf "$link"
      elif [[ -e "$link" ]]; then
        warn "$agent: $name exists and is neither a link nor a directory — left alone"
        continue
      else
        delta "$agent: linking $name"
      fi
      plan "mirror:$agent:$name"
      run ln -sfn "$target" "$link"
    done <<< "$mirrored"

    [[ -d "$dir" ]] || continue
    while IFS= read -r link; do
      [[ -n "$link" ]] || continue
      name=$(basename "$link")
      grep -qxF "$name" <<< "$mirrored" && continue   # owned by the loop above
      if [[ ! -e "$link" ]]; then
        delta "$agent: removing dangling link $name"
      elif [[ "$link" -ef "$AGENTS_STORE/$name" ]]; then
        delta "$agent: removing stale link $name"
      else
        continue
      fi
      plan "unmirror:$agent:$name"
      run rm -f "$link"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)
  done
}
