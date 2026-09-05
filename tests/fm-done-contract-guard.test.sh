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
  status_line_has_pr_link "done: local tests pass" \
    && fail "a done: with no link was read as carrying one"
  status_line_has_pr_link "done: see https://github.com/kunchenguid/firstmate" \
    && fail "a repository URL that is not a pull request was read as a PR link"
  status_line_has_pr_link "done: see https://github.com/kunchenguid/firstmate/pull/0" \
    && fail "a malformed pull-request number was read as a PR link"
  status_line_has_pr_link "done: see https://github.com/o/r/pull/notanumber" \
    && fail "a non-numeric pull-request id was read as a PR link"
  status_line_has_pr_link "done: see https://github.com/o/r/pull/0/files" \
    && fail "a malformed pull-request number with a suffix was read as a PR link"
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
test_guard_ignores_historical_done_lines
test_a_historical_delivered_done_does_not_release_a_live_hold
test_backstop_skips_a_held_done_but_recovers_a_budget_exhausted_one
test_watcher_absorbs_a_withheld_done
test_stale_pane_behind_a_withheld_done_is_absorbed
test_stale_pane_behind_a_real_done_still_surfaces
test_watcher_still_surfaces_a_real_done
