#!/usr/bin/env bash
# tests/fm-done-contract-guard.test.sh - the PR-delivery done contract guard in
# bin/fm-classify-lib.sh and the watcher absorb it earns in bin/fm-watch.sh.
#
# A ship task recorded as mode=no-mistakes or mode=direct-PR delivers through a
# pull request, so a `done:` with no PR link is not a completion. These cases pin
# the whole loop through public interfaces: the classifier withholds such a line
# and steers the worker through its own steering inbox, the reminder quotes the
# exact form bin/fm-dod-lib.sh writes into that mode's brief, a real done keeps
# its existing behavior byte for byte, local-only and unregistered tasks are
# untouched, and a reminder that goes unheeded still reaches firstmate along both
# bounded paths (the inbox re-ring ladder, and the guard's own reminder budget).
#
# The watcher-side absorb is driven through a real fm-watch.sh subprocess, so the
# assertion is behavior (no wake, no queue record) rather than the classifier's
# return code alone.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-dod-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
PR_URL='https://github.com/kunchenguid/firstmate/pull/4242'

TMP_ROOT=$(fm_test_tmproot fm-done-contract-guard-tests)

# A ship task ready to be classified: its recorded delivery mode plus a status log.
make_task() {  # <state> <id> <mode> [status lines...]
  local state=$1 id=$2 mode=$3
  shift 3
  {
    printf 'window=fmtest:%s\n' "$id"
    printf 'kind=ship\n'
    [ -z "$mode" ] || printf 'mode=%s\n' "$mode"
  } > "$state/$id.meta"
  : > "$state/$id.status"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$state/$id.status"; done
}

