#!/usr/bin/env bash
# fm-push-lock.sh - machine-wide serialization for the git operations that
# publish work: `git push`, and the merge commands that land a branch.
#
# WHY. Firstmate runs many workers at once, each in its own worktree, and
# nothing coordinated the moment two of them reached the forge together. The
# fleet has paid for that twice already: a validation attestation is taken
# against one head, and a concurrent push moves the branch before the merge
# lands, so the attestation no longer describes what shipped
# (data/learnings.md). Publication is the one step where concurrency buys
# nothing - it is seconds of work - so it is cheap to make it strictly one at a
# time.
#
# SCOPE, deliberately minimal. One lock, machine-wide, held only across the
# publishing command itself. No priority queue, no daemon, no fairness beyond
# first-come. It covers what firstmate controls: bin/fm-pr-merge.sh,
# bin/fm-merge-local.sh, and any push a crewmate runs through the wrapper below.
# A push made from inside another tool's own pipeline is outside this lock, and
# nothing here pretends otherwise.
#
# WHY NOT AN EXISTING LIB. bin/fm-wake-lib.sh owns the portable lock primitive
# this builds on (flock is absent on macOS), but every lock it takes is
# home-scoped, and this one must be machine-scoped so separate firstmate homes
# on one machine still serialize against each other. It also has to be directly
# runnable, because a crewmate brief hands the worker a command to type; a
# sourced library cannot be that. So this file is both: a wrapper when
# executed, and the acquire/release pair when sourced by firstmate's own merge
# scripts.
#
# LOCATION. The lock lives outside any home, next to the other machine-wide
# firstmate records, at $XDG_STATE_HOME/firstmate (default ~/.local/state).
#
# Usage (wrapper - the form a brief hands a worker):
#   bin/fm-push-lock.sh -- git push -u origin fm/<task-id>
#   bin/fm-push-lock.sh --timeout 300 -- git push --force-with-lease
#   bin/fm-push-lock.sh --label "merge PR 42" -- gh-axi pr merge 42 --squash
#
# Usage (library - firstmate's own merge scripts):
#   . bin/fm-push-lock.sh
#   fm_push_lock_acquire "merge <url>" || exit 1
#   trap 'fm_push_lock_release' EXIT
#
# Options:
#   --timeout <seconds>  how long to wait for the lock before refusing
#                        (default: $FM_PUSH_LOCK_TIMEOUT_SECS, then 900)
#   --label <text>       what to call this operation in the waiting message
#   -h, --help           print this header
#
# Environment:
#   FM_PUSH_LOCK_DIR           directory holding the lock (default:
#                              ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate)
#   FM_PUSH_LOCK_TIMEOUT_SECS  default wait bound in whole seconds
#   FM_PUSH_LOCK_HELD          set by an acquiring process and inherited by its
#                              children, so a wrapped command that itself
#                              acquires the same lock proceeds instead of
#                              waiting on its own parent
#
# Exit status is the wrapped command's own, except 2 for a usage error and 124
# when the wait bound elapsed with another process still holding the lock. The
# refusal names the holding pid so the operator can see what to wait for.

FM_PUSH_LOCK_DIR_DEFAULT="${XDG_STATE_HOME:-$HOME/.local/state}/firstmate"
FM_PUSH_LOCK_TIMEOUT_DEFAULT=900
# Poll cadence while waiting. A push is seconds of work, so a one-second sample
# is fine-grained relative to the hold it is waiting out.
FM_PUSH_LOCK_POLL_SECS=1

_FM_PUSH_LOCK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_PUSH_LOCK_SCRIPT_DIR/fm-wake-lib.sh"

# This frame's own hold, so release only removes a lock this frame took and a
# reentrant acquire is a no-op rather than an early release of its parent's.
FM_PUSH_LOCK_ACQUIRED=0

fm_push_lock_path() {
  printf '%s/push.lock\n' "${FM_PUSH_LOCK_DIR:-$FM_PUSH_LOCK_DIR_DEFAULT}"
}

_fm_push_lock_timeout() {
  local secs=${1:-}
  [ -n "$secs" ] || secs=${FM_PUSH_LOCK_TIMEOUT_SECS:-$FM_PUSH_LOCK_TIMEOUT_DEFAULT}
  case "$secs" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  printf '%s\n' "$secs"
}

