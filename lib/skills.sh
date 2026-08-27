#!/usr/bin/env bash
# lib/skills.sh — converge the shared skill store and mirror it into the agents
# that cannot read it directly.
#
# One store, ~/.agents/skills, holds every skill payload. Which agents need a
# copy is a property of the agent binary, not a preference:
#
#   Claude Code  reads ~/.claude/skills/<name>/            → mirror
#   Codex        reads $CODEX_HOME/skills/<name>/          → mirror
#   OpenCode     reads ~/.agents/skills/<name>/SKILL.md    → no mirror needed
#
# `skills add` routes an agent to the store when that agent's skillsDir is
# `.agents/skills`. Of the three here, `codex` and `opencode` are classified
# that way and `claude-code` is not, so a global `skills add -a codex` writes the
# store and never `~/.codex/skills` — which is the only place the Codex binary
# looks. `-a claude-code` alone writes a full copy into `~/.claude/skills` that
# shadows the store. `universal` is the id whose whole purpose is the store: it
# is never auto-detected, so naming it says "the store, and nothing else".
#
# The store is therefore the only install target here, and every agent link is
# made by skills_mirror, which can be verified afterwards.
# shellcheck shell=bash

AGENTS_HOME=${AGENTS_HOME:-$HOME/.agents}
AGENTS_STORE=${AGENTS_STORE:-$AGENTS_HOME/skills}
# Upstream getSkillLockPath() prefers $XDG_STATE_HOME/skills/ and falls back to
# ~/.agents/. Following the same rule keeps both tools reading one lock.
if [[ -z "${AGENTS_LOCK:-}" ]]; then
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    AGENTS_LOCK="$XDG_STATE_HOME/skills/.skill-lock.json"
  else
    AGENTS_LOCK="$AGENTS_HOME/.skill-lock.json"
  fi
fi

# The hidden agent id whose base directory is the canonical store.
SKILL_STORE_AGENT=${SKILL_STORE_AGENT:-universal}

# Agents whose skills directory this repo keeps in step with the store.
SKILL_MIRROR_AGENTS=${SKILL_MIRROR_AGENTS:-claude-code codex}

skills_cli() { run npx -y "skills@${SKILLS_CLI_VERSION:-latest}" "$@"; }

# skill_flags <comma-separated names> — expand to repeated `-s` arguments.
# `--skill a,b` is read as one skill literally named "a,b" and matches nothing;
# the CLI reports "No matching skills found" and exits successfully, so a joined
# list fails silently.
skill_flags() {
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf -- '-s\n%s\n' "$name"
  done < <(printf '%s\n' "$1" | tr ',' '\n')
}


# store_skill_names — the skills the store actually provides.
#
# A directory is not a skill until it has a SKILL.md: no agent will load one
# without it. Counting bare directories made a half-written or truncated payload
# look installed, so nothing re-fetched it and every check downstream agreed the
# host had converged while the skill did nothing.
store_skill_names() {
  local d
  [[ -d "$AGENTS_STORE" ]] || return 0
  for d in "$AGENTS_STORE"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue   # an unmatched glob expands to itself
    d=${d%/}; printf '%s\n' "${d##*/}"
  done | sort
}

# store_invalid_names — directories in the store with no SKILL.md.
store_invalid_names() {
  local d
  [[ -d "$AGENTS_STORE" ]] || return 0
  for d in "$AGENTS_STORE"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/SKILL.md" ]] && continue
    d=${d%/}; printf '%s\n' "${d##*/}"
  done | sort
}

# lock_skill_names — the entries upstream records, read from its own lock.
# Keys sit at 4 spaces: "version" and "skills" are at 2, skill names one level
# in. Reading is enough — every write to this file is left to `skills remove`.
lock_skill_names() {
  [[ -f "$AGENTS_LOCK" ]] || return 0
  sed -n 's/^    "\([^"]*\)": {$/\1/p' "$AGENTS_LOCK" | sort
}

# store_all_names — every directory in the store, skill or not.
store_all_names() { cat <(store_skill_names) <(store_invalid_names) | sort -u; }

