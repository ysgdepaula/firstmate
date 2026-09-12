#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, the record-divergence guard over its two records, and the legacy
# compatibility for pre-collapse decision identities.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# tasks-axi, and firstmate's archive resolution with it, falls back to
# $HOME/.tasks-axi/config.toml when a repository config does not answer. Point
# HOME at the fixture so the developer's own user config can never decide what
# a fixture resolves: "this home keeps no Done archive" must be true on every
# machine, not only on one without that file.
tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && HOME="$home" tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" HOME="$home" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
}

# A home whose config names no Done archive, which is NOT a home without one:
# tasks-axi still rotates closed rows into its own default beside the backlog.
# tasks_in and run_captain pin HOME to the fixture, so the user-level config
# cannot supply an archive behind the test's back.
write_no_archive_config() {  # <home>
  local home=$1
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\ndone_keep = 10\n' \
    > "$home/.tasks.toml"
  rm -rf "$home/.tasks-axi"
}

# Rotate one throwaway row through tasks-axi's real retention, so this home's
# Done archive exists and is readable without archiving anything the case under
# test names.
seed_done_archive() {  # <home>
  local home=$1
  tasks_in "$home" add sample-archive-seed "Seed the Done archive" --repo sample >/dev/null \
    || fail "could not create the archive seed"
  tasks_in "$home" "done" sample-archive-seed --keep 0 >/dev/null \
    || fail "could not rotate the archive seed out of the backlog"
}

# Purge <id> from the backlog through tasks-axi's own Done retention, which
# moves every retained row into this home's configured archive.
archive_out_of_backlog() {  # <home> <id>
  local home=$1 id=$2
  tasks_in "$home" add sample-retention-filler "Filler work" --repo sample >/dev/null \
    || fail "could not create the retention filler"
  tasks_in "$home" "done" sample-retention-filler --keep 0 >/dev/null \
    || fail "could not run retention over the Done rows"
  if tasks_in "$home" show "$id" >/dev/null 2>&1; then
    fail "retention did not push $id out of the backlog"
  fi
}

# --- markdown-to-beads migration resolution ----------------------------------
#
# A home on the Beads backend no longer carries the legacy markdown ids a scout
# report attested: fm-hold-migration rehomed each held row under a prefixed fm-
# id and recorded its markdown identity in the row's notes as the exact line
# "migrated from data/backlog.md id <legacy id>". The fixture graph is driven
# through bd directly where possible because the npm-published tasks-axi ships
# the markdown backend only; the hold itself needs a beads-capable tasks-axi,
# so that family probes once and skips itself with an explicit reason on
# markdown-only installs, mirroring tests/fm-control-relaunch.test.sh.

# Build a fixture home whose configured backend is a scratch Beads graph.
# Echoes "<home>|<graph-beads-dir>". The graph repo dir is named "fm" because
# bd derives the row-id prefix from the repo directory name.
make_beads_home() {  # <name>
  local name=$1 case_dir home graph fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  graph="$case_dir/fm"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$graph"
  (umask 077; mkdir -p "$home/state")
  git -C "$graph" init -q
  if ! (cd "$graph" && bd init >"$case_dir/bd-init.log" 2>&1); then
    cat "$case_dir/bd-init.log" >&2
    fail "fixture bd init failed on $graph"
  fi
  cat > "$home/.tasks.toml" <<EOF
backend = "beads"

[beads]
path = "$graph/.beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  fb=$(fm_fakebin "$home")
  fm_fake_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home|$graph/.beads"
}

bdrow() {  # <beads-dir> <args...>
  BEADS_DIR="$1" bd "${@:2}"
}

# One capability probe for the migration family: can the installed tasks-axi
# operate on a beads-backed home? The npm-published tasks-axi cannot, and the
# hold fixture needs its beads backend; those installs skip with this reason.
probe_tasks_axi_beads() {
  local probe_home="$TMP_ROOT/.probe" probe_graph="$TMP_ROOT/.probe-fm"
  rm -rf "$probe_home" "$probe_graph"
  mkdir -p "$probe_home/data" "$probe_graph"
  git -C "$probe_graph" init -q
  (cd "$probe_graph" && bd init >/dev/null 2>&1) || return 1
  cat > "$probe_home/.tasks.toml" <<PROBEEOF
backend = "beads"

[beads]
path = "$probe_graph/.beads"
binary = "bd"
prefix = "fm"
PROBEEOF
  (cd "$probe_home" && tasks-axi list) >/dev/null 2>&1
}
TASKS_AXI_BEADS_OK=0
if bd --version >/dev/null 2>&1 && jq --version >/dev/null 2>&1 \
   && probe_tasks_axi_beads; then
  TASKS_AXI_BEADS_OK=1
fi

require_tasks_axi_beads() {  # <what>
  [ "$TASKS_AXI_BEADS_OK" = 1 ] && return 0
  pass "skipped on markdown-only tasks-axi: $1"
  return 1
}

write_scout_with_attested_inventory() {  # <home> <scout-id> <keys>
  local home=$1 scout=$2 keys=$3
  mkdir -p "$home/data/$scout"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout" \
    "decisions_reviewed=1" \
    "decision_keys=$keys"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"
}

test_verify_resolves_a_hold_migrated_to_beads_notes() {
  local fixture home beads scout
  require_tasks_axi_beads "verify against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-notes)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-beads-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "Origin: herald-retire
Decision key: github-delete
State: awaiting captain decision.

migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_scout_with_attested_inventory "$home" "$scout" \
    herald-retire-decision-github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the attested legacy id through its migrated beads row"
  pass "verify resolves a captain hold migrated to a beads row with a marker note"
}

# A tasks-axi stub that knows ONLY the row ids it is given. The real
# beads-capable tasks-axi resolves a bare legacy id onto its prefixed row
# itself, answering before any migration lookup runs; against this stub the
# migrated-hold resolution order is what has to answer.
write_known_rows_stub() {  # <fakebin> <row-id...>
  local fb=$1 known
  shift
  known=$(printf '%s|' "$@")
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.5' ;;
  update)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '--archive-body'
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '  --kind captain'
    ;;
  show)
    case "${2:-}" in
      @KNOWN@) ;;
      *) printf 'error: no task %s in this backlog\n' "${2:-}" >&2; exit 1 ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "$2"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain' '  body: ""'
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s%@KNOWN@%${known%|}%" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"
}

test_verify_resolves_a_hold_migrated_under_the_configured_prefix() {
  local fixture home scout out
  require_tasks_axi_beads "verify against a prefix-migrated hold" || return 0
  fixture=$(make_beads_home migrated-prefix)
  home=${fixture%%|*}
  scout=sample-prefix-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-other-legacy-row \
    "Second migrated hold" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the prefix-migrated fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-other-legacy-row \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the prefix-migrated fixture row"
  # No row in this graph carries a marker note, so the narrowed prefix guess is
  # the only resolution left for the attested legacy id.
  write_known_rows_stub "$(fm_fakebin "$home")" fm-other-legacy-row
  write_scout_with_attested_inventory "$home" "$scout" other-legacy-row

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the legacy id under the configured prefix"
  out=$(run_captain "$home" complete "$scout" other-legacy-row) \
    || fail "the completion gate refused the prefix-resolved hold"
  assert_contains "$out" "other-legacy-row=fm-other-legacy-row" \
    "completion did not name the row the prefix guess attested against"
  pass "verify resolves a captain hold whose id is the legacy id under the configured prefix"
}

# The prefix guess is a name, not evidence: when a row actually carries the
# migration marker, that row is the one attested even though an unrelated
# captain-held task occupies the <prefix>-<legacy id> name.
test_marker_noted_row_wins_over_a_prefix_namesake() {
  local fixture home beads scout row out
  require_tasks_axi_beads "prefer a marker-noted row over a prefix namesake" || return 0
  fixture=$(make_beads_home migrated-marker-wins)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-marker-wins-scout
  for row in fm-dual-row fm-marked-dual-row fm-solo-row; do
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi add "$row" "Captain call $row" \
      --repo sample) >/dev/null 2>&1 || fail "could not create the fixture row $row"
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold "$row" --kind captain \
      --reason "captain must decide") >/dev/null 2>&1 \
      || fail "could not hold the fixture row $row"
  done
  bdrow "$beads" note fm-marked-dual-row \
    "migrated from data/backlog.md id dual-row on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_known_rows_stub "$(fm_fakebin "$home")" \
    fm-dual-row fm-marked-dual-row fm-solo-row
  write_scout_with_attested_inventory "$home" "$scout" "dual-row,solo-row"

  out=$(run_captain "$home" complete "$scout" dual-row solo-row) \
    || fail "the completion gate refused an inventory carrying both migrated shapes"
  assert_not_contains "$out" "dual-row=fm-dual-row" \
    "the bare prefix namesake shadowed the row carrying the migration marker"
  assert_contains "$out" "solo-row=fm-solo-row" \
    "completion did not name the row the prefix guess attested against"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve both migrated shapes after completion"
  pass "the marker-noted row wins over an unrelated row holding the prefix namesake"
}

test_complete_accepts_a_migrated_inventory_on_beads() {
  local fixture home scout
  require_tasks_axi_beads "complete against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-complete)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-complete-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  mkdir -p "$home/data/$scout"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"

  run_captain "$home" complete "$scout" herald-retire-decision-github-delete >/dev/null \
    || fail "the completion gate refused an inventory resolved through a migrated beads row"
  assert_grep "decision_keys=herald-retire-decision-github-delete" \
    "$home/state/$scout.meta" \
    "the attestation did not record the attested legacy id"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve the attested legacy id after completion"
  pass "the completion gate attests an inventory resolved through a migrated beads row"
}

test_verify_names_the_unresolvable_legacy_id_once() {
  local fixture home scout err rc
  require_tasks_axi_beads "verify an unresolvable beads legacy id" || return 0
  fixture=$(make_beads_home migrated-absent)
  home=${fixture%%|*}
  scout=sample-absent-scout
  write_scout_with_attested_inventory "$home" "$scout" ghost-legacy-id

  rc=0
  err=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted an attested id that resolves to nothing"
  assert_contains "$err" "ghost-legacy-id" \
    "the refusal did not name the id it could not resolve"
  [ "$(printf '%s\n' "$err" | grep -c '^fm-captain-hold:')" = 1 ] \
    || fail "the refusal emitted more than one line: $err"
  pass "an unresolvable legacy id is refused once, naming the id"
}

