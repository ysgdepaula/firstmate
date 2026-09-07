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
# return code alone. The stale-path cases use a capturable backend on purpose:
# with the fake `fmtest:` window this suite first shipped, the pane capture fails
# and the window is skipped before the branch under test ever runs, so those
# assertions would pass while proving nothing.
#
# The other paths that must agree with the guard have their regressions with the
# code that owns them: bin/fm-crew-state.sh in tests/fm-crew-state.test.sh, and
# the secondmate parent-channel ledger in tests/fm-inactive-reconcile.test.sh.
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
    || fail "a GitHub pull-request URL was not recognized"
  status_line_has_pr_link "done: PR https://gitlab.com/group/sub/proj/-/merge_requests/7" \
    || fail "a GitLab merge-request URL was not recognized"
  status_line_has_pr_link "done: PR $PR_URL." \
    || fail "a URL followed by sentence punctuation was not recognized"
  # The shape test, not a forge check: a pull request the fleet's merge polling
  # cannot address is still a delivered pull request, and withholding it would
  # steer a worker that did exactly what its contract asked.
  status_line_has_pr_link "done: PR https://git.corp.example/team/svc/pull/12 checks green" \
    || fail "a pull request on an unsupported host was read as no link at all"
  # A pasted review URL carries whatever the browser hung off the number, and a
  # one-digit pull request must be read exactly like a many-digit one.
  status_line_has_pr_link "done: PR https://github.com/o/r/pull/7/files checks green" \
    || fail "a single-digit pull request with a path suffix was read as no link"
  status_line_has_pr_link "done: PR https://github.com/o/r/pull/7#issuecomment-1 checks green" \
    || fail "a single-digit pull request with a fragment was read as no link"
  status_line_has_pr_link "done: PR https://github.com/o/r/pull/7?w=1 checks green" \
    || fail "a single-digit pull request with a query was read as no link"
  status_line_has_pr_link "done: PR https://github.com/o/r/pull/12/files checks green" \
    || fail "a multi-digit pull request with a path suffix was read as no link"
  status_line_has_pr_link "done: PR https://gitlab.com/g/p/-/merge_requests/3/diffs" \
    || fail "a single-digit merge request with a path suffix was read as no link"
  # Prose wraps a pasted URL on both sides, and a worker that brackets its link
  # has still delivered the pull request.
  status_line_has_pr_link "done: PR (https://github.com/o/r/pull/7) checks green" \
    || fail "a parenthesized pull-request URL was read as no link"
  status_line_has_pr_link "done: PR <https://github.com/o/r/pull/7> checks green" \
    || fail "an angle-bracketed pull-request URL was read as no link"
  status_line_has_pr_link 'done: PR "https://github.com/o/r/pull/12" checks green' \
    || fail "a quoted pull-request URL was read as no link"
  status_line_has_pr_link "done: PR [https://gitlab.com/g/p/-/merge_requests/3] shipped" \
    || fail "a bracketed merge-request URL was read as no link"
  # bin/fm-dod-lib.sh hands the worker its terminal line inside a code span, so
  # an agent echoing that markdown around the substituted URL is a real shape.
  status_line_has_pr_link "done: PR \`https://github.com/o/r/pull/7\` checks green" \
    || fail "a code-span pull-request URL was read as no link"
  status_line_has_pr_link "done: PR **https://github.com/o/r/pull/7** checks green" \
    || fail "an emphasized pull-request URL was read as no link"
  status_line_has_pr_link "done: PR [#4242](https://github.com/o/r/pull/4242) checks green" \
    || fail "a markdown-linked pull-request URL was read as no link"
  status_line_has_pr_link "done: PR [!3](https://gitlab.com/g/p/-/merge_requests/3) shipped" \
    || fail "a markdown-linked merge-request URL was read as no link"
  status_line_has_pr_link "done: local tests pass" \
    && fail "a done: with no link was read as carrying one"
  status_line_has_pr_link "done: everything green, opening the pull request next" \
    && fail "prose naming a pull request with no URL at all was read as a link"
  status_line_has_pr_link "done: see [the repo](https://github.com/kunchenguid/firstmate)" \
    && fail "a markdown-linked repository URL that is not a pull request was read as a PR link"
  status_line_has_pr_link "done: see (https://github.com/kunchenguid/firstmate)" \
    && fail "a bracketed repository URL that is not a pull request was read as a PR link"
  status_line_has_pr_link "done: see https://github.com/kunchenguid/firstmate" \
    && fail "a repository URL that is not a pull request was read as a PR link"
  status_line_has_pr_link "done: see https://github.com/kunchenguid/firstmate/pull/0" \
    && fail "a malformed pull-request number was read as a PR link"
  status_line_has_pr_link "done: see https://github.com/o/r/pull/notanumber" \
    && fail "a non-numeric pull-request id was read as a PR link"
  status_line_has_pr_link "done: see https://github.com/o/r/pull/0/files" \
    && fail "a malformed pull-request number with a suffix was read as a PR link"
  local spelling suffix
  for spelling in pull -/merge_requests; do
    for suffix in 7oops 12oops 7oops/files '12oops?w=1' '12oops#comment' '12oops?next=/pull/7' 7-1 7.1; do
      status_line_has_pr_link "done: PR https://git.corp.example/team/svc/$spelling/$suffix" \
        && fail "a malformed request number was accepted: $spelling/$suffix"
    done
    for suffix in '12/files' '12?w=1' '12#comment' '12?next=/pull/invalid'; do
      status_line_has_pr_link "done: PR https://git.corp.example/team/svc/$spelling/$suffix" \
        || fail "a browser suffix was rejected: $spelling/$suffix"
    done
  done
  pass "the PR link test accepts a delivered pull request on any host and nothing else"
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
  status_done_guard_holds "$state/t.status" && fail "the guard was not released by the corrected done"
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