inbox_records() {  # <state> <id>
  local f count=0
  for f in "$1/$2.inbox"/*.msg; do
    [ -e "$f" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

newest_inbox_body() {  # <state> <id>
  local f newest=''
  for f in "$1/$2.inbox"/*.msg; do
    [ -e "$f" ] || continue
    newest=$f
  done
  [ -n "$newest" ] || return 1
  fm_task_inbox_body "$newest"
}

watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- the mechanical test itself ---------------------------------------------

test_pr_link_detection() {
  status_line_has_pr_link "done: PR $PR_URL checks green" \
    || fail "a real GitHub pull-request URL was not recognized"
  status_line_has_pr_link "done: PR https://gitlab.com/group/sub/proj/-/merge_requests/7" \
    || fail "a GitLab merge-request URL was not recognized"
  status_line_has_pr_link "done: PR $PR_URL." \
    || fail "a URL followed by sentence punctuation was not recognized"
  status_line_has_pr_link "done: local tests pass" \
    && fail "a done: with no link was read as carrying one"
  status_line_has_pr_link "done: see https://github.com/kunchenguid/firstmate" \
    && fail "a repository URL that is not a pull request was read as a PR link"
  status_line_has_pr_link "done: see https://github.com/kunchenguid/firstmate/pull/0" \
    && fail "a malformed pull-request number was read as a PR link"
  pass "the PR link test accepts exactly the pull-request URLs fm-pr-lib.sh validates"
}

test_contract_unmet_only_for_pr_delivery_modes() {
  local dir state
  dir="$TMP_ROOT/contract-scope"; state="$dir/state"; mkdir -p "$state"

  make_task "$state" nm no-mistakes 'done: local tests pass'
  status_done_contract_unmet "$state/nm.status" 'done: local tests pass' \
    || fail "a linkless done on a no-mistakes task was accepted"
  status_done_contract_unmet "$state/nm.status" "done: PR $PR_URL checks green" \
    && fail "a real no-mistakes done was rejected"

  make_task "$state" dp direct-PR 'done: pushed'
  status_done_contract_unmet "$state/dp.status" 'done: pushed' \
    || fail "a linkless done on a direct-PR task was accepted"
  status_done_contract_unmet "$state/dp.status" "done: PR $PR_URL" \
    && fail "a real direct-PR done was rejected"

  make_task "$state" lo local-only 'done: ready in branch fm/lo'
  status_done_contract_unmet "$state/lo.status" 'done: ready in branch fm/lo' \
    && fail "local-only was pulled into the PR-delivery contract"

  make_task "$state" scout '' 'done: report written'
  status_done_contract_unmet "$state/scout.status" 'done: report written' \
    && fail "a task with no recorded delivery mode was pulled into the contract"

  # Only the done verb is in scope: nothing else changes meaning for want of a link.
  status_done_contract_unmet "$state/nm.status" 'working: implemented the fix' \
    && fail "a working: line was judged against the done contract"
  status_done_contract_unmet "$state/nm.status" 'blocked: need a credential' \
    && fail "a blocked: line was judged against the done contract"
  pass "the done contract binds exactly the PR-delivery modes and exactly the done verb"
}

# --- a false done is withheld and the worker is steered ----------------------

test_false_done_is_withheld_and_steered() {
  local dir state body form
  dir="$TMP_ROOT/false-done"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes 'working: implementing' 'done: local tests pass'

  status_span_has_actionable "$state/t.status" 0 \
    && fail "a done: with no PR link was presented as an actionable captain event"

  [ "$(inbox_records "$state" t)" = 1 ] \
    || fail "the withheld done did not enqueue exactly one steering-inbox record"

  body=$(newest_inbox_body "$state" t) || fail "the steering record had no readable body"
  form=$(fm_dod_done_form no-mistakes t)
  case "$body" in
    *"$form"*) ;;
    *) fail "the reminder did not quote the exact required form '$form'" ;;
  esac
  case "$body" in
    *'done: local tests pass'*) ;;
    *) fail "the reminder did not quote the worker's own offending line" ;;
  esac
  case "$body" in
    *'mode=no-mistakes'*) ;;
    *) fail "the reminder did not name the task's recorded delivery contract" ;;
  esac

  status_done_guard_holds "$state/t.status" \
    || fail "the guard did not record that it is holding this task's newest done"
  pass "a linkless done is withheld from presentation and the worker is steered with the exact contract"
}

test_direct_pr_false_done_is_withheld() {
  local dir state
  dir="$TMP_ROOT/false-done-direct"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t direct-PR 'done: branch pushed, tests green'
  status_span_has_actionable "$state/t.status" 0 \
    && fail "a direct-PR done with no PR link was presented as actionable"
  [ "$(inbox_records "$state" t)" = 1 ] \
    || fail "the withheld direct-PR done did not steer the worker"
  pass "direct-PR is held to its own PR link the same way"
}

# --- a real done keeps exactly its existing behavior -------------------------

test_real_done_is_presented_unchanged() {
  local dir state event
  dir="$TMP_ROOT/real-done"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes "done: PR $PR_URL checks green"

  event=$(status_span_first_actionable "$state/t.status" 0) \
    || fail "a real done was not presented as actionable"
  [ "$event" = "done: PR $PR_URL checks green" ] \
    || fail "a real done was not presented verbatim: got '$event'"
  [ -d "$state/t.inbox" ] && fail "a real done steered the worker"
  [ -e "$state/.t.done-guard" ] && fail "a real done left guard state behind"
  status_done_guard_holds "$state/t.status" && fail "the guard claimed to hold a real done"
  pass "a done carrying its PR link is presented verbatim with no guard side effects"
}

test_a_real_done_releases_a_held_task() {
  local dir state event
  dir="$TMP_ROOT/release"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes 'done: local tests pass'
  status_span_has_actionable "$state/t.status" 0 && fail "the false done was presented"
  [ -e "$state/.t.done-guard" ] || fail "the guard recorded no hold to release"

  printf 'done: PR %s checks green\n' "$PR_URL" >> "$state/t.status"
  event=$(status_span_first_actionable "$state/t.status" 0) \
    || fail "the worker's corrected done was not presented"
  case "$event" in
    *"$PR_URL"*) ;;
    *) fail "the corrected done was not the presented event: got '$event'" ;;
  esac
  [ -e "$state/.t.done-guard" ] && fail "the guard was not released by the corrected done"
  pass "the worker's corrected done releases the hold and is presented"
}

# --- modes and tasks the guard must not touch --------------------------------

test_local_only_done_is_untouched() {
  local dir state event
  dir="$TMP_ROOT/local-only"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t local-only 'done: ready in branch fm/t'
  event=$(status_span_first_actionable "$state/t.status" 0) \
    || fail "a local-only done was not presented as actionable"
  [ "$event" = 'done: ready in branch fm/t' ] \
    || fail "a local-only done was not presented verbatim: got '$event'"
  [ -d "$state/t.inbox" ] && fail "a local-only done steered the worker"
  [ -e "$state/.t.done-guard" ] && fail "a local-only done left guard state behind"
  pass "local-only keeps its own terminal contract, unchanged and unsteered"
}

test_unregistered_task_done_is_untouched() {
  local dir state
  dir="$TMP_ROOT/no-mode"; state="$dir/state"; mkdir -p "$state"
  # A scout, a secondmate, or a foreign log: no recorded delivery mode at all.
  make_task "$state" t '' 'done: report written to data/t/report.md'
  status_span_has_actionable "$state/t.status" 0 \
    || fail "a done on a task with no recorded delivery mode was withheld"
  [ -d "$state/t.inbox" ] && fail "a task with no delivery mode was steered"
  printf 'done: report written\n' > "$state/orphan.status"
  status_span_has_actionable "$state/orphan.status" 0 \
    || fail "a done on a log with no task record at all was withheld"
  pass "a task with no recorded PR-delivery mode is classified exactly as before"
}

# --- the reminder that goes unheeded still reaches firstmate -----------------

test_unheeded_reminder_rides_the_inbox_escalation_ladder() {
  local dir state action
  dir="$TMP_ROOT/ladder"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes 'done: local tests pass'
  status_span_has_actionable "$state/t.status" 0 && fail "the false done was presented"
  [ "$(inbox_records "$state" t)" = 1 ] || fail "no steering record to escalate"

  # The reminder is an ORDINARY record, so the watcher's existing re-ring ladder
  # owns it: with the delivery budget spent it becomes a stale wake firstmate
  # handles. A fire-and-forget record would be skipped by the ladder entirely,
  # which is exactly the silent-swallow this asserts against.
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    fm_task_inbox_due_action "$state" t)
  case "$action" in
    escalate\ *) ;;
    *) fail "an unacknowledged contract reminder does not escalate to firstmate: got '$action'" ;;
  esac
  pass "an unacknowledged contract reminder escalates to firstmate through the inbox ladder"
}

test_reminder_budget_is_bounded() {
  local dir state i
  dir="$TMP_ROOT/budget"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t direct-PR
  : > "$state/t.status"

  # Each distinct linkless done spends one reminder. Once the budget is spent the
  # guard stops absorbing: the next one is presented to firstmate unchanged.
  i=1
  while [ "$i" -le "$(fm_done_guard_reminder_max)" ]; do
    printf 'done: attempt %s\n' "$i" >> "$state/t.status"
    status_span_has_actionable "$state/t.status" 0 \
      && fail "reminder $i was not spent: the done was presented instead of steered"
    i=$((i + 1))
  done
  [ "$(inbox_records "$state" t)" = "$(fm_done_guard_reminder_max)" ] \
    || fail "the guard did not spend exactly its reminder budget"

  printf 'done: attempt past the budget\n' >> "$state/t.status"
  status_span_has_actionable "$state/t.status" 0 \
    || fail "a linkless done past the reminder budget was still withheld from firstmate"
  [ "$(inbox_records "$state" t)" = "$(fm_done_guard_reminder_max)" ] \
    || fail "the guard kept steering past its budget"
  pass "the reminder budget is bounded: past it, a linkless done reaches firstmate"
}

test_one_line_never_spends_two_reminders() {
  local dir state
  dir="$TMP_ROOT/one-line"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes 'done: local tests pass'
  # The signal path and the heartbeat backstop keep independent cursors, so the
  # same append is classified more than once. That must not burn the budget.
  status_span_has_actionable "$state/t.status" 0 && fail "the false done was presented"
  status_span_has_actionable "$state/t.status" 0 && fail "the re-read false done was presented"
  status_span_has_actionable "$state/t.status" 0 && fail "the re-read false done was presented"
  [ "$(inbox_records "$state" t)" = 1 ] \
    || fail "re-classifying one line enqueued more than one reminder"
  pass "re-classifying one withheld line neither re-steers the worker nor spends more budget"
}

test_unsteerable_worker_is_presented() {
  local dir state
  dir="$TMP_ROOT/unsteerable"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes 'done: local tests pass'
  # The inbox cannot be created: the guard has no way to steer the worker, so it
  # must present the event rather than withhold a captain-facing done for nothing.
  printf 'not a directory\n' > "$state/t.inbox"
  # The inbox library's own mkdir diagnostic is the expected noise here.
  status_span_has_actionable "$state/t.status" 0 2>/dev/null \
    || fail "a done was withheld even though the worker could not be steered"
  pass "a worker that cannot be steered has its done presented instead of withheld"
}

test_guard_steers_without_the_inbox_library_preloaded() {
  local dir state records
  dir="$TMP_ROOT/lazy-load"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes 'done: local tests pass'
  # The away-mode supervisor loads this classifier without the steering-inbox
  # library, so the guard has to be able to steer on its own rather than silently
  # losing the withheld done. Driven through a shell that loads nothing else.
  bash -c '
    set -u
    . "$1/bin/fm-classify-lib.sh"
    status_span_has_actionable "$2" 0 && exit 1
    exit 0
  ' _ "$ROOT" "$state/t.status" || fail "the done was presented when only the classifier was loaded"
  records=$(inbox_records "$state" t)
  [ "$records" = 1 ] \
    || fail "the classifier alone did not steer the worker: $records records in the task's inbox"
  pass "the classifier steers a worker even when no consumer preloaded the steering-inbox library"
}

# --- the watcher-side behavior ------------------------------------------------

test_watcher_absorbs_a_withheld_done() {
  local dir state fakebin out pid
  dir=$(make_case watcher-false-done); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  make_task "$state" task no-mistakes 'working: implementing'
  prime_status_seen "$state" "$state/task.status"
  # The crew stopped its turn with no running pipeline and no busy pane: without
  # the guard this wake surfaces, which is how a false done reached firstmate.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  printf 'done: local tests pass\n' >> "$state/task.status"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "the watcher woke firstmate for a done: with no PR link: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the withheld done printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "the withheld done enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "the withheld done did not advance its suppressor"
  [ -d "$state/task.inbox" ] || fail "the watcher absorbed the done without steering the worker"
  reap "$pid"
  pass "the watcher absorbs a withheld done and steers the worker instead of waking firstmate"
}

test_watcher_still_surfaces_a_real_done() {
  local dir state fakebin out drain_out pid
  dir=$(make_case watcher-real-done); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  make_task "$state" task no-mistakes 'working: implementing'
  prime_status_seen "$state" "$state/task.status"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  printf 'done: PR %s checks green\n' "$PR_URL" >> "$state/task.status"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the watcher did not wake firstmate for a real done"
  grep -F "signal: $state/task.status" "$out" >/dev/null \
    || fail "the watcher did not print the surfaced done signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "the drain after a real done failed"
  grep -F "$state/task.status" "$drain_out" >/dev/null \
    || fail "the real done was not queued for firstmate"
  [ -d "$state/task.inbox" ] && fail "a real done steered the worker"
  pass "a done carrying its PR link still wakes firstmate exactly as before"
}

test_pr_link_detection
test_contract_unmet_only_for_pr_delivery_modes
test_false_done_is_withheld_and_steered
test_direct_pr_false_done_is_withheld
test_real_done_is_presented_unchanged
test_a_real_done_releases_a_held_task
test_local_only_done_is_untouched
test_unregistered_task_done_is_untouched
test_unheeded_reminder_rides_the_inbox_escalation_ladder
test_reminder_budget_is_bounded
test_one_line_never_spends_two_reminders
test_unsteerable_worker_is_presented
test_guard_steers_without_the_inbox_library_preloaded
test_watcher_absorbs_a_withheld_done
test_watcher_still_surfaces_a_real_done