test_verify_resolves_a_pre_collapse_key_through_its_derived_marker() {
  local fixture home beads scout
  require_tasks_axi_beads "verify a derived pre-collapse key" || return 0
  fixture=$(make_beads_home migrated-derived)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-derived-scout
  # The row was migrated under the DERIVED pre-collapse identity, keyed by a
  # bare decision key the origin's old metadata attests.
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-dec-call \
    "Migrated pre-collapse call" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the derived-marker fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-dec-call \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the derived-marker fixture row"
  bdrow "$beads" note fm-dec-call \
    "migrated from data/backlog.md id $scout-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the derived-id marker note"
  write_scout_with_attested_inventory "$home" "$scout" github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not probe the derived pre-collapse identity for its migrated row"
  pass "a pre-collapse key resolves through its derived identity's migration marker"
}

# A markdown-to-beads migration rehomes the held rows but leaves the old
# data/backlog.md and data/done-archive.md sitting on disk. That archive records
# answers given BEFORE the migration, which say nothing about the call that
# lives in the migrated graph now, so it must not prove a purged entry on a home
# whose resolved backend is no longer markdown: a migration, like retention,
# never turns a refusal into an acceptance. Fully portable - the stubbed
# tasks-axi and bd fake the beads backend and its empty graph, so no beads
# install is needed to drive the refusal.
test_stale_markdown_archive_proves_nothing_on_a_beads_home() {
  local home fb scout call rc
  home="$TMP_ROOT/captain-stub-stale-archive/home"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$home/graph/.beads"
  (umask 077; mkdir -p "$home/state")
  cat > "$home/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = "graph/.beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  scout=sample-stale-archive-scout
  call=sample-stale-archive-call
  fb=$(fm_fakebin "$home")
  fm_fake_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi
  # The migrated graph carries no row for the attested call, and no row carries
  # its migration marker, so the entry legitimately resolves to nothing here.
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.5' ;;
  update)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '--archive-body'
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    case " $* " in
      *" --help "*) printf '%s\n' '  --kind captain'; exit 0 ;;
    esac
    exit 1
    ;;
  show)
    printf '%s\n' 'error: task not found' 'code: NOT_FOUND' >&2
    exit 1
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/tasks-axi"
  cat > "$fb/bd" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "list --all --json") printf '%s\n' '[]' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/bd"
  write_scout_with_attested_inventory "$home" "$scout" "$call"
  # Exactly the shape retention wrote before the migration: a closed row whose
  # indented body carries the captain's recorded answer. On a markdown home this
  # row proves the entry; here it must not be read at all.
  cat > "$home/data/done-archive.md" <<EOF
## Archived 2026-09-01

- [x] $call - Choose route: north, south
  Resolution recorded by fm-captain-hold.
  Decision digest: 0000000000000000000000000000000000000000000000000000000000000000
  Resolution mode: done

  Captain decision:
  the captain chose north
EOF

  set +e
  run_captain "$home" verify "$scout" > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a pre-migration markdown archive proved a purged entry on a beads home"
  assert_grep "$call" "$home/verify.err" \
    "the refusal did not name the entry it could not prove"
  assert_grep "beads backend" "$home/verify.err" \
    "the refusal did not say why no markdown Done archive is authoritative here"
  assert_no_grep "purged: captain-held task" "$home/verify.err" \
    "the gate announced the entry as purged on a stale markdown archive"
  assert_no_grep "done-archive.md" "$home/verify.err" \
    "the refusal named a markdown Done archive that is not authoritative here"

  set +e
  run_captain "$home" complete "$scout" --none > "$home/none.out" 2> "$home/none.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completion accepted a purged entry on a stale markdown archive"
  assert_grep "$call" "$home/none.err" \
    "the completion refusal did not name the entry"
  assert_no_grep "purged: captain-held task" "$home/none.err" \
    "completion announced the entry as purged on a stale markdown archive"
  assert_no_grep "done-archive.md" "$home/none.err" \
    "the completion refusal named a Done archive that is not authoritative here"
  pass "a pre-migration markdown Done archive proves nothing on a beads home"
}

# The captain-hold mutation wrapper must address the configured backend like
# the transition library does: on a beads-configured home its hold/answer/done
# calls reach tasks-axi with no markdown file override. Fully portable - the
# stubbed tasks-axi fakes the beads backend, so no bd or beads-capable install
# is needed.
test_captain_hold_mutations_address_the_beads_backend() {
  local home id fb log
  home="$TMP_ROOT/captain-stub-beads/home"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$home/state"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = "graph/.beads"
binary = "bd"
prefix = "fm"
EOF
  id=fm-stub-held-row
  fb=$(fm_fakebin "$home")
  log="$home/tasks-axi-calls"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "@LOG@"
case "${1:-}" in
  --version) printf '%s\n' '0.2.5' ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' '--archive-body'
      exit 0
    fi
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads update received a markdown file override' >&2
        exit 1
        ;;
    esac
    stub_prev=
    stub_path=
    for stub_arg in "$@"; do
      if [ "$stub_prev" = --body-file ]; then stub_path=$stub_arg; fi
      stub_prev=$stub_arg
    done
    [ -n "$stub_path" ] && cp -- "$stub_path" "@HOME@/last-body"
    printf 'ok: update %s\n' "${2:-}"
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    case " $* " in
      *" --help "*) printf '%s\n' '  --kind captain' ; exit 0 ;;
      *" --file "*)
        printf '%s\n' 'error: beads hold received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: hold %s\n' "${2:-}"
    ;;
  done)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads done received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: done %s\n' "${2:-}"
    ;;
  show)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads show received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "@ID@"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain'
    if [ -f "@HOME@/last-body" ]; then
      printf '%s' '  body: '
      perl -MJSON::PP -e 'local $/; print encode_json(<STDIN>)' < "@HOME@/last-body"
      printf '\n'
    else
      printf '%s\n' '  body: ""'
    fi
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s|@HOME@|$home|g; s|@ID@|$id|g; s|@LOG@|$log|g" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"

  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "captain must decide" >/dev/null \
    || fail "holding on a beads-configured home failed without a markdown backlog"
  assert_grep "hold $id" "$log" \
    "the captain-hold mutation never reached the configured backend"

  decision="$home/captain-decision.txt"
  printf 'Ship the gold-only plan.\n' > "$decision"
  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$decision" >/dev/null \
    || fail "answering on a beads-configured home failed without a markdown backlog"
  assert_grep "update $id --body-file" "$log" \
    "the captain answer never reached the configured backend"
  assert_grep "done $id" "$log" \
    "the captain answer close never reached the configured backend"
  assert_no_grep " --file " "$log" \
    "a captain-hold mutation passed a markdown file override to a beads home"
  pass "captain-hold mutations address the beads backend without a markdown override"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  grep -F 'captain-held [key=route]: tracked by sample-route-call' "$home/state/$id.status" >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out snap
  home=$(make_home release-work)
  cat > "$home/widget-body.txt" <<'EOF'
The widget plan body. Literal escape: \n. Unicode: café.
Captain hold set: 2025-01-02T03:04:05Z
EOF
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body-file "$home/widget-body.txt" >/dev/null \
    || fail "could not create the held work item"
  FM_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Not urgent; ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Not urgent; ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  assert_contains "$show" "Captain hold set: 2025-01-02T03:04:05Z" \
    "hold stamping deleted matching user content outside the leading stamp"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed after re-hold"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-widget")
    | .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "a new hold lifecycle reused historical timestamp or answer text: $snap"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Not urgent; ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# The hold-set stamp must be durable before the captain hold becomes visible.
# A wrapper observes the real tasks-axi hold boundary, and a forced stamp-write
# failure proves the command never publishes the hold without its timestamp.
test_hold_stamp_precedes_hold_visibility() {
  local home show
  home=$(make_home hold-stamp-order)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-old-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)
- [ ] sample-stamp-failure - Existing task whose stamp fails (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = update ] && [ "${2:-}" = sample-stamp-failure ]; then
  exit 92
fi
if [ "${1:-}" = hold ] && [ "${2:-}" = sample-old-call ]; then
  show=$("$REAL_TASKS_AXI" show "$2" --full) || exit 93
  printf '%s\n' "$show" | grep -F 'Captain hold set: 2026-07-14T12:00:00Z' >/dev/null || exit 94
  : > "$FM_HOME/hold-observed-after-stamp"
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-old-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "hold was published before its hold-set stamp"
  assert_present "$home/hold-observed-after-stamp" \
    "the tasks-axi hold boundary was not observed"
  show=$(tasks_in "$home" show sample-old-call --full)
  assert_contains "$show" "hold_kind: captain" "the stamped task was not captain-held"
  assert_contains "$show" "Captain hold set: 2026-07-14T12:00:00Z" \
    "the visible captain hold lost its timestamp"

  if FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-stamp-failure \
    --reason "captain route choice pending" > "$home/stamp-failure.out" 2> "$home/stamp-failure.err"; then
    fail "hold succeeded after its timestamp update failed"
  fi
  show=$(tasks_in "$home" show sample-stamp-failure --full)
  assert_contains "$show" "held: no" "a failed timestamp update still published the hold"
  assert_contains "$show" 'hold_kind: "-"' "a failed timestamp update retained captain-hold provenance"
  pass "captain holds become visible only after their hold-set timestamp is durable"
}