test_a_reappended_identical_done_is_steered_again() {
  local dir state handled oldest
  dir="$TMP_ROOT/reappended"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes 'done: local tests pass'

  # First linkless done: withheld, one reminder spent.
  status_span_has_actionable "$state/t.status" 0 && fail "the first linkless done was presented"
  [ "$(inbox_records "$state" t)" = 1 ] || fail "the first linkless done did not steer the worker"

  # The worker acknowledges the reminder the way its brief tells it to: the move
  # into handled/ IS the acknowledgement (bin/fm-task-inbox-lib.sh owns that
  # contract), so nothing is left for the re-ring ladder to escalate.
  handled=$(fm_task_inbox_handled_dir "$state" t)
  mkdir -p "$handled"
  oldest=$(fm_task_inbox_oldest_unhandled "$state" t) \
    || fail "the contract reminder was not an escalation-tracked record"
  mv "$oldest" "$handled/" || fail "the worker could not acknowledge the reminder"
  [ "$(inbox_records "$state" t)" = 0 ] || fail "the acknowledged reminder is still unhandled"
  [ "$(fm_task_inbox_due_action "$state" t)" = quiet ] \
    || fail "an acknowledged reminder still has the ladder holding something"

  printf 'working: retrying\n' >> "$state/t.status"
  status_span_has_actionable "$state/t.status" 0 >/dev/null

  # The SAME text appended again is a new line, not a second cursor re-reading
  # the old one: the worker moved on and wrote the false done a second time, so
  # it must be steered again and spend budget like any other new linkless done.
  printf 'done: local tests pass\n' >> "$state/t.status"
  status_span_has_actionable "$state/t.status" 0 && fail "the re-appended linkless done was presented"
  [ "$(inbox_records "$state" t)" = 1 ] \
    || fail "a re-appended identical linkless done neither steered the worker nor left the ladder anything to escalate"

  # The divergence, so this cannot pass vacuously: re-reading that same append
  # from another cursor still enqueues nothing more.
  status_span_has_actionable "$state/t.status" 0 && fail "the re-read of the re-appended done was presented"
  [ "$(inbox_records "$state" t)" = 1 ] \
    || fail "re-classifying one append enqueued a second reminder"

  # Budget really was spent twice, so the guard is at its documented bound: the
  # next linkless done reaches firstmate unchanged.
  printf 'done: still just local tests\n' >> "$state/t.status"
  status_span_has_actionable "$state/t.status" 0 \
    || fail "the second reminder did not spend budget: a third linkless done was still withheld"
  status_done_guard_holds "$state/t.status" \
    && fail "the guard claims to hold a line whose budget it has spent"
  pass "a worker that re-writes the same linkless done is steered again and still reaches its bound"
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

# --- the guard judges current state, never history ---------------------------

test_guard_ignores_historical_done_lines() {
  local dir state records
  dir="$TMP_ROOT/historical"; state="$dir/state"; mkdir -p "$state"
  # A no-mistakes log always ends up holding an earlier linkless handoff done:,
  # because that is exactly what the mode's brief asks the worker to append. A
  # whole-log re-read (the watcher's stale path passes offset 0 literally) must
  # not steer a worker about that old line hours after it delivered.
  make_task "$state" t no-mistakes \
    'working: implementing' \
    'done: implemented the parser' \
    'working: no-mistakes running' \
    "done: PR $PR_URL checks green"

  local event
  event=$(status_span_first_actionable "$state/t.status" 0) \
    || fail "the delivered done was not presented on a whole-log read"
  [ "$event" = "done: PR $PR_URL checks green" ] \
    || fail "a whole-log read presented more than the delivered done: '$event'"
  [ "$(inbox_records "$state" t)" = 0 ] \
    || fail "a whole-log re-read steered a worker about a historical done"
  [ -e "$state/.t.done-guard" ] && fail "a historical done left guard state behind"

  # Re-read the same whole log again: still no steer, and still no false wake to
  # escalate later through the never-acknowledged reminder.
  status_span_has_actionable "$state/t.status" 0 >/dev/null
  [ "$(inbox_records "$state" t)" = 0 ] \
    || fail "a repeated whole-log re-read steered the worker about a historical done"
  pass "a whole-log re-read neither steers a worker about a done it has moved past nor re-presents it"
}

# One span classification covers every byte appended since the cursor, so a
# linkless done can be seen for the FIRST time already non-newest: the worker
# appended it and a `working:` line inside the same window. Dropping that one
# would arm neither bounded path - no reminder is written and no event reaches
# firstmate - so it is presented instead, which is what happened before the guard
# existed and is the safe direction.
test_a_first_sight_non_newest_linkless_done_is_not_swallowed() {
  local dir state event
  dir="$TMP_ROOT/first-sight"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes \
    'done: local tests pass' \
    'working: starting no-mistakes'

  event=$(status_span_first_actionable "$state/t.status" 0) \
    || fail "a linkless done seen first as a non-newest line was presented to no one and steered no one"
  [ "$event" = 'done: local tests pass' ] \
    || fail "the unjudged done was not the presented event: '$event'"

  # The divergence: once that same line HAS been judged at its own position, the
  # replay is dropped exactly as before. Build the same log one append at a time
  # so the guard judges the done while it is still the newest line.
  make_task "$state" u no-mistakes 'done: local tests pass'
  status_span_has_actionable "$state/u.status" 0 \
    && fail "the linkless done was presented instead of withheld while newest"
  [ "$(inbox_records "$state" u)" = 1 ] || fail "the newest linkless done did not steer the worker"
  printf 'working: starting no-mistakes\n' >> "$state/u.status"
  status_span_has_actionable "$state/u.status" 0 \
    && fail "an already-judged linkless done was re-presented by a whole-log re-read"
  [ "$(inbox_records "$state" u)" = 1 ] \
    || fail "an already-judged linkless done was steered a second time"
  pass "a linkless done is dropped only once it is provably judged, never on first sight"
}

test_historical_witnesses_cover_only_the_judged_occurrence() {
  local dir state witness handled oldest start event
  local done_line='done: tests locaux validés'
  dir="$TMP_ROOT/occurrence-witness"; state="$dir/state"; mkdir -p "$state"
  witness=reminder
  make_task "$state" "$witness" no-mistakes 'working: préparation' "$done_line"
  start=$(wc -c < "$state/$witness.status" | tr -d '[:space:]')
  status_span_has_actionable "$state/$witness.status" 0 \
    && fail "the first occurrence was presented instead of steered"
  status_span_has_actionable "$state/$witness.status" 0 \
    && fail "a second cursor presented the same occurrence"
  [ "$(inbox_records "$state" "$witness")" = 1 ] \
    || fail "two cursors did not enqueue exactly one reminder"
  handled=$(fm_task_inbox_handled_dir "$state" "$witness")
  mkdir -p "$handled"
  oldest=$(fm_task_inbox_oldest_unhandled "$state" "$witness") \
    || fail "the first reminder was not tracked"
  mv "$oldest" "$handled/" || fail "the first reminder could not be acknowledged"
  [ "$(fm_task_inbox_due_action "$state" "$witness")" = quiet ] \
    || fail "the acknowledged reminder was still escalating"
  printf 'working: continuing\n' >> "$state/$witness.status"
  status_span_has_actionable "$state/$witness.status" 0 \
    && fail "the $witness witness did not suppress its own historical occurrence"
  printf '%s\nworking: continuing again\n' "$done_line" >> "$state/$witness.status"
  event=$(status_span_first_actionable "$state/$witness.status" "$start") \
    || fail "the $witness witness swallowed an unseen identical occurrence"
  [ "$event" = "$done_line" ] \
    || fail "the later occurrence was not presented verbatim: $event"
  event=$(status_span_first_actionable "$state/$witness.status" 0) \
    || fail "a whole-log read swallowed the unseen occurrence"
  [ "$event" = "$done_line" ] \
    || fail "a whole-log read did not distinguish the two occurrences: $event"
  [ "$(inbox_records "$state" "$witness")" = 0 ] \
    || fail "the historical occurrence incorrectly steered the worker"
  pass "reminder witnesses suppress only their own byte occurrence"
}

test_identical_history_is_not_the_newest_occurrence() {
  local dir state event
  dir="$TMP_ROOT/identical-current"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes \
    'done: local tests pass' 'working: retrying' 'done: local tests pass' ''
  event=$(status_span_first_actionable "$state/t.status" 0) \
    || fail "the unseen historical occurrence was treated as the newest done"
  [ "$event" = 'done: local tests pass' ] \
    || fail "the historical occurrence was not presented exactly once: $event"
  [ "$(inbox_records "$state" t)" = 1 ] \
    || fail "the newest occurrence did not enqueue exactly one reminder"
  status_done_guard_holds "$state/t.status" \
    || fail "the newest occurrence did not retain its hold"
  pass "identical history is presented while only the newest occurrence is steered"
}

test_witnesses_preserve_payload_tabs() {
  local dir state witness line=$'done:\tlocal tests pass\t' event i
  dir="$TMP_ROOT/payload-tabs"; state="$dir/state"; mkdir -p "$state"
  witness=reminder
  make_task "$state" "$witness" no-mistakes "$line"
  for i in 1 2 3; do
    status_span_has_actionable "$state/$witness.status" 0 \
      && fail "a re-read of the tab payload was presented on pass $i"
    status_done_guard_holds "$state/$witness.status" "$line" \
      || fail "the tab payload did not match its own witness"
  done
  [ "$(inbox_records "$state" "$witness")" = 1 ] || fail "tab replays spent more than one reminder"
  printf 'working: again\n' >> "$state/$witness.status"
  status_span_has_actionable "$state/$witness.status" 0 \
    && fail "the historical tab payload lost its witness"
  printf '%s\nworking: again\n' "$line" >> "$state/$witness.status"
  event=$(status_span_first_actionable "$state/$witness.status" 0) \
    || fail "a new identical tab payload was swallowed"
  [ "$event" = "$line" ] || fail "the presented payload lost bytes"
  pass "witnesses preserve payload tabs and distinguish later identical occurrences"
}

test_live_hold_reads_are_bounded_and_skip_absent_witnesses() {
  local dir state reader log line='done: bounded hold' endpoint
  dir="$TMP_ROOT/bounded-hold"; state="$dir/state"; mkdir -p "$state"
  reader="$dir/reader"; log="$dir/reads"
  make_task "$state" t no-mistakes
  perl -e 'print "working: old history\n" x 20000' > "$state/t.status"
  printf '%s\n' "$line" >> "$state/t.status"
  endpoint=$(wc -c < "$state/t.status" | tr -d '[:space:]')
  status_done_guard_defer "$state/t.status" "$line" "$line" no-mistakes "$endpoint" \
    || fail "the large-log occurrence was not held"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$2" "$3" >> "$FM_HOLD_READ_LOG"
[ "$2" -gt 0 ] && [ "$3" -le 65536 ] || exit 1
perl -e 'open my $f, "<", $ARGV[0] or exit 1; seek $f, $ARGV[1], 0; read $f, my $s, $ARGV[2]; print $s' "$@"
SH
  chmod +x "$reader"
  FM_STATUS_SPAN_READER="$reader" FM_HOLD_READ_LOG="$log" status_done_guard_holds "$state/t.status" "$line" \
    || fail "a live hold attempted to read the entire lifetime log"
  [ -s "$log" ] || fail "the live hold did not exercise the bounded reader"
  : > "$log"
  FM_STATUS_SPAN_READER="$reader" FM_HOLD_READ_LOG="$log" status_done_guard_occurrence_held "$state/t.status" "$line" "$endpoint" \
    || fail "the captured occurrence lost its witness"
  [ ! -s "$log" ] || fail "a captured occurrence reread the status log"
  make_task "$state" absent no-mistakes "done: PR $PR_URL checks green"
  FM_STATUS_SPAN_READER="$reader" FM_HOLD_READ_LOG="$log" status_done_guard_holds "$state/absent.status" \
    && fail "a task with no witness was held"
  [ ! -s "$log" ] || fail "absent witnesses still caused status reads"
  pass "captured and absent-witness checks avoid reads, and live holds read at most 64 KiB"
}

test_trailing_blanks_preserve_occurrence_witnesses() {
  local dir state witness event
  dir="$TMP_ROOT/trailing-blanks"; state="$dir/state"; mkdir -p "$state"
  witness=reminder
  make_task "$state" "$witness" no-mistakes 'working: préparation' 'done: tests validés' '' '  '
  status_span_has_actionable "$state/$witness.status" 0 \
    && fail "the done with trailing blanks was presented"
  status_done_guard_holds "$state/$witness.status" \
    || fail "the $witness did not hold its occurrence"
  printf '\n' >> "$state/$witness.status"
  status_done_guard_holds "$state/$witness.status" \
    || fail "an extra blank line invalidated the $witness hold"
  printf 'working: continuing\n' >> "$state/$witness.status"
  status_span_has_actionable "$state/$witness.status" 0 \
    && fail "trailing blanks invalidated the historical $witness witness"
  printf 'done: tests validés\nworking: again\n' >> "$state/$witness.status"
  event=$(status_span_first_actionable "$state/$witness.status" 0) \
    || fail "the $witness swallowed an unseen identical occurrence"
  [ "$event" = 'done: tests validés' ] \
    || fail "the $witness did not present exactly the unseen occurrence: $event"
  make_task "$state" unterminated no-mistakes
  printf 'done: no final newline' > "$state/unterminated.status"
  status_span_has_actionable "$state/unterminated.status" 0 \
    && fail "an unterminated done was presented instead of steered"
  status_done_guard_holds "$state/unterminated.status" \
    || fail "an unterminated occurrence did not retain its hold"
  pass "writers and readers agree on occurrence endpoints despite trailing blanks"
}

test_acknowledged_reminder_history_survives_delivery() {
  local state oldest handled event
  state="$TMP_ROOT/acknowledged-history/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes 'done: local tests pass'
  status_span_has_actionable "$state/t.status" 0 && fail "the linkless done was presented"
  oldest=$(fm_task_inbox_oldest_unhandled "$state" t) || fail "the reminder was not queued"
  handled=$(fm_task_inbox_handled_dir "$state" t)
  mkdir -p "$handled"
  mv "$oldest" "$handled/" || fail "the worker could not acknowledge its reminder"
  printf 'done: PR %s checks green\n' "$PR_URL" >> "$state/t.status"
  event=$(status_span_first_actionable "$state/t.status" 0) || fail "the valid done was withheld"
  [ "$event" = "done: PR $PR_URL checks green" ] || fail "delivery was not presented verbatim: $event"
  printf 'needs-decision: choose the next task\n' >> "$state/t.status"
  event=$(status_span_first_actionable "$state/t.status" 0) || fail "the decision was lost"
  case "$event" in *'done: local tests pass'*) fail "delivery erased the historical judgment" ;; esac
  case "$event" in *'needs-decision: choose the next task'*) ;; *) fail "the decision was not presented: $event" ;; esac
  rm "$state/t.status"
  status_retire_presentation_task "$state" t || fail "budget-only retirement failed"
  [ ! -e "$state/.t.done-guard" ] || fail "retirement left the budget witness behind"
  pass "acknowledged reminder evidence survives delivery until task retirement"
}