# store_local_names — store entries the lock does not claim.
#
# The lock is `skills`' own record of what it fetched, and it holds a source,
# a sourceUrl and a skillPath for each. An entry it has never heard of was not
# installed by it: somebody wrote that skill here by hand.
#
# This is what the manifest is authoritative *over*. Listing hand-authored
# skills in the manifest instead would be asking every machine to declare what
# only one of them has, and asking a person to edit this repo every time they
# write a skill — the number of them is unbounded and their names are nobody
# else's business. The host already knows which is which; read it off the host.
store_local_names() { comm -23 <(store_all_names) <(lock_skill_names); }

# skills_forget <name> — drop a skill from the store and the lock.
#
# `skills remove` enumerates the lock as well as the filesystem, so it removes
# an entry whose payload is already gone. Nothing here edits the lock: it is
# upstream's file, and upstream's own command keeps its bookkeeping consistent.
skills_forget() {
  skills_cli remove -g -s "$1" -y || warn "could not remove $1"
}

# skills_install — fetch the declared skills that are not in the store.
#
# `skills add` re-downloads and re-copies whatever it is given, whether or not
# the store already holds it, so calling it once per source on every run rewrote
# the whole store and reported no change. Only the missing names are requested,
# which makes a settled host free and the delta count honest. Refreshing what is
# already present is skills_refresh, and it is a separate, deliberate action.
#
# This also repairs an entry the lock claims but the store lacks: `skills add`
# fetches on the name it is given and does not consult the lock to decide, so a
# deleted payload comes back with no lock surgery.
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
        # `paste -` names stdin explicitly, which BSD paste requires; and
        # ${flags[@]+…} keeps bash 3.2 from calling an empty array unbound.
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

# mirror_set — the names each agent's skills directory should hold.
#
# Whatever the store holds: once install has run everything declared is in it,
# and a skill somebody wrote sits beside them precisely so all three agents
# load it. Under --dry-run install has not run, so what it said it would fetch
# counts too — the real run links those, and a plan that stops short of them is
# not the plan. On a real run `planned` is always false and this is the store.
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

# skills_refresh — pull upstream changes for everything already installed.
#
# This is upstream's own update path over the lock, which the prune pass has
# already reduced to exactly the manifest. One invocation, upstream's semantics,
# nothing here to keep in step with them.
skills_refresh() {
  delta "refreshing every installed skill from upstream"
  skills_cli update -g -y || warn "skills update reported a failure"
}

# skills_prune — remove what a source installed and the manifest no longer
# declares. This is what keeps the manifest authoritative.
#
# The lock decides what is in scope, so the set is exactly what it records
# minus what the manifest declares. That covers a payload still in the store
# and an entry whose payload went years ago, and it leaves alone anything the
# lock never fetched — which is the only safe reading of a directory this repo
# did not put there.
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

# skills_mirror — make each mirroring agent's skills directory match the store.
#
# A declared skill must be a link into the store. A real directory carrying a
# declared name is a stale full copy from an install that named the agent
# instead of the store; it is replaced, because the store is authoritative and
# the copy silently shadows it. Anything undeclared is left alone — Codex ships
# its own skills/.system/.
skills_mirror() {
  local agent dir target name link mirrored
  # The sweep below skips exactly this set, so the two halves cover every link
  # between them and neither touches the other's — nothing is linked and
  # unlinked in the same run.
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
      # A name the loop above owns has just been pointed at the store. Sweeping
      # it here too planned a link and its removal in the same run, and on a
      # real run deleted the link whenever an install had failed — churn on top
      # of a failure that was already reported.
      grep -qxF "$name" <<< "$mirrored" && continue
      if [[ ! -e "$link" ]]; then
        delta "$agent: removing dangling link $name"
      elif [[ "$link" -ef "$AGENTS_STORE/$name" ]]; then
        # Into the store, but the store no longer holds it under that name.
        delta "$agent: removing stale link $name"
      else
        continue
      fi
      plan "unmirror:$agent:$name"
      run rm -f "$link"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)
  done
}