test_interrupted_answer_preserves_hold_age() {
  local home snap show
  home=$(make_home interrupted-answer-age)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-interrupted-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-interrupted-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "could not hold the interrupted-answer fixture"
  printf 'Not urgent in the historical answer.\n' > "$home/interrupted-answer.txt"
  mkdir -p "$home/at-close"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "done" ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/close-failed-once" ]; then
  cp "$FM_HOME/data/backlog.md" "$FM_HOME/at-close/backlog.md" || exit 93
  : > "$FM_HOME/close-failed-once"
  exit 92
fi
if [ "${1:-}" = update ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/normalize-failed-once" ]; then
  state=$("$REAL_TASKS_AXI" show "$2" --full | sed -n 's/^  state: //p' | head -1)
  if [ "$state" = "done" ]; then
    : > "$FM_HOME/normalize-failed-once"
    exit 94
  fi
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/answer.out" 2> "$home/answer.err"; then
    fail "the forced answer close failure reported success"
  fi
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/at-close" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at interrupted close boundary"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-interrupted-call")
    | .captain_actionable == true
      and .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "an interrupted answer lost the fresh hold age basis: $snap"

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/normalize.out" 2> "$home/normalize.err"; then
    fail "the forced post-close normalization failure reported success"
  fi
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" "state: done" "the normalization failure undid the successful close"
  run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" >/dev/null \
    || fail "the closed answer could not normalize on retry"
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" 'body: "Resolution recorded by fm-captain-hold.' \
    "the matching done retry did not restore resolution-first body ordering"
  pass "an interrupted answer preserves its hold age until close retry"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-existing-call - Decide an existing sample task (repo: sample) (kind: captain) (since 2026-06-01)
- [ ] sample-near-marker - Decide a deferred sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  Captain hold set: 2026-07-14T12:00:00Z
  abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij DEFERRED
- [ ] sample-late-marker - Decide a documented sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  This deliberately long decision context fills the bounded display excerpt without changing the durable classification contract. Additional synthetic context keeps extending the body beyond that display boundary while remaining ordinary task prose. More synthetic context places the presentation marker after the excerpt cutoff. DEFERRED

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not hold the existing task"
  FM_CAPTAIN_HOLD_NOW=2026-07-20T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not repeat the existing task hold"
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and $existing.since == "2026-06-01" and $existing.hold_set == "2026-07-14T12:00:00Z"
      and $existing.hold_age_days == 0 and $existing.hold_bucket == "live"
      and ([.backlog.records[] | select(.id == "sample-near-marker")][0].hold_bucket == "live")
      and ([.backlog.records[] | select(.id == "sample-late-marker")][0].hold_bucket == "live")
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate, hold-set age, or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-existing-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == true
      and $existing.hold_age_days == 18 and $existing.hold_bucket == "aged"
  ' >/dev/null || fail "a due deferral did not resurface or a stamped hold did not age from its hold date"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_captain "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  # A seeded home always carries its parent binding; teardown delivers the
  # scout's final line through it before removing the record.
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  # The parent registers the mate before its children are ever torn down;
  # teardown resolves that registration to deliver the scout's final line.
  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null
  grep -Eq "^done \\[key=child-outcome-$origin-done-[0-9a-f]{8}\\]: child $origin done: report and visual review complete mode=scout report=data/$origin/report.md$" \
    "$parent/state/sample-mate.status" \
    || fail "the scout's final line did not reach the parent at teardown"

  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# Inside a secondmate home a hold and its answer reach the parent channel from
# the script itself, keyed per hold occurrence, so a re-held task opens and
# closes a distinct parent decision and a retry never duplicates a line. A main
# home publishes nothing anywhere.
test_secondmate_home_publishes_holds_and_answers() {
  local parent mate fakebin channel decision out
  parent=$(make_home parent-channel)
  mate="$TMP_ROOT/channel-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  channel="$parent/state/channel-mate.status"
  decision="$mate/decision.txt"

  tasks_in "$mate" add quoted-record-call "Choose quoted record handling" --kind ship --repo sample \
    --body 'Documentation quote: Resolution recorded by fm-captain-hold.' >/dev/null \
    || fail "could not create quoted-record captain call"
  run_captain "$mate" hold quoted-record-call --reason "quoted record choice pending" \
    --origin quoted-origin >/dev/null || fail "quoted-record hold failed"
  assert_grep 'needs-decision [key=captain-hold-quoted-record-call-1]: captain hold quoted-record-call: quoted record choice pending' \
    "$channel" "body prose was incorrectly counted as a resolution record"

  run_captain "$mate" hold mate-call --title "Choose the mate release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "mate hold failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: release choice pending' \
    "$channel" "the mate's hold did not reach the parent channel"
  run_captain "$mate" hold mate-call --reason "release choice pending" >/dev/null \
    || fail "repeated mate hold failed"
  [ "$(grep -c 'captain-hold-mate-call-1' "$channel")" = 1 ] \
    || fail "a repeated hold duplicated the parent decision: $(cat "$channel")"

  printf 'ship it later\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" --release >/dev/null \
    || fail "mate release answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: released' \
    "$channel" "the released answer did not close the parent decision"

  run_captain "$mate" hold mate-call --reason "second release choice" >/dev/null \
    || fail "re-hold after release failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-2]: captain hold mate-call: second release choice' \
    "$channel" "a re-held task did not open a distinct parent decision"
  printf 'ship it\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "mate close answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-2]: captain hold mate-call: answered' \
    "$channel" "the closing answer did not close the second parent decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "idempotent answer retry failed"
  [ "$(grep -c 'captain-hold-mate-call-2' "$channel")" = 2 ] \
    || fail "an answer retry duplicated a parent line: $(cat "$channel")"
  [ "$(grep -c 'captain-hold-mate-call' "$channel")" = 4 ] \
    || fail "unexpected parent channel contents: $(cat "$channel")"

  run_captain "$mate" hold batch-call --title "Choose the batch release" \
    --reason "batch choice pending" --repo sample >/dev/null \
    || fail "batch hold failed"
  mv "$channel" "$channel.saved"
  mkdir "$channel"
  out=$(printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" 2>&1) \
    || fail "batch answer did not preserve its durable close: $out"
  printf '%s\n' "$out" | grep -Fq 'actionable:' \
    || fail "failed batch parent delivery was not actionable: $out"
  rmdir "$channel"
  mv "$channel.saved" "$channel"
  printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" >/dev/null \
    || fail "idempotent batch answer retry failed"
  [ "$(grep -c 'resolved \[key=captain-hold-batch-call-1\]' "$channel")" = 1 ] \
    || fail "batch retry did not restore exactly one parent resolution: $(cat "$channel")"

  run_captain "$parent" hold main-call --title "Choose the main release" \
    --reason "main choice pending" --repo sample >/dev/null || fail "main hold failed"
  [ ! -e "$parent/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  assert_no_grep 'captain-hold-main-call' "$channel" "a main home's hold leaked onto a mate channel"
  pass "a secondmate home publishes each hold occurrence and its answer on the parent channel"
}

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[6]{uid,prompt,selector,tag,text}:
  "2","Membership: gold-only\n\nContext data:\n{\n  \"question\": \"sample-membership-call\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"sample-headline-call\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"question\": \"sample-gated-work\",\n  \"answer\": \"go\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"question\": \"sample-nonexistent-call\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

# A `done:` its delivery contract withholds is not a finish, so it cannot retire
# the captain's still-open decisions either. The completion gate reads the
# origin's last status line and, for a finished origin, drops every open decision
# before attesting. The shared classifier is reporting a task behind a withheld
# line as working and steering its worker back to the contract, so letting that
# line retire an unresolved needs-decision would attest away a call the captain
# is still owed on the word of a line nothing else in the fleet reads as a finish.
test_withheld_done_does_not_retire_open_decisions() {
  local home id
  home=$(make_home withheld-done-open-decisions)
  id=sample-ship-work
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Ship sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ship backlog fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" "harness=codex" "kind=ship" \
    "mode=no-mistakes" "spawn_gen=fixture-$id"
  cat > "$home/state/$id.status" <<'EOF'
working: implementing
needs-decision [key=api-shape]: choose REST or RPC
done: local tests pass
EOF

  if run_captain "$home" complete "$id" --none > "$home/withheld.out" 2> "$home/withheld.err"; then
    fail "a withheld done retired the captain's open decision and let --none attest: $(cat "$home/withheld.err")"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "a withheld done produced a false completion attestation"

  # The deliberate divergence: the same fixture whose done carries its PR link is
  # a real finish, so it retires the open decision exactly as before and --none
  # attests. Without this half the case would pass even if the gate refused every
  # origin unconditionally.
  cat > "$home/state/$id.status" <<'EOF'
working: implementing
needs-decision [key=api-shape]: choose REST or RPC
done: PR https://github.com/owner/repo/pull/9 checks green
EOF
  rm -f "$home/state/.$id.open-decisions-cursor"
  run_captain "$home" complete "$id" --none >/dev/null 2> "$home/delivered.err" \
    || fail "a done carrying its PR link no longer retires an open decision: $(cat "$home/delivered.err")"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the delivered done did not record its completion attestation"
  pass "a withheld done leaves the captain's open decisions open, a delivered one still retires them"
}

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

# The originating work item is itself the captain call, which is what the policy
# prefers ("hold the work item the question gates"). Cleanup of that finished
# work must never be the act that closes the captain's own row: the deliverable
# is recorded on the still-held row, the call keeps reading as open on the
# board, and only a recorded answer closes it. An ordinary finished task in the
# same home must still close exactly as before, and discard authority covers
# unlanded work, never the captain's question.
test_teardown_never_closes_a_captain_held_task() {
  local home id plain forced json show
  home=$(make_home teardown-held)
  id=sample-attach-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample attachment evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample attachment evidence\n\nThe captain must choose inline or by-reference attachments.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" \
    --reason "captain must choose inline or by-reference attachments" >/dev/null \
    || fail "could not hold the originating work item for the captain"
  run_captain "$home" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed with the origin as its own captain call"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held investigation failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held row is gone after cleanup"
  assert_not_contains "$show" "state: done" \
    "cleanup closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "the finished work's row still reads as worked on"
  assert_contains "$show" "held: yes" "cleanup lifted the captain hold"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the deliverable was not recorded on the still-open row"
  assert_absent "$home/state/$id.meta" "cleanup did not release the finished worker record"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  assert_grep "still held for the captain" "$home/teardown.out" \
    "cleanup did not say the row stays open for the captain"
  json=$(run_bearings "$home") || fail "Bearings failed after cleanup of a captain-held task"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id and .verb == "captain-hold"))
  ' >/dev/null || fail "the board no longer surfaces the captain call: $json"

  # The ordinary path is untouched: a finished task with no captain call closes.
  plain=sample-plain-review
  mkdir -p "$home/data/$plain"
  tasks_in "$home" add "$plain" "Investigate the sample cache" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the ordinary fixture"
  write_origin_meta "$home" "$plain"
  printf 'done: report complete\n' > "$home/state/$plain.status"
  printf '# Sample cache\n\nNothing waits on the captain.\n' > "$home/data/$plain/report.md"
  run_captain "$home" complete "$plain" --none >/dev/null \
    || fail "completion gate failed for the ordinary investigation"
  run_teardown "$home" "$plain" > "$home/plain.out" 2> "$home/plain.err" \
    || fail "ordinary cleanup failed: $(cat "$home/plain.err")"
  show=$(tasks_in "$home" show "$plain" --full) || fail "the ordinary row vanished"
  assert_contains "$show" "state: done" "ordinary cleanup no longer closes its backlog item"
  assert_contains "$show" "data/$plain/report.md" "ordinary cleanup lost the report link"
  assert_absent "$home/state/$plain.backlog-close" "ordinary cleanup left its pending close behind"

  # Discard authority covers unlanded work, never the captain's question.
  forced=sample-forced-review
  mkdir -p "$home/data/$forced"
  tasks_in "$home" add "$forced" "Investigate the sample forced path" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the forced fixture"
  write_origin_meta "$home" "$forced"
  printf 'done: report complete\n' > "$home/state/$forced.status"
  printf '# Sample forced path\n\nOne captain choice remains.\n' > "$home/data/$forced/report.md"
  run_captain "$home" hold "$forced" --reason "captain must choose the sample forced path" >/dev/null \
    || fail "could not hold the forced fixture for the captain"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$forced" --force \
    > "$home/forced.out" 2> "$home/forced.err" \
    || fail "forced cleanup failed: $(cat "$home/forced.err")"
  show=$(tasks_in "$home" show "$forced" --full) || fail "forced cleanup erased the captain-held row"
  assert_not_contains "$show" "state: done" \
    "discard authority closed a captain call with no recorded answer"
  assert_contains "$show" "state: queued" "forced cleanup left the captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "forced cleanup dropped the captain hold"

  # Only a recorded answer closes the captain call, and the deliverable survives it.
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the surviving captain call could not be answered"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered row is gone"
  assert_contains "$show" "state: done" "the recorded answer did not close the captain call"
  assert_contains "$show" "Ship attachments by reference." "the captain's words were not recorded"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the answer lost the recorded deliverable"
  pass "cleanup leaves a captain-held work item open with its deliverable, and only an answer closes it"
}

# Retention happens after destructive cleanup, through the same pending record
# an ordinary close stages first. A cleanup that fails part-way therefore leaves
# the row exactly as it was, and the next session start finishes the retention
# instead of closing the captain's question.
test_interrupted_cleanup_keeps_the_captain_call_recoverable() {
  local home id wt show rc bootstrap
  home=$(make_home teardown-held-interrupted)
  id=sample-held-cleanup-failure
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  tasks_in "$home" add "$id" "Investigate failed sample cleanup" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the cleanup-failure fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Failed cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after cleanup retry" >/dev/null \
    || fail "could not hold the cleanup-failure fixture"
  run_captain "$home" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed for the cleanup-failure fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.meta" "a failed cleanup removed the task record"
  assert_present "$home/state/$id.backlog-close" \
    "a failed cleanup lost the pending record that replays the retention"
  show=$(tasks_in "$home" show "$id" --full) || fail "a failed cleanup erased the captain call"
  assert_contains "$show" "state: in_flight" "a failed cleanup changed the row before cleanup succeeded"
  assert_contains "$show" "hold_kind: captain" "a failed cleanup dropped the captain hold"
  assert_not_contains "$show" "Deliverable of the finished work" \
    "the deliverable was recorded before destructive cleanup succeeded"

  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay the interrupted retention: $bootstrap"
  assert_contains "$bootstrap" "kept the captain call for $id open" \
    "session start did not report the retained captain call"
  assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  show=$(tasks_in "$home" show "$id" --full) || fail "session start erased the captain call"
  assert_not_contains "$show" "state: done" "session start closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "session start did not return the captain call to the queue"
  assert_contains "$show" "hold_kind: captain" "session start dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "session start did not record the finished work's deliverable"
  pass "an interrupted cleanup keeps the captain call recoverable and session start retains it"
}

# A home whose data directory is relocated keeps one backlog; the predicate and
# the retention must address it the way teardown does, not FM_HOME/data.
test_teardown_retains_captain_calls_in_a_relocated_backlog() {
  local home data id show
  home=$(make_home teardown-relocated-hold)
  data="$home/records"
  mv "$home/data" "$data"
  id=sample-relocated-hold
  mkdir -p "$home/data" "$data/$id"
  # A backlog at the default location stays empty, so a wrongly addressed read
  # would find no row at all.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated sample hold" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated captain-hold fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated hold\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose the relocated sample outcome" >/dev/null \
    || fail "could not hold the relocated work item"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id" >/dev/null \
    || fail "completion gate failed for the relocated captain hold"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the relocated captain hold failed: $(cat "$home/teardown.err")"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the relocated captain-held row disappeared"
  assert_not_contains "$show" "state: done" "cleanup closed the relocated captain call"
  assert_contains "$show" "state: queued" "cleanup left the relocated captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the relocated captain hold"
  assert_contains "$show" "Deliverable of the finished work: report records/$id/report.md" \
    "cleanup did not record the deliverable in the relocated backlog"
  assert_absent "$home/state/$id.meta" "cleanup left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "cleanup left its pending record behind"
  assert_no_grep "$id" "$home/data/backlog.md" "cleanup wrote to the empty default-location backlog"
  pass "cleanup retains captain calls in the configured backlog"
}

# "Cannot tell" is not permission to close. A ship row has no separate
# inventory gate ahead of the close, so the predicate itself must refuse before
# any destructive step when the hold cannot be read.
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read() {
  local home id rc show
  home=$(make_home teardown-ship-hold-read-error)
  id=sample-unreadable-ship-hold
  tasks_in "$home" add "$id" "Ship the sample change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the unreadable-hold fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" "harness=codex" "kind=ship" "mode=direct-PR" \
    "spawn_gen=fixture-$id"
  printf 'done: PR https://github.com/sample/sample/pull/7\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must approve the sample change" >/dev/null \
    || fail "could not hold the ship fixture for the captain"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_FAIL_SHOW_ID:-}" ]; then
  printf 'error: temporary backlog read failure\n' >&2
  exit 75
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    TASKS_AXI_FAIL_SHOW_ID="$id" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup treated an unreadable captain hold as permission to close"
  assert_present "$home/state/$id.meta" "read uncertainty must refuse before removing the task record"
  assert_absent "$home/state/$id.backlog-close" "read uncertainty staged a pending transition anyway"
  show=$(tasks_in "$home" show "$id" --full) || fail "the unreadable captain-held row disappeared"
  assert_contains "$show" "state: in_flight" "read uncertainty allowed cleanup to move the row"
  assert_contains "$show" "hold_kind: captain" "read uncertainty dropped the captain hold"
  assert_grep "could not be read" "$home/teardown.err" "cleanup did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/teardown.err" \
    "the underlying captain-hold read failure was hidden"
  pass "cleanup refuses a ship row when its captain hold cannot be read"
}


# Retention pushes an answered captain call out of the backlog and into the
# configured Done archive, so an inventory recorded several passes ago names a
# task tasks-axi can no longer show. Both gates must still pass on the archived
# answer, name the entry they treated as purged and the record that proved it,
# and keep the live entries checked exactly as before.
test_purged_inventory_entry_passes_on_its_archived_answer() {
  local home id call show archive
  home=$(make_home purged-archived-answer)
  id=sample-retention-review
  call=sample-purged-call
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample retention" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the retention investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'working: report drafted\n' > "$home/state/$id.status"
  printf '# Sample retention review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"

  run_captain "$home" hold "$call" --title "Choose route: north, south" \
    --reason "captain route choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  printf 'Captain, 2026-09-05: "north."\n' > "$home/decision.txt"
  run_captain "$home" answer "$call" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not record the captain answer"
  run_captain "$home" complete "$id" "$call" >/dev/null \
    || fail "completion gate failed while the answered call was still in the backlog"

  archive_out_of_backlog "$home" "$call"
  archive="$home/data/done-archive.md"
  assert_grep "- [x] $call -" "$archive" "retention did not move the answered call into the archive"
  assert_grep "Resolution recorded by fm-captain-hold." "$archive" \
    "the archived row lost the captain answer this gate reads"

  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err" \
    || fail "the completion gate refused an answered captain call that retention archived"
  assert_grep "purged: captain-held task $call" "$home/verify.err" \
    "the gate did not name the entry it treated as purged"
  assert_grep "its archived captain answer in $archive" "$home/verify.err" \
    "the gate did not name the record that proved the purged entry"
  assert_no_grep "captain-held task  is" "$home/verify.err" \
    "the gate emitted a refusal naming no task at all"

  # The vecu command: re-attesting the same finished investigation must pass too.
  run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err" \
    || fail "re-attesting a finished investigation refused because of a purged entry"
  assert_grep "purged: captain-held task $call" "$home/none.err" \
    "completion did not name the purged entry it accepted"
  show=$(tasks_in "$home" list --state "done" --fields body) \
    || fail "could not read the backlog after the purged-entry completion"
  assert_not_contains "$show" "$call" "the purged call reappeared in the live backlog"
  pass "an answered captain call archived by retention still passes the completion gate"
}

# Pre-collapse captain calls are the oldest population, so they are the ones
# retention has most likely already purged, and their metadata records the SHORT
# key while the answered row carries the composed `<origin>-decision-<key>` id.
# The archive must be searched under that identity too, or the gate refuses a
# properly answered call and claims the archive holds nothing it demonstrably
# holds.
test_purged_legacy_identity_passes_on_its_archived_answer() {
  local home id key legacy archive
  home=$(make_home purged-legacy-archived)
  id=sample-legacy-purge-review
  key=route
  legacy="$id-decision-$key"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample legacy purges" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the legacy-purge investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'working: report drafted\n' > "$home/state/$id.status"
  printf '# Sample legacy purge review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"

  # Exactly what the retired fm-decision-hold.sh left behind: a composed row,
  # captain-held, closed with its own resolution record.
  tasks_in "$home" add "$legacy" "Choose the legacy route" --repo sample >/dev/null \
    || fail "could not create the legacy captain-held fixture"
  tasks_in "$home" hold "$legacy" --reason "captain legacy route choice pending" --kind captain >/dev/null \
    || fail "could not hold the legacy fixture for the captain"
  tasks_in "$home" update "$legacy" --body "$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: 0000000000000000000000000000000000000000000000000000000000000000\nResolution mode: answered\n\nCaptain decision:\nThe captain chose the north route.')" >/dev/null \
    || fail "could not record the legacy captain answer"
  tasks_in "$home" "done" "$legacy" >/dev/null || fail "could not close the legacy captain call"

  # The pre-collapse attestation records the short key, never the composed id.
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$key" >> "$home/state/$id.meta"
  archive_out_of_backlog "$home" "$legacy"
  archive="$home/data/done-archive.md"
  assert_grep "- [x] $legacy -" "$archive" "retention did not archive the legacy captain call"
  assert_no_grep "resolved [key=$key]" "$home/state/$id.status" \
    "the fixture recorded a status close that would prove the entry another way"

  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err" \
    || fail "the gate refused a legacy captain call whose archived answer exists"
  assert_grep "purged: captain-held task $key" "$home/verify.err" \
    "the gate did not name the entry it treated as purged"
  assert_grep "legacy identity $legacy" "$home/verify.err" \
    "the gate did not name the composed identity that proved the entry"
  pass "a purged pre-collapse captain call passes on its archived answer"
}

# The second record that outlives the row: the origin's own keyed status close.
# It is evidence only where the archive was genuinely read and holds no row for
# the entry, so this home has a real, populated archive and the captain-held row
# left the backlog through `tasks-axi rm`, which archives nothing.
test_purged_inventory_entry_passes_on_its_status_close() {
  local home id call archive
  home=$(make_home purged-status-close)
  id=sample-statusonly-review
  call=sample-status-closed-call
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample status closes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the status-close investigation fixture"
  write_origin_meta "$home" "$id"
  printf '# Sample status review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "Choose route: north, south" \
    --reason "captain route choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  cat > "$home/state/$id.status" <<EOF
working: report drafted
needs-decision [key=$call]: choose route north or route south
resolved [key=$call]: the captain chose north
EOF
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$call" >> "$home/state/$id.meta"
  seed_done_archive "$home"
  tasks_in "$home" rm "$call" >/dev/null || fail "could not remove the captain-held row"
  if tasks_in "$home" show "$call" >/dev/null 2>&1; then
    fail "the captain-held row survived its removal from the backlog"
  fi
  assert_present "$archive" "the fixture home never built the Done archive this case must read"
  assert_no_grep "- [x] $call -" "$archive" \
    "the fixture archived the very row this case needs the archive to lack"

  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err" \
    || fail "the completion gate refused a call the origin's status log records as closed"
  assert_grep "purged: captain-held task $call" "$home/verify.err" \
    "the gate did not name the entry it treated as purged"
  assert_grep "resolved close for [key=$call]" "$home/verify.err" \
    "the gate did not name the status record that proved the purged entry"
  assert_no_grep "archived captain answer" "$home/verify.err" \
    "the gate credited an archived answer the archive does not hold"
  pass "a purged captain call passes on the origin's recorded status close"
}

# A config that names no archive still HAS one: tasks-axi rotates into its own
# default beside the backlog. The gate must read that default archive, so a call
# answered through `answer` and then rotated is proved by its archived answer and
# never needs a status line.
test_default_done_archive_proves_a_purged_answer() {
  local home id call archive
  home=$(make_home purged-default-archive-answer)
  id=sample-default-archive-review
  call=sample-default-archive-call
  archive="$home/data/done-archive.md"
  write_no_archive_config "$home"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample default archives" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the default-archive investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'working: report drafted\n' > "$home/state/$id.status"
  printf '# Sample default archive review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "Choose route: north, south" \
    --reason "captain route choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  printf 'Captain, 2026-09-05: "north."\n' > "$home/decision.txt"
  run_captain "$home" answer "$call" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not record the captain answer"
  run_captain "$home" complete "$id" "$call" >/dev/null \
    || fail "completion failed while the answered call was still in the backlog"
  archive_out_of_backlog "$home" "$call"
  assert_present "$archive" "tasks-axi did not rotate into its default Done archive"
  assert_grep "- [x] $call -" "$archive" "the default archive did not receive the answered row"
  assert_no_grep "resolved [key=$call]" "$home/state/$id.status" \
    "the fixture recorded a status close that would prove the entry another way"

  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err" \
    || fail "the gate refused an answered call rotated into tasks-axi's default archive"
  assert_grep "purged: captain-held task $call" "$home/verify.err" \
    "the gate did not name the entry it treated as purged"
  assert_grep "its archived captain answer in $archive" "$home/verify.err" \
    "the gate did not read the default Done archive that holds the answer"
  pass "an answered call rotated into the default Done archive passes the gate"
}

# The same default archive must close the back door as well as open the front
# one: a bare `tasks-axi done` close rotated into it proves the call was closed
# with no captain answer, so the origin's resolved line must not override it.
test_default_done_archive_refuses_an_unanswered_rotation() {
  local home id call rc archive
  home=$(make_home purged-default-archive-unanswered)
  id=sample-default-unanswered-review
  call=sample-default-unanswered-call
  archive="$home/data/done-archive.md"
  write_no_archive_config "$home"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample default rotations" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the default-rotation investigation fixture"
  write_origin_meta "$home" "$id"
  printf '# Sample default rotation review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "Choose route: north, south" \
    --reason "captain route choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  tasks_in "$home" "done" "$call" >/dev/null || fail "could not close the row outside the owner"
  cat > "$home/state/$id.status" <<EOF
working: report drafted
needs-decision [key=$call]: choose route north or route south
resolved [key=$call]: the captain chose north
EOF
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$call" >> "$home/state/$id.meta"
  archive_out_of_backlog "$home" "$call"
  assert_grep "- [x] $call -" "$archive" "the default archive did not receive the closed row"
  assert_no_grep "Resolution recorded by fm-captain-hold." "$archive" \
    "the fixture recorded an answer it was supposed to skip"

  set +e
  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a status close overrode an unanswered row in the default archive"
  assert_grep "no captain-held task $call" "$home/verify.err" \
    "the refusal did not name the entry it could not prove"
  assert_grep "closed with no recorded captain answer" "$home/verify.err" \
    "the refusal did not say the default archive holds an unanswered row"
  assert_no_grep "purged: captain-held task" "$home/verify.err" \
    "the gate announced an unanswered rotated call as purged"

  set +e
  run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completion accepted an unanswered row in the default archive"
  pass "an unanswered rotation into the default Done archive is still refused"
}

# The status log gets the same treatment the archive does: a log that exists but
# cannot be opened was never read, so the gate must name it rather than report
# that it records no close.
test_unreadable_status_log_is_named_rather_than_assumed_silent() {
  local home id call rc
  home=$(make_home purged-unreadable-status)
  id=sample-unreadable-status-review
  call=sample-unreadable-status-call
  mkdir -p "$home/data/$id" "$home/shared"
  tasks_in "$home" add "$id" "Investigate sample shared status logs" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unreadable-status investigation fixture"
  write_origin_meta "$home" "$id"
  printf '# Sample shared status review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$call" >> "$home/state/$id.meta"
  cat > "$home/shared/$id.status" <<EOF
working: report drafted
needs-decision [key=$call]: choose route north or route south
resolved [key=$call]: the captain chose north
EOF
  ln -s "$home/shared/$id.status" "$home/state/$id.status"

  set +e
  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unreadable status log was read as proof of a close"
  assert_grep "could not be read" "$home/verify.err" \
    "the refusal did not say the status log could not be read"
  assert_grep "$home/state/$id.status" "$home/verify.err" \
    "the refusal did not name the status log it could not read"
  assert_no_grep "records no resolved close" "$home/verify.err" \
    "the refusal asserted what a status log it never opened records"
  pass "an unreadable origin status log is named rather than assumed silent"
}

# No record either way is still a refusal, and the refusal must be usable: it
# names the entry (never an empty task), both records it looked in, and the
# exact commands that make the call durable again.
test_unprovable_inventory_entry_is_refused_by_name() {
  local home id call rc bare
  home=$(make_home purged-no-evidence)
  id=sample-noevidence-review
  call=sample-unprovable-call
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample gaps" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the no-evidence investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'working: report drafted\n' > "$home/state/$id.status"
  printf '# Sample gap review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$call" >> "$home/state/$id.meta"

  set +e
  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the gate accepted an inventory entry with no record of any close"
  assert_grep "no captain-held task $call" "$home/verify.err" \
    "the refusal did not name the entry it could not prove"
  assert_no_grep "captain-held task  is" "$home/verify.err" \
    "the refusal named no task at all"
  assert_grep "hold $call" "$home/verify.err" "the refusal offered no hold repair command"
  assert_grep "answer $call" "$home/verify.err" "the refusal offered no answer repair command"
  assert_grep "$id-decision-$call" "$home/verify.err" \
    "the refusal claimed the archive holds nothing without naming the legacy identity it searched"

  set +e
  run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completion accepted an inventory entry with no record of any close"
  assert_no_grep "captain-held task  is" "$home/none.err" "completion named no task at all"

  # An origin that carries no attestation file has nothing to edit, so the
  # refusal must not send the operator to a file that does not exist.
  bare=sample-bare-origin
  mkdir -p "$home/data/$bare"
  printf '# Bare origin\n\nThis origin has a report and no metadata.\n' > "$home/data/$bare/report.md"
  assert_absent "$home/state/$bare.meta" "the metadata-less origin fixture was not metadata-less"
  set +e
  run_captain "$home" complete "$bare" sample-typo-call > "$home/bare.out" 2> "$home/bare.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completion accepted an unprovable entry on a metadata-less origin"
  assert_grep "no captain-held task sample-typo-call" "$home/bare.err" \
    "the metadata-less refusal did not name the entry"
  assert_no_grep "decision_keys=" "$home/bare.err" \
    "the refusal advised editing an attestation file that does not exist"
  pass "an inventory entry with no closing record is refused by name with its repair"
}

# The tolerance must not become a way to close a captain call by closing the row
# without recording what the captain said and waiting for retention: a bare
# tasks-axi close leaves no resolution record, and an archived row without one
# proves nothing. This is the same rule the live check applies, unchanged.
test_purged_entry_without_a_recorded_answer_is_still_refused() {
  local home id call rc
  home=$(make_home purged-unanswered)
  id=sample-unanswered-review
  call=sample-unanswered-call
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample closes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unanswered investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'working: report drafted\n' > "$home/state/$id.status"
  printf '# Sample close review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "Choose route: north, south" \
    --reason "captain route choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  tasks_in "$home" "done" "$call" >/dev/null || fail "could not close the row outside the owner"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$call" >> "$home/state/$id.meta"
  archive_out_of_backlog "$home" "$call"
  assert_grep "- [x] $call -" "$home/data/done-archive.md" "retention did not archive the closed row"
  assert_no_grep "Resolution recorded by fm-captain-hold." "$home/data/done-archive.md" \
    "the fixture recorded an answer it was supposed to skip"

  set +e
  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an archived row with no recorded captain answer passed the gate"
  assert_grep "no captain-held task $call" "$home/verify.err" \
    "the refusal did not name the unprovable entry"
  pass "an archived captain call closed with no recorded answer is still refused"
}

# A row that cannot be READ is not a purged row. The purge tolerance must never
# be reached on read uncertainty: the call here is still live, open, and
# unanswered, so treating its unreadable row as purged would pass an open
# captain call on a status close and state a falsehood while doing it.
test_unreadable_inventory_entry_refuses_both_gates() {
  local home id call rc show
  home=$(make_home purged-read-error)
  id=sample-readerror-review
  call=sample-unreadable-call
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample read failures" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the read-error investigation fixture"
  write_origin_meta "$home" "$id"
  printf '# Sample read-error review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "Choose route: north, south" \
    --reason "captain route choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the still-open captain-held task"
  # The status log carries the very record the purge tolerance accepts, so only
  # the absence check can keep this open call from passing.
  cat > "$home/state/$id.status" <<EOF
working: report drafted
needs-decision [key=$call]: choose route north or route south
resolved [key=$call]: the captain chose north
EOF
  # The failing id is baked into the fake rather than carried in the
  # environment, so the read failure needs no subshell around run_captain and
  # cannot leak into another case.
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = "$call" ]; then
  printf 'error: temporary backlog read failure\n' >&2
  exit 75
fi
exec "\${REAL_TASKS_AXI:?}" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  run_captain "$home" complete "$id" "$call" > "$home/complete.out" 2> "$home/complete.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completion treated an unreadable captain call as purged"
  assert_grep "could not be read" "$home/complete.err" "completion did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/complete.err" \
    "the underlying backlog read failure was hidden"
  assert_no_grep "purged: captain-held task" "$home/complete.err" \
    "an unreadable row was announced as purged"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "completion attested an inventory it could not read"

  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$call" >> "$home/state/$id.meta"
  set +e
  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "verification treated an unreadable captain call as purged"
  assert_grep "could not be read" "$home/verify.err" "verification did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/verify.err" \
    "verification hid the underlying backlog read failure"
  assert_no_grep "purged: captain-held task" "$home/verify.err" \
    "verification announced an unreadable row as purged"

  show=$(tasks_in "$home" show "$call" --full) || fail "the unreadable captain call disappeared"
  assert_contains "$show" "hold_kind: captain" "the refusal dropped the captain hold"
  assert_not_contains "$show" "Resolution recorded by fm-captain-hold." \
    "the refusal recorded an answer nobody gave"
  pass "an inventory entry whose row cannot be read refuses both gates"
}

# Rotation alone must never flip a verdict. This is the unanswered-close fixture
# plus the one thing that used to override it: the origin's own resolved close.
# Before retention, verify_hold_durable refuses this state outright; after it,
# the archived row still proves the call was closed with no captain answer, so
# the status log must not be read behind it.
test_archived_unanswered_row_outranks_a_status_close() {
  local home id call rc
  home=$(make_home purged-archive-outranks-status)
  id=sample-precedence-review
  call=sample-precedence-call
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample precedence" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the precedence investigation fixture"
  write_origin_meta "$home" "$id"
  printf '# Sample precedence review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "Choose route: north, south" \
    --reason "captain route choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  tasks_in "$home" "done" "$call" >/dev/null || fail "could not close the row outside the owner"
  cat > "$home/state/$id.status" <<EOF
working: report drafted
needs-decision [key=$call]: choose route north or route south
resolved [key=$call]: the captain chose north
EOF
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$call" >> "$home/state/$id.meta"
  archive_out_of_backlog "$home" "$call"
  assert_grep "- [x] $call -" "$home/data/done-archive.md" "retention did not archive the closed row"
  assert_no_grep "Resolution recorded by fm-captain-hold." "$home/data/done-archive.md" \
    "the fixture recorded an answer it was supposed to skip"

  set +e
  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a status close overrode an archived row proving no captain answer"
  assert_grep "no captain-held task $call" "$home/verify.err" \
    "the refusal did not name the entry it could not prove"
  assert_grep "closed with no recorded captain answer" "$home/verify.err" \
    "the refusal did not say the archive holds an unanswered row"
  assert_no_grep "purged: captain-held task" "$home/verify.err" \
    "the gate announced an unanswered archived call as purged"

  set +e
  run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completion accepted an archived row proving no captain answer"
  assert_grep "no captain-held task $call" "$home/none.err" \
    "the completion refusal did not name the entry"
  pass "an archived row with no recorded answer outranks the origin's status close"
}

# An archive that exists but cannot be opened is not evidence that it holds no
# row, so the gate must name it as unreadable rather than assert what it carries
# or fall through to the status log behind it.
test_unreadable_archive_is_named_rather_than_assumed_empty() {
  local home id call rc
  home=$(make_home purged-unreadable-archive)
  id=sample-unreadable-archive-review
  call=sample-shared-archive-call
  mkdir -p "$home/data/$id" "$home/shared"
  tasks_in "$home" add "$id" "Investigate sample shared archives" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unreadable-archive investigation fixture"
  write_origin_meta "$home" "$id"
  printf '# Sample shared archive review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"
  cat > "$home/state/$id.status" <<EOF
working: report drafted
needs-decision [key=$call]: choose route north or route south
resolved [key=$call]: the captain chose north
EOF
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$call" >> "$home/state/$id.meta"
  # tasks-axi follows a symlinked archive, so retention would write the answered
  # row through it; this gate refuses to read one and must say so.
  printf '## Done\n\n' > "$home/shared/done-archive.md"
  ln -s "$home/shared/done-archive.md" "$home/data/done-archive.md"

  set +e
  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unreadable Done archive was treated as holding no answer"
  assert_grep "could not be read" "$home/verify.err" \
    "the refusal did not say the Done archive could not be read"
  assert_grep "$home/data/done-archive.md" "$home/verify.err" \
    "the refusal did not name the archive it could not read"
  assert_no_grep "carries no archived captain answer" "$home/verify.err" \
    "the refusal asserted what an archive it never opened holds"
  assert_no_grep "purged: captain-held task" "$home/verify.err" \
    "an unreadable archive licensed the status-log fall-through"
  pass "an unreadable Done archive is named rather than assumed to hold no answer"
}

# A purge frees the id, so a captain call answered and archived several passes
# ago can be followed by a fresh call under the very same id. Retention appends
# a new archived section without deduping, so the archive then holds two closed
# rows for one identity: only the newest says whether THIS call was answered,
# and the older answer beneath it must not license a bare `tasks-axi done`.
test_reused_identity_is_judged_on_its_newest_archived_row() {
  local home id call rc archive rows
  home=$(make_home purged-reused-identity)
  id=sample-reuse-review
  call=sample-reused-call
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample id reuse" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the reuse investigation fixture"
  write_origin_meta "$home" "$id"
  printf '# Sample reuse review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"

  # Pass one: the call is held, answered, and rotated out carrying its record.
  run_captain "$home" hold "$call" --title "Choose route: north, south" \
    --reason "captain route choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the first captain-held task"
  printf 'Captain, 2026-09-05: "north."\n' > "$home/decision.txt"
  run_captain "$home" answer "$call" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not record the first captain answer"
  archive_out_of_backlog "$home" "$call"
  assert_grep "Resolution recorded by fm-captain-hold." "$archive" \
    "the first pass did not archive an answered row"

  # Pass two: the freed id carries a new call, closed with a bare tasks-axi done.
  run_captain "$home" hold "$call" --title "Choose route again: east, west" \
    --reason "captain route choice pending again" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the reused captain-held task"
  tasks_in "$home" "done" "$call" >/dev/null || fail "could not close the reused row outside the owner"
  archive_out_of_backlog "$home" "$call"
  rows=$(grep -Fc -- "- [x] $call -" "$archive" || true)
  [ "$rows" = 2 ] || fail "the fixture left $rows archived rows for the reused id instead of two"

  # The origin's resolved close from the first pass survives, so this also pins
  # that it cannot rescue the unanswered newer row behind the archive.
  cat > "$home/state/$id.status" <<EOF
working: report drafted
needs-decision [key=$call]: choose route east or route west
resolved [key=$call]: the captain chose north
EOF
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$call" >> "$home/state/$id.meta"

  set +e
  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a stale archived answer passed a call closed with no recorded answer"
  assert_grep "no captain-held task $call" "$home/verify.err" \
    "the refusal did not name the entry it could not prove"
  assert_grep "closed with no recorded captain answer" "$home/verify.err" \
    "the refusal did not say the newest archived row carries no captain answer"
  assert_grep "2 archived rows" "$home/verify.err" \
    "the refusal did not say how many archived rows that identity carries"
  assert_no_grep "purged: captain-held task" "$home/verify.err" \
    "the gate announced the reused unanswered call as purged"

  set +e
  run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completion accepted a reused call closed with no recorded answer"
  assert_grep "no captain-held task $call" "$home/none.err" \
    "the completion refusal did not name the entry"
  pass "the newest archived row decides a reused captain-call identity"
}

# The second record gets the same two identities the archive does. A
# pre-collapse call was closed on the status side under its composed
# `<origin>-decision-<key>` identity while the attestation records the short
# key, so reading the log under the entry alone would refuse a call the log
# demonstrably records as closed.
test_purged_legacy_identity_passes_on_its_status_close() {
  local home id key legacy archive
  home=$(make_home purged-legacy-status-close)
  id=sample-legacy-status-review
  key=route
  legacy="$id-decision-$key"
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample legacy status closes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the legacy status-close investigation fixture"
  write_origin_meta "$home" "$id"
  printf '# Sample legacy status review\n\nThe evidence is complete.\n' > "$home/data/$id/report.md"

  tasks_in "$home" add "$legacy" "Choose the legacy route" --repo sample >/dev/null \
    || fail "could not create the legacy captain-held fixture"
  tasks_in "$home" hold "$legacy" --reason "captain legacy route choice pending" --kind captain >/dev/null \
    || fail "could not hold the legacy fixture for the captain"
  # The composed row left the backlog without ever being archived, which is
  # exactly what `tasks-axi rm` does, so only the status log still speaks.
  tasks_in "$home" rm "$legacy" >/dev/null || fail "could not remove the legacy captain-held row"
  cat > "$home/state/$id.status" <<EOF
working: report drafted
needs-decision [key=$legacy]: choose the legacy route
resolved [key=$legacy]: the captain chose the north route
EOF
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$key" >> "$home/state/$id.meta"
  seed_done_archive "$home"
  assert_present "$archive" "the fixture home never built the Done archive this case must read"
  assert_no_grep "- [x] $legacy -" "$archive" \
    "the fixture archived the very row this case needs the archive to lack"
  assert_no_grep "resolved [key=$key]" "$home/state/$id.status" \
    "the fixture recorded a short-key close that would prove the entry another way"

  run_captain "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err" \
    || fail "the gate refused a legacy call the origin's status log records as closed"
  assert_grep "purged: captain-held task $key" "$home/verify.err" \
    "the gate did not name the entry it treated as purged"
  assert_grep "resolved close for [key=$legacy]" "$home/verify.err" \
    "the gate did not name the composed key whose status close proved the entry"
  pass "a purged pre-collapse call passes on the status close recorded under its composed key"
}

test_completion_preserves_review_pages_after_status_cleanup() {
  local home id show before after page
  home=$(make_home completion-pages)
  id=sample-review
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-page-call --title "Choisir la suite" --reason "choisir" --repo sample --origin "$id" --until 2026-12-31 >/dev/null || fail "could not hold review"
  before=$(tasks_in "$home" show sample-page-call --full)
  cat > "$home/state/$id.status" <<'EOF'
paused: voir `http://localhost:4387/session/durable`.
needs-decision [key=route]: choisir la suite
EOF
  run_captain "$home" complete "$id" sample-page-call >/dev/null || fail "completion did not retain page"
  assert_grep 'captain-held [key=route]: tracked by sample-page-call' "$home/state/$id.status" "completion did not record its transfer"
  show=$(tasks_in "$home" show sample-page-call --full)
  assert_contains "$show" "http://localhost:4387/session/durable" "held task lost its review page"
  run_captain "$home" complete "$id" sample-page-call >/dev/null || fail "completion retry failed"
  after=$(tasks_in "$home" show sample-page-call --full)
  [ "$show" = "$after" ] || fail "completion retry changed the held task"
  assert_contains "$after" '2026-12-31' "completion lost the hold date"
  [ "$(printf '%s\n' "$before" | sed -n '/Captain hold set:/p')" = "$(printf '%s\n' "$after" | sed -n '/Captain hold set:/p')" ] || fail "completion changed the hold timestamp"
  rm "$home/state/$id.status" "$home/state/$id.meta"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json --all-decisions > "$home/snapshot.json" || fail "post-cleanup projection failed"
  jq -e '.decisions_open[] | select(.id == "sample-page-call") | .links == "http://localhost:4387/session/durable"' "$home/snapshot.json" >/dev/null || fail "durable backlog links lost the page after cleanup"
  FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" compose --snapshot "$home/snapshot.json" --no-quota > "$home/page.json" || fail "post-cleanup composition failed"
  for page in projets a-valider; do
    FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" render "$home/page.json" --page "$page" >/dev/null || fail "post-cleanup rendering failed"
    node "$ROOT/tests/assets/projets-render-harness.mjs" "$home/.lavish/$page.html" > "$home/rendered.json"
    jq -e '.cards[].blocs[].decisions[] | select(.key == "sample-page-call")
      | .pageHref == "http://localhost:4387/session/durable" and .page == "ouvrir la page"' "$home/rendered.json" >/dev/null || fail "page link vanished after cleanup ($page)"
  done
  pass "completion retains review URLs in the held task across retries and status cleanup"
}

test_completion_keeps_control_before_metadata() {
  local home id
  home=$(make_home completion-locks)
  id=sample-locks
  write_origin_meta "$home" "$id"
  run_captain "$home" hold "$id" --title "Choisir la suite" --reason choisir --repo sample >/dev/null || fail "could not hold origin"
  run_captain "$home" hold retained-call --title "Autre choix" --reason choisir --repo sample >/dev/null || fail "could not hold retained call"
  printf 'paused: http://localhost:4387/session/locks\nneeds-decision [key=route]: choisir\n' > "$home/state/$id.status"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = hold ] && [ "${2:-}" = --help ]; then
  touch "$FM_HOME/completion-ready"
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  cat > "$home/cleanup-locks.sh" <<'SH'
#!/usr/bin/env bash
set -e
. "$1/bin/fm-wake-lib.sh"
control="$FM_HOME/state/.control-$2.lock"
meta="$FM_HOME/state/$2.meta"
meta_lock=$(fm_meta_lock_path "$meta")
fm_lock_acquire_wait "$control"
trap 'fm_lock_release "$meta_lock"; fm_lock_release "$control"' EXIT
printf 'ready\n'
read -r _
fm_lock_acquire_wait_bounded "$meta_lock" 3
printf 'decision_keys=retained-call\n' >> "$meta"
SH
  python3 - "$ROOT" "$home" "$id" "$TASKS_AXI_BIN" <<'PYLOCK' || fail "completion and cleanup did not obey the shared lock order"
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
root, home, task, tasks = sys.argv[1:]
env = dict(os.environ, FM_HOME=home, FM_STATE_OVERRIDE=home + '/state',
           FM_DATA_OVERRIDE=home + '/data', FM_CONFIG_OVERRIDE=home + '/config',
           HOME=home, REAL_TASKS_AXI=tasks, PATH=home + '/fakebin:' + os.environ['PATH'])
processes = []
try:
    cleanup = subprocess.Popen(['bash', home + '/cleanup-locks.sh', root, task], env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    processes.append(cleanup)
    assert cleanup.stdout.readline().strip() == 'ready'
    complete = subprocess.Popen([root + '/bin/fm-captain-hold.sh', 'complete', task, task],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
    processes.append(complete)
    deadline = time.monotonic() + 10
    while not Path(home, 'completion-ready').exists():
        assert complete.poll() is None and time.monotonic() < deadline, 'completion never reached inventory validation'
        time.sleep(.02)
    cleanup.stdin.write('continue\n')
    cleanup.stdin.flush()
    _, errors = cleanup.communicate(timeout=8)
    assert cleanup.returncode == 0, 'cleanup could not acquire metadata while completion waited for control: ' + errors
    _, errors = complete.communicate(timeout=15)
    assert complete.returncode == 0, 'completion failed after concurrent metadata update: ' + errors
finally:
    for process in processes:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
PYLOCK
  run_captain "$home" verify "$id" >/dev/null || fail "concurrent completion inventory is not valid"
  assert_grep 'decision_keys=retained-call,sample-locks' "$home/state/$id.meta" "completion lost the inventory written while waiting"
  pass "completion permits control-then-metadata cleanup and rereads concurrent inventory"
}

test_ipv6_review_pages_survive_extraction_and_completion() {
  local home id phase
  home=$(make_home ipv6-pages)
  id=ipv6-review
  write_origin_meta "$home" "$id"
  run_captain "$home" hold "$id" --title "Choisir la revue" --reason choisir --repo sample >/dev/null || fail "could not hold IPv6 review"
  cat > "$home/state/$id.status" <<'EOF'
paused: [revue](http://[::1]:4387/session/abc), `http://[::1]:4387/session/abc`.
needs-decision [key=route]: choisir
EOF
  for phase in status durable; do
    if [ "$phase" = durable ]; then
      run_captain "$home" complete "$id" "$id" >/dev/null || fail "IPv6 page completion failed"
      rm "$home/state/$id.status"
    fi
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json --all-decisions > "$home/snapshot.json" || fail "IPv6 snapshot failed"
    jq -e '.decisions_open[] | select(.id == "ipv6-review") | .links == "http://[::1]:4387/session/abc"' "$home/snapshot.json" >/dev/null || fail "IPv6 authority brackets were lost ($phase)"
    FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" compose --snapshot "$home/snapshot.json" --no-quota > "$home/page.json" || fail "IPv6 composition failed"
    FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" render "$home/page.json" --page a-valider >/dev/null || fail "IPv6 render failed"
    node "$ROOT/tests/assets/projets-render-harness.mjs" "$home/.lavish/a-valider.html" > "$home/rendered.json"
    jq -e '.cards[].blocs[].decisions[] | select(.key == "ipv6-review") | .pageHref == "http://[::1]:4387/session/abc"' "$home/rendered.json" >/dev/null || fail "IPv6 page link is absent ($phase)"
  done
  pass "IPv6 review URLs retain authority brackets in snapshots and durable completion"
}

test_newest_status_page_precedes_older_fallbacks() {
  local home id phase
  home=$(make_home newest-pages)
  id=newest-review
  write_origin_meta "$home" "$id"
  run_captain "$home" hold "$id" --title "Choisir la revue" --reason choisir --repo sample >/dev/null || fail "could not hold versioned review"
  cat > "$home/state/$id.status" <<'EOF'
paused: http://localhost:4387/session/draft
done: http://localhost:4387/session/final
needs-decision [key=route]: choisir
EOF
  for phase in status durable; do
    if [ "$phase" = durable ]; then
      run_captain "$home" complete "$id" "$id" >/dev/null || fail "versioned page completion failed"
      rm "$home/state/$id.status"
    fi
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json --all-decisions > "$home/snapshot.json" || fail "versioned snapshot failed"
    jq -e '.decisions_open[] | select(.id == "newest-review") | (.links | split(" ")) == ["http://localhost:4387/session/final", "http://localhost:4387/session/draft"]' "$home/snapshot.json" >/dev/null || fail "status page priority was reversed ($phase)"
    FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" compose --snapshot "$home/snapshot.json" --no-quota > "$home/page.json" || fail "versioned composition failed"
    FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" render "$home/page.json" --page a-valider >/dev/null || fail "versioned render failed"
    node "$ROOT/tests/assets/projets-render-harness.mjs" "$home/.lavish/a-valider.html" > "$home/rendered.json"
    jq -e '.cards[].blocs[].decisions[] | select(.key == "newest-review") | .pageHref == "http://localhost:4387/session/final"' "$home/rendered.json" >/dev/null || fail "older draft outranked final review ($phase)"
  done
  pass "newest status page wins while older URLs survive as completion fallbacks"
}

test_repeated_completion_promotes_latest_page() {
  local home id version expected page
  home=$(make_home repeated-pages)
  id=repeated-review
  write_origin_meta "$home" "$id"
  run_captain "$home" hold "$id" --title "Choisir la revue" --reason choisir --repo sample >/dev/null || fail "could not hold repeated review"
  for version in draft final draft final cleaned; do
    if [ "$version" = cleaned ]; then
      rm "$home/state/$id.status"
    else
      printf 'done: http://localhost:4387/session/%s\n' "$version" >> "$home/state/$id.status"
      run_captain "$home" complete "$id" "$id" >/dev/null || fail "repeated completion failed ($version)"
      expected="http://localhost:4387/session/$version"
    fi
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json --all-decisions > "$home/snapshot.json" || fail "repeated snapshot failed"
    jq -e --arg expected "$expected" '.decisions_open[] | select(.id == "repeated-review") | (.links | split(" "))[0] == $expected' "$home/snapshot.json" >/dev/null || fail "completion did not promote latest page ($version)"
    if [ "$version" = final ] || [ "$version" = cleaned ]; then
      jq -e '.decisions_open[] | select(.id == "repeated-review") | (.links | split(" ")) == ["http://localhost:4387/session/final", "http://localhost:4387/session/draft"]' "$home/snapshot.json" >/dev/null || fail "completion lost older page fallback ($version)"
    fi
    FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" compose --snapshot "$home/snapshot.json" --no-quota > "$home/page.json" || fail "repeated composition failed"
    for page in projets a-valider; do
      FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" render "$home/page.json" --page "$page" >/dev/null || fail "repeated rendering failed"
      node "$ROOT/tests/assets/projets-render-harness.mjs" "$home/.lavish/$page.html" > "$home/rendered.json"
      jq -e --arg expected "$expected" '.cards[].blocs[].decisions[] | select(.key == "repeated-review")
        | .pageHref == $expected and .page == "ouvrir la page"' "$home/rendered.json" >/dev/null || fail "page opened superseded review ($page, $version)"
    done
  done
  pass "repeated completion promotes new and previously stored pages through status cleanup"
}

test_completion_preserves_hold_title_identity() {
  local home id version title page before after
  for title in 'Choisir la suite' 'Choisir la suite http://localhost:4387/session/draft'; do
    home=$(make_home "title-retry-${#title}")
    id="title-review"
    write_origin_meta "$home" "$id"
    run_captain "$home" hold "$id" --title "$title" --reason choisir --repo sample >/dev/null || fail "could not create titled hold"
    before=$(tasks_in "$home" show "$id" --full | sed -n '/^  title: /p')
    for version in draft final; do
      printf 'done: http://localhost:4387/session/%s\n' "$version" >> "$home/state/$id.status"
      run_captain "$home" complete "$id" "$id" >/dev/null || fail "titled hold completion failed"
      after=$(tasks_in "$home" show "$id" --full | sed -n '/^  title: /p')
      [ "$before" = "$after" ] || fail "completion changed the captain title"
      run_captain "$home" hold "$id" --title "$title" --reason choisir --repo sample >/dev/null || fail "identical hold retry failed after completion"
    done
    if run_captain "$home" hold "$id" --title "$title autre" --reason choisir --repo sample > "$home/refused" 2>&1; then
      fail "different title was accepted after completion"
    fi
    assert_grep 'has a different title' "$home/refused" "different title failed for the wrong reason"
    rm "$home/state/$id.status"
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json --all-decisions > "$home/snapshot.json" || fail "title retry snapshot failed"
    jq -e '.decisions_open[] | select(.id == "title-review") | (.links | split(" ")) == ["http://localhost:4387/session/final", "http://localhost:4387/session/draft"]' "$home/snapshot.json" >/dev/null || fail "hold retry lost newest-first durable links"
    FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" compose --snapshot "$home/snapshot.json" --no-quota > "$home/page.json" || fail "title retry composition failed"
    for page in projets a-valider; do
      FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" render "$home/page.json" --page "$page" >/dev/null || fail "title retry rendering failed"
      node "$ROOT/tests/assets/projets-render-harness.mjs" "$home/.lavish/$page.html" > "$home/rendered.json"
      jq -e '.cards[].blocs[].decisions[] | select(.key == "title-review") | .pageHref == "http://localhost:4387/session/final" and .page == "ouvrir la page"' "$home/rendered.json" >/dev/null || fail "hold retry opened an older page"
    done
  done
  pass "completion preserves strict title identity and ordered links through hold retries"
}

test_rehold_promotes_current_review_page() {
  local home id reason page
  home=$(make_home rehold-pages)
  id=rehold-review
  run_captain "$home" hold "$id" --title 'Choisir la suite' --reason 'voir http://localhost:4387/session/draft' --repo sample >/dev/null || fail "could not hold draft review"
  for reason in 'voir http://localhost:4387/session/final' 'voir http://localhost:4387/session/final' voir; do
    run_captain "$home" hold "$id" --title 'Choisir la suite' --reason "$reason" --repo sample >/dev/null || fail "could not re-hold review"
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json --all-decisions > "$home/snapshot.json" || fail "re-hold snapshot failed"
    jq -e '.decisions_open[] | select(.id == "rehold-review") | (.links | split(" ")) == ["http://localhost:4387/session/final", "http://localhost:4387/session/draft"]' "$home/snapshot.json" >/dev/null || fail "re-hold put stored pages ahead of current page or lost fallbacks"
    FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" compose --snapshot "$home/snapshot.json" --no-quota > "$home/page.json" || fail "re-hold composition failed"
    for page in projets a-valider; do
      FM_HOME="$home" "$ROOT/bin/fm-projets-board.sh" render "$home/page.json" --page "$page" >/dev/null || fail "re-hold rendering failed"
      node "$ROOT/tests/assets/projets-render-harness.mjs" "$home/.lavish/$page.html" > "$home/rendered.json"
      jq -e '.cards[].blocs[].decisions[] | select(.key == "rehold-review") | .pageHref == "http://localhost:4387/session/final" and .page == "ouvrir la page"' "$home/rendered.json" >/dev/null || fail "re-hold opened an older page"
    done
  done
  pass "re-hold promotes current review pages and preserves fallback order on retries"
}

if [ "${1:-}" = --completion-pages ]; then
  test_completion_preserves_review_pages_after_status_cleanup
  test_completion_keeps_control_before_metadata
  test_ipv6_review_pages_survive_extraction_and_completion
  test_newest_status_page_precedes_older_fallbacks
  test_repeated_completion_promotes_latest_page
  test_completion_preserves_hold_title_identity
  test_rehold_promotes_current_review_page
  exit 0
fi

test_completion_preserves_review_pages_after_status_cleanup
test_completion_keeps_control_before_metadata
test_ipv6_review_pages_survive_extraction_and_completion
test_newest_status_page_precedes_older_fallbacks
test_repeated_completion_promotes_latest_page
test_completion_preserves_hold_title_identity
test_rehold_promotes_current_review_page
test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_hold_stamp_precedes_hold_visibility
test_interrupted_answer_preserves_hold_age
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_secondmate_home_publishes_holds_and_answers
test_bound_channel_answers_close_at_answer_time
test_unbound_source_closes_no_hold
test_legacy_identities_keep_working
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
test_withheld_done_does_not_retire_open_decisions
test_teardown_never_closes_a_captain_held_task
test_interrupted_cleanup_keeps_the_captain_call_recoverable
test_teardown_retains_captain_calls_in_a_relocated_backlog
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read
test_purged_inventory_entry_passes_on_its_archived_answer
test_purged_inventory_entry_passes_on_its_status_close
test_unprovable_inventory_entry_is_refused_by_name
test_purged_entry_without_a_recorded_answer_is_still_refused
test_purged_legacy_identity_passes_on_its_archived_answer
test_unreadable_inventory_entry_refuses_both_gates
test_archived_unanswered_row_outranks_a_status_close
test_unreadable_archive_is_named_rather_than_assumed_empty
test_default_done_archive_proves_a_purged_answer
test_default_done_archive_refuses_an_unanswered_rotation
test_unreadable_status_log_is_named_rather_than_assumed_silent
test_reused_identity_is_judged_on_its_newest_archived_row
test_purged_legacy_identity_passes_on_its_status_close

test_verify_resolves_a_hold_migrated_to_beads_notes
test_verify_resolves_a_hold_migrated_under_the_configured_prefix
test_marker_noted_row_wins_over_a_prefix_namesake
test_complete_accepts_a_migrated_inventory_on_beads
test_verify_names_the_unresolvable_legacy_id_once
test_verify_resolves_a_pre_collapse_key_through_its_derived_marker
test_stale_markdown_archive_proves_nothing_on_a_beads_home
test_captain_hold_mutations_address_the_beads_backend