test_a_historical_delivered_done_does_not_release_a_live_hold() {
  local dir state
  dir="$TMP_ROOT/historical-clear"; state="$dir/state"; mkdir -p "$state"
  make_task "$state" t no-mistakes \
    "done: PR $PR_URL checks green" \
    'done: follow-up landed locally'
  # Newest line is linkless, so the guard holds - and the earlier delivered done
  # replayed by the same whole-log read must not release that hold.
  local event
  event=$(status_span_first_actionable "$state/t.status" 0) \
    || fail "the replayed delivered done was not presented"
  case "$event" in
    *'follow-up landed locally'*) fail "the withheld newest done was presented: '$event'" ;;
  esac
  status_done_guard_holds "$state/t.status" \
    || fail "a replayed historical done with a PR link released a live hold"
  [ "$(inbox_records "$state" t)" = 1 ] || fail "the newest linkless done did not steer the worker"
  pass "a replayed delivered done does not release the hold the newest line still earns"
}

# --- the recovery backstop stays able to recover -----------------------------

backstop_body() {  # <drain-output>
  awk '
    /^STATUS OUTCOME BACKSTOP \(/ { in_section=1; next }
    in_section && /^(OPEN DECISIONS|RECORD DIVERGENCE|UNREAD STATUS|WAKE_ACK_REQUIRED)/ { exit }
    in_section { print }
  ' "$1"
}

age_file() {  # <epoch> <file>
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

# The recovery backstop presents only a log's LAST non-blank line and then
# commits its cursor at that line's endpoint, jumping past every earlier line it
# never showed. So its cursor is no witness that an earlier line was judged, and
# a linkless done it jumped past must still be presented when the watcher comes
# back and classifies from its own unadvanced offset.
test_a_done_the_backstop_jumped_past_is_not_swallowed() {
  local dir state out body old event
  dir=$(make_case backstop-jump); state="$dir/state"; out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))

  make_task "$state" t no-mistakes 'done: local tests pass' 'failed: the build broke'
  age_file "$old" "$state/t.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed over the backstop fixture"
  body=$(backstop_body "$out")
  case "$body" in
    *'t failed: the build broke'*) ;;
    *) fail "the backstop did not recover the log's latest event: $body" ;;
  esac
  case "$body" in
    *'done: local tests pass'*) fail "the backstop presented the linkless done itself: $body" ;;
  esac

  event=$(status_span_first_actionable "$state/t.status" 0) \
    || fail "a done the backstop jumped past was presented to no one and steered no one"
  case "$event" in
    *'done: local tests pass'*) ;;
    *) fail "the unjudged done was not presented once the watcher classified it: '$event'" ;;
  esac

  # The divergence: the same shape where a genuine witness DOES cover the done -
  # the guard steered its worker about it while it was still the newest line - is
  # dropped on the same whole-log re-read, so this cannot pass vacuously.
  make_task "$state" u no-mistakes 'done: local tests pass'
  status_span_has_actionable "$state/u.status" 0 \
    && fail "the linkless done was presented instead of withheld while newest"
  [ "$(inbox_records "$state" u)" = 1 ] || fail "the newest linkless done did not steer the worker"
  printf 'failed: the build broke\n' >> "$state/u.status"
  event=$(status_span_first_actionable "$state/u.status" 0) \
    || fail "the later failed: line was not presented"
  case "$event" in
    *'done: local tests pass'*) fail "an already-steered done was re-presented: '$event'" ;;
  esac
  pass "a backstop cursor is no witness, so only a genuinely judged done is dropped"
}

