#!/usr/bin/env bash
# lib/log.sh — logging helpers. Sourced by sync.sh.
# shellcheck shell=bash

if [[ -t 2 ]] || [[ -n "${FORCE_COLOR:-}" ]]; then
  agents_color() {
    case "$1" in
      red)    printf '\033[31m' ;;
      green)  printf '\033[32m' ;;
      yellow) printf '\033[33m' ;;
      blue)   printf '\033[34m' ;;
      dim)    printf '\033[2m' ;;
      bold)   printf '\033[1m' ;;
      reset)  printf '\033[0m' ;;
    esac
  }
else
  agents_color() { :; }
fi

log()  { printf '%s\n' "$*"; }
info() { agents_color blue;   printf '• %s\n' "$*"; agents_color reset; }
ok()   { agents_color green;  printf '✓ %s\n' "$*"; agents_color reset; }
warn() { agents_color yellow; printf '! %s\n' "$*" >&2; agents_color reset; }
fail() { agents_color red;    printf '✗ %s\n' "$*" >&2; agents_color reset; exit 1; }

# A delta is a change this run made, or would make under --dry-run. The counter
# is what makes idempotence observable: a converged host reports zero.
DELTAS=0
delta() { DELTAS=$((DELTAS + 1)); agents_color yellow; printf '~ %s\n' "$*"; agents_color reset; }

# problem <text> — a fact the sync found but will not act on by itself.
PROBLEMS=0
problem() { PROBLEMS=$((PROBLEMS + 1)); agents_color red; printf '✗ %s\n' "$*" >&2; agents_color reset; }

# problem_list <text> <newline-separated names> — one problem naming them all.
#
# A line per name is unreadable on a host that is far out of step: thirty-two
# declared skills missing printed thirty-two near-identical lines, then the same
# names again for each agent that mirrors them. The count is what is read; the
# names are what is acted on, so both stay.
problem_list() {
  local names n
  names=$(printf '%s\n' "$2" | grep -v '^[[:space:]]*$')
  [[ -n "$names" ]] || return 0
  n=$(printf '%s\n' "$names" | grep -c .)
  problem "$1 ($n): $(oneline "$names")"
}

# oneline <newline-separated> — the same names on one line, no trailing space.
oneline() { printf '%s\n' "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

# plan <key> / planned <key> — what this run would do, recorded as it decides.
#
# A dry run applies nothing, so verification necessarily reads the host as it
# stands and used to repeat the whole plan back as unresolved problems: a fresh
# host reported a hundred-odd failures and exited non-zero, burying the few
# findings the run would *not* have fixed. Recording the plan lets verification
# subtract it and report only the remainder.
#
# The ledger is consulted under --dry-run alone. On a real run the work has
# actually happened, and verification must read the result rather than trust
# that the command it invoked did what it said.
PLANNED=""
plan() { PLANNED="$PLANNED$1
"; }
planned() { [[ -n "${DRY_RUN:-}" ]] && grep -qxF "$1" <<< "$PLANNED"; }

# unplanned <newline-separated names> <key prefix> — those not already planned.
unplanned() {
  local prefix="$2" name out=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    planned "$prefix$name" && continue
    out="$out$name
"
  done <<< "$1"
  printf '%s' "$out"
}

stage() {
  local name="$1" fn="$2"
  agents_color bold; printf '\n── %s ──\n' "$name"; agents_color reset
  "$fn"
}

# run <cmd...> — execute, or under DRY_RUN report and skip. Callers count their
# own deltas; this only decides whether the command actually runs.
#
# stdin is closed for every command. These run inside `while read` loops, and a
# child that reads stdin — npx does — drains the loop's input, so the loop
# handles its first item and silently exits. Everything here is driven by
# arguments and `-y`, so nothing needs a terminal.
run() {
  if [[ -n "${DRY_RUN:-}" ]]; then
    agents_color dim; printf '  would run: %s\n' "$*"; agents_color reset
    return 0
  fi
  "$@" < /dev/null
}
