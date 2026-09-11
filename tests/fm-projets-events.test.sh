#!/usr/bin/env bash
# Exercise event producers, cleanup survival and canonical project projection.
set -eu
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null 2>&1 || { echo 'skip: tasks-axi not found'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-projets-events)
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$TMP_ROOT/root"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config"
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config" "$FM_ROOT_OVERRIDE/bin"
cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
cat > "$FM_HOME/data/backlog.md" <<'DATA'
## In flight
- [ ] torre-pr - Page client (repo: agent-platform) (kind: ship) (since 2026-09-11)
## Queued
## Done
- [x] torre-livraison - Livraison client (repo: agent-platform) (done 2026-09-10)
DATA
fm_write_meta "$FM_HOME/state/torre-pr.meta" "window=firstmate:fm-torre-pr" "endpoint_task_id=torre-pr" "backend=tmux" "worktree=$FM_HOME/projects/missing" "project=agent-platform" "kind=ship" "mode=no-mistakes" "spawn_gen=one"
fakebin=$(fm_fakebin "$FM_HOME")
fm_fake_exit0 "$fakebin" no-mistakes gh gh-axi
fm_fake_exit0 "$FM_ROOT_OVERRIDE/bin" fm-guard.sh
printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tmux"
chmod +x "$fakebin/tmux"
export PATH="$fakebin:$PATH"
url=https://github.com/acme/agent-platform/pull/43
"$ROOT/bin/fm-pr-check.sh" torre-pr "$url" >/dev/null
"$ROOT/bin/fm-pr-check.sh" torre-pr "$url" >/dev/null
at=$(sed -n 's/^pr_recorded_at=//p' "$FM_HOME/state/torre-pr.meta")
jq -se --arg at "$at" 'length == 1 and .[0].kind == "pr" and .[0].at == $at and ($at | test("T[0-9:]+Z$"))' "$FM_HOME/data/torre-pr/events.jsonl" >/dev/null || fail "PR registration lost its clock or duplicated the event"
"$ROOT/bin/fm-captain-hold.sh" hold torre-choix --title 'Hébergement' --reason 'Choisir' --repo agent-platform >/dev/null
printf 'Chez Torre.\n' > "$TMP_ROOT/answer.txt"
"$ROOT/bin/fm-captain-hold.sh" answer torre-choix --decision-file "$TMP_ROOT/answer.txt" >/dev/null
"$ROOT/bin/fm-captain-hold.sh" answer torre-choix --decision-file "$TMP_ROOT/answer.txt" >/dev/null
at=$(jq -r .at "$FM_HOME/data/torre-choix/events.jsonl")
jq -se 'length == 1 and .[0].kind == "decision" and .[0].what == "Chez Torre."' "$FM_HOME/data/torre-choix/events.jsonl" >/dev/null || fail "answer was not preserved exactly once"
(cd "$FM_HOME" && tasks-axi show torre-choix) > "$TMP_ROOT/answer-record.txt"
assert_contains "$(cat "$TMP_ROOT/answer-record.txt")" "Resolution at: $at" "answer body lost its resolution clock"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$ROOT/bin/fm-merge-outcome-lib.sh"
fm_merge_outcome_report "$FM_HOME" "$FM_STATE_OVERRIDE" torre-pr "$url" self
fm_merge_outcome_report "$FM_HOME" "$FM_STATE_OVERRIDE" torre-pr "$url" self
jq -se 'length == 2 and any(.[]; .kind == "merge" and (.at | contains("T")))' "$FM_HOME/data/torre-pr/events.jsonl" >/dev/null || fail "merge event missing or duplicated"
"$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$TMP_ROOT/before.json"
rm "$FM_HOME/state/torre-pr.meta" "$FM_HOME/state/torre-pr.pr-poll-merge-notified"
"$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$TMP_ROOT/after.json"
jq -e --slurpfile before "$TMP_ROOT/before.json" '.events == $before[0].events and any(.events[]; .kind == "pr" and (.at | contains("T"))) and any(.events[]; .kind == "decision" and (.at | contains("T")))' "$TMP_ROOT/after.json" >/dev/null || fail "cleanup changed durable journal events"
"$ROOT/bin/fm-projets-board.sh" init >/dev/null
"$ROOT/bin/fm-captain-hold.sh" hold torre-futur --title 'Plus tard' --reason 'Attendre' --until 2099-10-01 >/dev/null
"$ROOT/bin/fm-projets-board.sh" compose --no-quota > "$TMP_ROOT/payload.json"
"$ROOT/bin/fm-projets-board.sh" render "$TMP_ROOT/payload.json" >/dev/null
jq -e '.badges.decisions == 0 and (.projects[] | select(.id == "torre") | (.journal | length) == 4 and .missing_from_you == [] and any(.gaps[]; contains("mise de côté")))' "$TMP_ROOT/payload.json" >/dev/null || fail "journal or actionable decision filtering failed"
pass "producer clocks survive cleanup and deferred decisions remain outside the badge"