test_backstop_skips_a_held_done_but_recovers_a_budget_exhausted_one() {
  local dir state out body old
  dir=$(make_case backstop-guard); state="$dir/state"; out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))

  # held: the guard is holding this task's newest line and its worker carries the
  # contract reminder, so recovering it would present the withheld completion.
  make_task "$state" held no-mistakes 'done: local tests pass'
  status_span_has_actionable "$state/held.status" 0 && fail "the held done was presented"
  status_done_guard_holds "$state/held.status" || fail "the guard did not take the hold"

  # spent: the same shape after the reminder budget is exhausted. The guard has
  # deliberately handed this line to firstmate as a real event, so if that primary
  # presentation is lost this backstop must still recover it - that is its job.
  make_task "$state" spent direct-PR
  : > "$state/spent.status"
  local i=1
  while [ "$i" -le "$(fm_done_guard_reminder_max)" ]; do
    printf 'done: attempt %s\n' "$i" >> "$state/spent.status"
    status_span_has_actionable "$state/spent.status" 0 \
      && fail "reminder $i was not spent"
    i=$((i + 1))
  done
  printf 'done: attempt past the budget\n' >> "$state/spent.status"
  status_span_has_actionable "$state/spent.status" 0 \
    || fail "the budget-exhausted done was not handed to firstmate"
  status_done_guard_holds "$state/spent.status" \
    && fail "the guard still claims to hold a line whose budget it has spent"

  age_file "$old" "$state/held.status"
  age_file "$old" "$state/spent.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed over the guard fixtures"
  body=$(backstop_body "$out")
  case "$body" in
    *'spent done: attempt past the budget'*) ;;
    *) fail "the backstop suppressed a budget-exhausted done it exists to recover: $body" ;;
  esac
  case "$body" in
    *'held done: local tests pass'*) fail "the backstop recovered a done the guard is holding: $body" ;;
  esac
  pass "the recovery backstop skips only a done the guard actually holds"
}

