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