# fm_push_lock_acquire [label] [timeout-seconds]
#
# 0 = the caller may publish (either it took the lock, or an ancestor already
# holds it); 124 = the wait bound elapsed with a live holder; 1 = the lock
# could not be prepared at all.
fm_push_lock_acquire() {
  local label=${1:-publish} timeout lock parent deadline now holder announced=0
  FM_PUSH_LOCK_ACQUIRED=0
  lock=$(fm_push_lock_path) || return 1
  parent=${FM_PUSH_LOCK_HELD:-}
  if [ -n "$parent" ] && [ "$parent" = "$lock" ]; then
    return 0
  fi
  if ! timeout=$(_fm_push_lock_timeout "${2:-}"); then
    printf 'fm-push-lock: timeout must be a positive whole number of seconds\n' >&2
    return 1
  fi
  if ! mkdir -p "$(dirname "$lock")" 2>/dev/null; then
    printf 'fm-push-lock: cannot create the lock directory %s\n' "$(dirname "$lock")" >&2
    return 1
  fi

  if ! fm_lock_try_acquire "$lock"; then
    deadline=$(( $(date +%s) + timeout ))
    while :; do
      now=$(date +%s)
      [ "$now" -lt "$deadline" ] || break
      if [ "$announced" -eq 0 ]; then
        holder=${FM_LOCK_HELD_PID:-unknown}
        printf 'fm-push-lock: another push or merge is in flight on this machine (pid %s); waiting up to %ss before %s\n' \
          "$holder" "$timeout" "$label" >&2
        announced=1
      fi
      sleep "$FM_PUSH_LOCK_POLL_SECS"
      if fm_lock_try_acquire "$lock"; then
        FM_PUSH_LOCK_ACQUIRED=1
        FM_PUSH_LOCK_HELD=$lock
        export FM_PUSH_LOCK_HELD
        return 0
      fi
    done
    holder=${FM_LOCK_HELD_PID:-unknown}
    printf 'fm-push-lock: gave up after %ss waiting for the machine push lock (held by pid %s) before %s; retry when that push or merge finishes, or raise --timeout\n' \
      "$timeout" "$holder" "$label" >&2
    return 124
  fi
  FM_PUSH_LOCK_ACQUIRED=1
  FM_PUSH_LOCK_HELD=$lock
  export FM_PUSH_LOCK_HELD
  return 0
}

fm_push_lock_release() {
  local lock
  [ "$FM_PUSH_LOCK_ACQUIRED" -eq 1 ] || return 0
  lock=$(fm_push_lock_path) || return 0
  fm_lock_release "$lock"
  FM_PUSH_LOCK_ACQUIRED=0
  FM_PUSH_LOCK_HELD=
  export FM_PUSH_LOCK_HELD
  return 0
}

_fm_push_lock_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$_FM_PUSH_LOCK_SCRIPT_DIR/fm-push-lock.sh" >&2
}

_fm_push_lock_main() {
  local timeout='' label='' rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _fm_push_lock_usage; return 0 ;;
      --timeout)
        [ "$#" -gt 1 ] || { printf 'fm-push-lock: --timeout requires a positive whole number of seconds\n' >&2; return 2; }
        timeout=$2
        shift 2
        ;;
      --timeout=*) timeout=${1#--timeout=}; shift ;;
      --label)
        [ "$#" -gt 1 ] || { printf 'fm-push-lock: --label requires text\n' >&2; return 2; }
        label=$2
        shift 2
        ;;
      --label=*) label=${1#--label=}; shift ;;
      --) shift; break ;;
      *)
        printf 'fm-push-lock: unknown option %s (the command must follow --)\n' "$1" >&2
        return 2
        ;;
    esac
  done
  if [ "$#" -eq 0 ]; then
    printf 'fm-push-lock: no command given; usage: fm-push-lock.sh [--timeout <secs>] [--label <text>] -- <command> [args...]\n' >&2
    return 2
  fi
  [ -n "$label" ] || label="running $1"
  fm_push_lock_acquire "$label" "$timeout" || return $?
  # The lock covers exactly the wrapped command. Release on every exit path,
  # including a signal, so an interrupted push never strands the machine lock
  # for the length of the next caller's wait bound.
  trap 'fm_push_lock_release; exit 130' INT
  trap 'fm_push_lock_release; exit 143' TERM
  "$@" || rc=$?
  trap - INT TERM
  fm_push_lock_release
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _fm_push_lock_main "$@"
  exit $?
fi