# --- the watcher-side behavior ------------------------------------------------

test_stale_pane_behind_a_withheld_done_is_absorbed() {
  local dir state fakebin out capture_file window key pane_hash pid
  dir=$(make_case stale-withheld); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-withheld"
  # A capturable backend on purpose: with a window the fake tmux cannot capture,
  # the pane loop skips it and never reaches the stale branch under test.
  printf 'idle shell after a linkless done\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nmode=no-mistakes\nharness=claude\nbackend=tmux\n' "$window" \
    > "$state/withheld.meta"
  printf 'done: local tests pass\n' > "$state/withheld.status"
  # Arm the guard exactly as the signal path would have, then declare the log
  # already surfaced so only the pane-staleness backbone is under test.
  status_span_has_actionable "$state/withheld.status" 0 && fail "the linkless done was presented"
  status_done_guard_holds "$state/withheld.status" || fail "the guard did not take the hold"
  prime_status_seen "$state" "$state/withheld.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle shell after a linkless done")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "an idle pane behind a withheld done woke firstmate: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the withheld done surfaced through the stale path: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "the stale path queued a wake for a withheld done"
  # Bounded, not muted: the wedge timer is running, so a pane that never comes
  # back still escalates past its threshold.
  [ -s "$state/.stale-since-$key" ] \
    || fail "the absorbed stale pane did not start its wedge timer"
  reap "$pid"
  pass "an idle pane behind a withheld done is absorbed with its wedge timer running, not surfaced"
}

