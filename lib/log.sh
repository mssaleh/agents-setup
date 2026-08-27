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

# A converged host reports zero. That is the signal.
DELTAS=0
delta() { DELTAS=$((DELTAS + 1)); agents_color yellow; printf '~ %s\n' "$*"; agents_color reset; }

# A fact found but not acted on.
PROBLEMS=0
problem() { PROBLEMS=$((PROBLEMS + 1)); agents_color red; printf '✗ %s\n' "$*" >&2; agents_color reset; }

# One line per kind, not per name: a host far out of step otherwise prints the
# same thirty-two names once per check.
problem_list() {
  local names n
  names=$(printf '%s\n' "$2" | grep -v '^[[:space:]]*$')
  [[ -n "$names" ]] || return 0
  n=$(printf '%s\n' "$names" | grep -c .)
  problem "$1 ($n): $(oneline "$names")"
}

oneline() { printf '%s\n' "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

# What this run would do, so --dry-run verification can subtract it instead of
# repeating the plan back as failures. Consulted under --dry-run alone: a real
# run must read the result, not trust the command it invoked.
PLANNED=""
plan() { PLANNED="$PLANNED$1
"; }
planned() { [[ -n "${DRY_RUN:-}" ]] && grep -qxF "$1" <<< "$PLANNED"; }

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

# stdin is closed for every child: npx reads it, which would drain the enclosing
# `while read` loop, or the script itself when piped from curl.
run() {
  if [[ -n "${DRY_RUN:-}" ]]; then
    agents_color dim; printf '  would run: %s\n' "$*"; agents_color reset
    return 0
  fi
  "$@" < /dev/null
}
