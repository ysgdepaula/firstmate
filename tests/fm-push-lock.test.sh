#!/usr/bin/env bash
# Contract tests for bin/fm-push-lock.sh - the machine-wide publication lock
# that serializes pushes and merges across every firstmate home on one machine.
#
# The behavior that matters here is exclusion: two callers must not publish at
# the same time, a caller must be told what it is waiting for, a bounded wait
# must refuse rather than hang forever, and the lock must never survive the
# command it wrapped.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCKER="$ROOT/bin/fm-push-lock.sh"

assert_present "$LOCKER" "bin/fm-push-lock.sh is missing"
[ -x "$LOCKER" ] || fail "bin/fm-push-lock.sh must be executable"

# Each case gets its own lock directory, so the cases never wait on each other
# and never on the operator's real lock.

test_wrapper_runs_the_command_and_passes_its_status() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-push-lock-run) || fail "could not create a temp root"

  out=$(FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" -- printf 'published\n') \
    || fail "the wrapper must run the command it was given"
  [ "$out" = published ] || fail "the wrapper must pass the command's output through, got: $out"

  rc=0
  FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" -- sh -c 'exit 7' || rc=$?
  [ "$rc" -eq 7 ] || fail "the wrapper must exit with the command's own status, got $rc"

  rc=0
  FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" -- true >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "the lock must be released for the next caller, got $rc"

  rc=0
  FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "no command must be a usage error, got $rc"
  rc=0
  FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" --nonsense -- true 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown option must be a usage error, got $rc"

  pass "the wrapper runs its command, passes its status, and releases the lock"
}

test_two_publications_never_overlap() {
  local tmp witness holder_pid waited order err
  tmp=$(fm_test_tmproot fm-push-lock-exclusion) || fail "could not create a temp root"
  witness="$tmp/witness"
  : >"$witness"

  # The holder brackets its own critical section in a shared witness file, so
  # overlap is observable without depending on wall-clock timing.
  FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" -- sh -c \
    "printf 'enter holder\n' >>'$witness'; sleep 3; printf 'exit holder\n' >>'$witness'" &
  holder_pid=$!
  waited=0
  while [ "$waited" -lt 100 ]; do
    grep -Fq 'enter holder' "$witness" 2>/dev/null && break
    sleep 0.1
    waited=$((waited + 1))
  done
  grep -Fq 'enter holder' "$witness" || { kill "$holder_pid" 2>/dev/null; fail "the holder never started"; }

  err=$(FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" --timeout 60 --label 'second push' -- sh -c \
    "printf 'enter waiter\n' >>'$witness'; printf 'exit waiter\n' >>'$witness'" 2>&1) \
    || { kill "$holder_pid" 2>/dev/null; fail "the queued publication failed: $err"; }
  wait "$holder_pid" || fail "the holding publication failed"

  case "$err" in
    *"another push or merge is in flight on this machine"*) ;;
    *) fail "a waiting caller must say what it is waiting for: $err" ;;
  esac
  case "$err" in
    *"second push"*) ;;
    *) fail "the waiting message must name the operation: $err" ;;
  esac
  order=$(paste -sd, - <"$witness")
  [ "$order" = "enter holder,exit holder,enter waiter,exit waiter" ] \
    || fail "two publications must not overlap: $order"

  pass "a second publication waits for the first instead of running beside it"
}

test_bounded_wait_refuses_instead_of_hanging() {
  local tmp holder_pid rc err waited
  tmp=$(fm_test_tmproot fm-push-lock-timeout) || fail "could not create a temp root"

  FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" -- sh -c "printf 'held\n' >'$tmp/held'; sleep 6" &
  holder_pid=$!
  waited=0
  while [ "$waited" -lt 100 ]; do
    [ -s "$tmp/held" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$tmp/held" ] || { kill "$holder_pid" 2>/dev/null; fail "the holder never started"; }

  rc=0
  err=$(FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" --timeout 1 --label 'late push' -- \
    sh -c "printf 'ran\n' >'$tmp/ran'" 2>&1) || rc=$?
  kill "$holder_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null || true

  [ "$rc" -eq 124 ] || fail "an elapsed wait bound must refuse with 124, got $rc"
  [ ! -e "$tmp/ran" ] || fail "a refused caller must not run its command"
  case "$err" in
    *"gave up after 1s"*) ;;
    *) fail "the refusal must say the wait bound elapsed: $err" ;;
  esac

  pass "a bounded wait refuses with the reason instead of hanging or publishing anyway"
}

test_a_nested_publication_proceeds_under_its_parent() {
  local tmp out
  tmp=$(fm_test_tmproot fm-push-lock-nested) || fail "could not create a temp root"

  # A merge script run under the wrapper must not deadlock against the hold its
  # own caller already took.
  out=$(FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" --timeout 3 -- \
    "$LOCKER" --timeout 3 -- printf 'nested\n' 2>&1) \
    || fail "a nested publication must proceed under its parent's hold: $out"
  [ "$out" = nested ] || fail "the nested command must run exactly once, got: $out"

  pass "a nested publication proceeds under its parent's hold instead of deadlocking"
}

test_a_dead_holder_never_wedges_the_machine() {
  local tmp rc waited
  tmp=$(fm_test_tmproot fm-push-lock-dead) || fail "could not create a temp root"

  # A holder killed hard leaves the lock behind. The next caller must recover it
  # rather than treat the machine as permanently busy.
  FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" -- sh -c "printf 'held\n' >'$tmp/held'; sleep 30" 2>/dev/null &
  waited=0
  while [ "$waited" -lt 100 ]; do
    [ -s "$tmp/held" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$tmp/held" ] || fail "the holder never started"
  pkill -KILL -P $! 2>/dev/null || true
  kill -KILL $! 2>/dev/null || true
  wait 2>/dev/null || true

  rc=0
  FM_PUSH_LOCK_DIR="$tmp/lock" "$LOCKER" --timeout 30 -- true >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a dead holder's lock must be recovered, got $rc"

  pass "a lock left by a killed holder is recovered instead of wedging every later push"
}

test_wrapper_runs_the_command_and_passes_its_status
test_two_publications_never_overlap
test_bounded_wait_refuses_instead_of_hanging
test_a_nested_publication_proceeds_under_its_parent
test_a_dead_holder_never_wedges_the_machine