test_stale_pane_behind_a_real_done_still_surfaces() {
  local dir state fakebin out capture_file window key pane_hash pid
  dir=$(make_case stale-real); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-real"
  # The deliberate divergence from the case above: same fixture, same backend,
  # same idle pane - only the done carries its PR link, so it stays terminal and
  # must still reach firstmate exactly as before.
  printf 'idle shell after a delivered done\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nmode=no-mistakes\nharness=claude\nbackend=tmux\n' "$window" \
    > "$state/real.meta"
  printf 'done: PR %s checks green\n' "$PR_URL" > "$state/real.status"
  prime_status_seen "$state" "$state/real.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle shell after a delivered done")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an idle pane behind a delivered done no longer surfaces: $(cat "$out")"
  grep -F "stale: $window" "$out" >/dev/null \
    || fail "the delivered done did not surface as a terminal stale pane: $(cat "$out")"
  [ -d "$state/real.inbox" ] && fail "a delivered done steered its worker from the stale path"
  pass "an idle pane behind a done carrying its PR link still surfaces exactly as before"
}

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

test_mixed_watcher_batch_filters_only_held_occurrences() {
  local dir state fakebin out drain_out pid verdict
  local FM_DONE_GUARD_REMINDER_MAX=1
  export FM_DONE_GUARD_REMINDER_MAX
  for verdict in held spent history; do
    dir=$(make_case "mixed-$verdict"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; drain_out="$dir/drain.out"
    make_task "$state" a no-mistakes 'working: implementing'
    make_task "$state" b local-only 'working: preparing'
    if [ "$verdict" = spent ]; then
      printf 'done: earlier attempt\n' >> "$state/a.status"
      status_span_has_actionable "$state/a.status" 0 \
        && fail "the setup did not spend a reminder"
      [ "$(inbox_records "$state" a)" = 1 ] || fail "the setup did not steer task a"
    fi
    prime_status_seen "$state" "$state/a.status"
    prime_status_seen "$state" "$state/b.status"
    printf 'done: mixed batch local tests pass\n\n' >> "$state/a.status"
    printf 'blocked: another task needs help\n' >> "$state/b.status"
    export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
    watch_bg "$state" "$fakebin" "$out"
    pid=$!
    wait_for_exit "$pid" 300 || fail "the mixed batch failed to wake firstmate"
    if [ "$verdict" = history ]; then
      status_done_guard_holds "$state/a.status" || fail "the original occurrence was never held"
      printf 'working: continuing\ndone: mixed batch local tests pass\nworking: again\n' >> "$state/a.status"
    fi
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
      || fail "the mixed batch drain failed"
    assert_contains "$(cat "$drain_out")" 'blocked: another task needs help' "the other task was not presented"
    if [ "$verdict" = held ]; then
      status_done_guard_holds "$state/a.status" || fail "task a was never held"
      assert_not_contains "$(cat "$drain_out")" 'done: mixed batch local tests pass' "the held occurrence leaked through annotations"
    elif [ "$verdict" = history ]; then
      [ "$(grep -c 'done: mixed batch local tests pass' "$drain_out")" = 1 ] \
        || fail "annotations did not distinguish held history from the unseen identical occurrence"
    else
      status_done_guard_holds "$state/a.status" && fail "the spent-budget occurrence was still held"
      assert_contains "$(cat "$drain_out")" 'done: mixed batch local tests pass' "the spent-budget occurrence was hidden"
    fi
  done
  pass "mixed watcher batches present other tasks and exhausted dones while hiding held occurrences"
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
test_a_reappended_identical_done_is_steered_again
test_unsteerable_worker_is_presented
test_guard_steers_without_the_inbox_library_preloaded
test_guard_ignores_historical_done_lines
test_a_first_sight_non_newest_linkless_done_is_not_swallowed
test_historical_witnesses_cover_only_the_judged_occurrence
test_identical_history_is_not_the_newest_occurrence
test_witnesses_preserve_payload_tabs
test_live_hold_reads_are_bounded_and_skip_absent_witnesses
test_trailing_blanks_preserve_occurrence_witnesses
test_acknowledged_reminder_history_survives_delivery
test_a_historical_delivered_done_does_not_release_a_live_hold
test_backstop_skips_a_held_done_but_recovers_a_budget_exhausted_one
test_a_done_the_backstop_jumped_past_is_not_swallowed
test_watcher_absorbs_a_withheld_done
test_stale_pane_behind_a_withheld_done_is_absorbed
test_stale_pane_behind_a_real_done_still_surfaces
test_mixed_watcher_batch_filters_only_held_occurrences
test_watcher_still_surfaces_a_real_done

