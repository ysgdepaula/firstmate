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
pr_at=$(sed -n 's/^pr_recorded_at=//p' "$FM_HOME/state/torre-pr.meta")
python3 - "$FM_HOME/state/torre-pr.meta" <<'PYRELAUNCH'
from pathlib import Path
import sys
meta = Path(sys.argv[1])
meta.write_text(meta.read_text().replace("spawn_gen=one", "spawn_gen=two"))
PYRELAUNCH
"$ROOT/bin/fm-pr-check.sh" torre-pr "$url" >/dev/null
jq -se 'length == 1' "$FM_HOME/data/torre-pr/events.jsonl" >/dev/null || fail "worker relaunch duplicated the PR"
python3 - "$FM_HOME/data/torre-pr/events.jsonl" <<'PYLEGACY'
from pathlib import Path
import json, sys
journal = Path(sys.argv[1])
event = json.loads(journal.read_text())
event["key"] = "pr:one:" + event["url"]
journal.write_text(json.dumps(event) + "\n")
PYLEGACY
"$ROOT/bin/fm-pr-check.sh" torre-pr "$url" >/dev/null
jq -se --arg at "$pr_at" 'length == 1 and .[0].kind == "pr" and .[0].at == $at and ($at | test("T[0-9:]+Z$"))' "$FM_HOME/data/torre-pr/events.jsonl" >/dev/null || fail "PR registration lost its clock or duplicated the event"
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
python3 - "$FM_HOME/data/torre-pr/events.jsonl" <<'PYDUPLICATES'
from pathlib import Path
import datetime as dt
import json, sys
journal = Path(sys.argv[1])
events = [json.loads(line) for line in journal.read_text().splitlines()]
original = next(event for event in events if event["kind"] == "pr")
later = dict(original, key="pr:two:" + original["url"])
later["at"] = (dt.datetime.fromisoformat(original["at"].replace("Z", "+00:00")) + dt.timedelta(seconds=10)).strftime("%Y-%m-%dT%H:%M:%SZ")
journal.write_text("".join(json.dumps(event) + "\n" for event in [later, *events]))
PYDUPLICATES
"$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$TMP_ROOT/before.json"
jq -e --arg at "$pr_at" '[.events[] | select(.id == "torre-pr" and .kind == "pr")] | length == 1 and .[0].at == $at' "$TMP_ROOT/before.json" >/dev/null || fail "legacy PR duplicates displaced the original registration"
pass "PR registration survives relaunches and legacy duplicates retain their first clock"
rm "$FM_HOME/state/torre-pr.meta" "$FM_HOME/state/torre-pr.pr-poll-merge-notified"
"$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$TMP_ROOT/after.json"
jq -e --slurpfile before "$TMP_ROOT/before.json" '.events == $before[0].events and any(.events[]; .kind == "pr" and (.at | contains("T"))) and any(.events[]; .kind == "decision" and (.at | contains("T")))' "$TMP_ROOT/after.json" >/dev/null || fail "cleanup changed durable journal events"
"$ROOT/bin/fm-projets-board.sh" init >/dev/null
"$ROOT/bin/fm-captain-hold.sh" hold torre-futur --title 'Plus tard' --reason 'Attendre' --until 2099-10-01 >/dev/null
"$ROOT/bin/fm-projets-board.sh" compose --no-quota > "$TMP_ROOT/payload.json"
"$ROOT/bin/fm-projets-board.sh" render "$TMP_ROOT/payload.json" >/dev/null
jq -e '.badges.decisions == 0 and (.projects[] | select(.id == "torre") | (.journal | length) == 4 and .missing_from_you == [] and any(.gaps[]; contains("mise de côté")))' "$TMP_ROOT/payload.json" >/dev/null || fail "journal or actionable decision filtering failed"
pass "producer clocks survive cleanup and deferred decisions remain outside the badge"

"$ROOT/bin/fm-captain-hold.sh" hold torre-reprise --title 'Livrer après accord' --reason 'Accord' --repo agent-platform >/dev/null
"$ROOT/bin/fm-captain-hold.sh" answer torre-reprise --decision-file "$TMP_ROOT/answer.txt" --release >/dev/null
(cd "$FM_HOME" && tasks-axi "done" torre-reprise >/dev/null)
"$ROOT/bin/fm-fleet-snapshot.sh" --json > "$TMP_ROOT/released.json"
jq -e '[.events[] | select(.id == "torre-reprise") | .kind] | sort == ["decision","landed"]' "$TMP_ROOT/released.json" >/dev/null || fail "released work lost its decision or delivery"
pass "a released and completed task retains its decision and delivery"

python3 - "$FM_DATA_OVERRIDE" <<'PYEVENTS'
import datetime as dt
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
day=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=1)).strftime("%Y-%m-%d")
def row(i):
    return {"schema":"fm-task-events.v1","key":str(i),"kind":"decision","at":f"{day}T00:{i:02}:00Z","what":"é"*4096,"url":None,"repo":"agent-platform"}
for task, indices in [("torre-a-history",range(50))] + [(f"torre-z-{i:02}",[i]) for i in range(30)]:
    folder=root/task
    folder.mkdir()
    (folder/"events.jsonl").write_text("".join(json.dumps(row(i),ensure_ascii=False)+"\n" for i in indices))
bad=root/"torre-middle"
bad.mkdir()
(bad/"events.jsonl").write_text(json.dumps(row(0))+"\n{bad JSON\n")
solo=root/"solos-last"
solo.mkdir()
(solo/"events.jsonl").write_text(json.dumps(dict(row(0),kind="landed",key="solo",what="Livraison Solos",repo="Solos",at="2026-01-01T00:00:00Z"))+"\n")
PYEVENTS
"$ROOT/bin/fm-fleet-snapshot.sh" --json > "$TMP_ROOT/large-events.json"
jq -e '([.events[] | select(.id == "torre-a-history")] | length) == 50
  and ([.events[] | select(.id | startswith("torre-z-"))] | length) == 30
  and all(.events[]; .id != "torre-middle")
  and any(.omitted[]; .surface == "events_unreadable" and .id == "torre-middle")' "$TMP_ROOT/large-events.json" >/dev/null || fail "large or malformed journals broke complete collection"
(
  export FM_BEARINGS_NOW=2026-09-11T01:00:00Z
  "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$TMP_ROOT/compact-events.json"
  "$ROOT/bin/fm-bearings-snapshot.sh" --json --all-events > "$TMP_ROOT/full-events.json"
  "$ROOT/bin/fm-bearings-snapshot.sh" > "$TMP_ROOT/compact-events.toon"
  "$ROOT/bin/fm-bearings-snapshot.sh" --all-events > "$TMP_ROOT/full-events.toon"
)
jq -e '(.events | length) == 20 and all(.events[]; (.what | length) <= 241)
  and ([.events[] | select(.id == "torre-a-history")] | length) == 5
  and any(.omitted[]; .surface == "events_truncated" and .reveal == "--all-events")
  and any(.omitted[]; .surface == "events_text_truncated" and .reveal == "--all-events")' "$TMP_ROOT/compact-events.json" >/dev/null || fail "Bearings event bounds or disclosures are missing"
jq -e --slurpfile compact "$TMP_ROOT/compact-events.json" '(.events | length) > 80
  and any(.events[]; (.what | length) == 4096)
  and del(.events,.omitted) == ($compact[0] | del(.events,.omitted))' "$TMP_ROOT/full-events.json" >/dev/null || fail "all-events changed existing Bearings fields or lost full text"
python3 - "$TMP_ROOT" <<'PYPARITY'
import json, re, sys
from pathlib import Path
root=Path(sys.argv[1])
def tokens(line):
    values=[]
    start=0
    quoted=False
    escaped=False
    for index,char in enumerate(line):
        if escaped:
            escaped=False
        elif quoted and char == "\\":
            escaped=True
        elif char == '"':
            quoted=not quoted
        elif char == ',' and not quoted:
            values.append(line[start:index])
            start=index+1
    values.append(line[start:])
    def scalar(value):
        if value.startswith('"') or value in ('null','true','false') or re.fullmatch(r'-?\d+(?:\.\d+)?',value):
            return json.loads(value)
        return value
    return [scalar(value) for value in values]
for mode in ('compact','full'):
    expected=json.loads((root/f'{mode}-events.json').read_text())
    lines=(root/f'{mode}-events.toon').read_text().splitlines()
    result={}
    index=0
    while index<len(lines):
        line=lines[index]
        match=re.fullmatch(r'([^[]+)\[(\d+)\]\{(.*)\}:',line)
        if match:
            key,count,fields=match.groups()
            columns=tokens(fields)
            result[key]=[dict(zip(columns,tokens(row[2:]))) for row in lines[index+1:index+1+int(count)]]
            index+=int(count)+1
        else:
            key,value=line.split(': ',1)
            result[key]=[] if value=='[]' else tokens(value)[0]
            index+=1
    expected.pop('omitted')
    result.pop('omitted')
    assert result==expected,mode
PYPARITY
"$ROOT/bin/fm-projets-board.sh" compose --no-quota > "$TMP_ROOT/full-events-page.json"
jq -e '.projects[] | select(.id == "solos") | any(.journal[]; .what == "Livraison Solos")' "$TMP_ROOT/full-events-page.json" >/dev/null || fail "project composition did not request the full journal"
pass "Bearings bounds history without changing existing JSON or TOON fields"
"$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null
jq -e '(.events | length) == 20 and ([.events[] | select(.id == "torre-a-history")] | length) == 5
  and any(.omitted[]; .surface == "events_truncated" and .count > 0)
  and any(.omitted[]; .surface == "events_unreadable" and .id == "torre-middle")' "$FM_STATE_OVERRIDE/home-summary.json" >/dev/null || fail "default event bounds or omissions lost"
[ "$(wc -c < "$FM_STATE_OVERRIDE/home-summary.json")" -lt 262144 ] || fail "event projection exceeds parent ledger limit"
FM_SNAPSHOT_SECONDMATE_EVENTS_PER_TASK=2 FM_SNAPSHOT_SECONDMATE_EVENTS=3 "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$TMP_ROOT/bounded.json"
jq -e '(.events | length)==3 and ([.events[] | select(.id=="torre-a-history")] | length)==2' "$TMP_ROOT/bounded.json" >/dev/null || fail "event bound overrides ignored"

mkdir -p "$FM_HOME/bin"
printf 'mate\n' > "$FM_HOME/.fm-secondmate-home"
printf '# Fixture home\n' > "$FM_HOME/AGENTS.md"
parent="$TMP_ROOT/parent"
mkdir -p "$parent/state" "$parent/data" "$parent/config" "$parent/projects"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$parent/data/backlog.md"
printf -- '- mate - fixture (home: %s; scope: fixture work; projects: agent-platform; added 2026-09-11)\n' "$FM_HOME" > "$parent/data/secondmates.md"
fm_write_secondmate_meta "$parent/state/mate.meta" "$FM_HOME" "fmtest:fm-mate" agent-platform claude
parent_run() {
  FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" FM_DATA_OVERRIDE="$parent/data" FM_CONFIG_OVERRIDE="$parent/config" "$@"
}
parent_run "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$TMP_ROOT/parent-bearings.json"
jq -e 'any(.omitted[]; .surface == "events_truncated" and .owner == "mate") and any(.omitted[]; .surface == "events_unreadable" and .id == "torre-middle")' "$TMP_ROOT/parent-bearings.json" >/dev/null || fail "parent bearings lost home journal disclosures"
parent_run "$ROOT/bin/fm-projets-board.sh" init >/dev/null
parent_run "$ROOT/bin/fm-projets-board.sh" compose --snapshot "$TMP_ROOT/parent-bearings.json" --no-quota > "$TMP_ROOT/parent-page.json"
jq -e '(.warnings | length) > 0' "$TMP_ROOT/parent-page.json" >/dev/null || fail "page hid partial event collection"
jq 'del(.events)' "$FM_STATE_OVERRIDE/home-summary.json" > "$TMP_ROOT/legacy.json"
mv "$TMP_ROOT/legacy.json" "$FM_STATE_OVERRIDE/home-summary.json"
parent_run "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$TMP_ROOT/legacy-parent.json"
jq -e 'any(.events[]; .id == "mate/torre-livraison" and .kind == "landed" and .at == "2026-09-10")' "$TMP_ROOT/legacy-parent.json" >/dev/null || fail "legacy home summary lost landed history"
pass "large journal transport, bounded publication, partial disclosure and legacy summaries work through real consumers"

(
  export FM_HOME="$TMP_ROOT/retention-home" FM_ROOT_OVERRIDE="$ROOT"
  export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config"
  mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config" "$FM_HOME/projects" "$FM_HOME/bin"
  cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
  (cd "$FM_HOME" && tasks-axi add torre-etude 'Étude du projet' --kind scout --repo agent-platform >/dev/null && tasks-axi start torre-etude >/dev/null)
  fm_write_meta "$FM_HOME/state/torre-etude.meta" "window=firstmate:fm-torre-etude" "endpoint_task_id=torre-etude" "backend=tmux" "worktree=$FM_HOME/projects/absent" "project=agent-platform" "harness=claude" "kind=scout" "mode=" "spawn_gen=study-one"
  mkdir -p "$FM_HOME/data/torre-etude"
  printf 'Étude terminée.\n' > "$FM_HOME/data/torre-etude/report.md"
  "$ROOT/bin/fm-captain-hold.sh" complete torre-etude --none >/dev/null
  "$ROOT/bin/fm-teardown.sh" torre-etude > "$TMP_ROOT/scout-teardown.txt"
  delivery_at=$(jq -r 'select(.kind == "landed") | .at' "$FM_HOME/data/torre-etude/events.jsonl")
  jq -se 'length == 1 and .[0].kind == "landed" and .[0].what == "Étude du projet" and (.[0].at | test("T[0-9:]+Z$"))' "$FM_HOME/data/torre-etude/events.jsonl" >/dev/null || fail "scout close did not preserve its delivery clock"
  jq '.what = "Livraison terminée"' "$FM_HOME/data/torre-etude/events.jsonl" > "$TMP_ROOT/generic-event.json"
  mv "$TMP_ROOT/generic-event.json" "$FM_HOME/data/torre-etude/events.jsonl"
  for i in {1..10}; do
    (cd "$FM_HOME" && tasks-axi add "fm-next-$i" "Livraison suivante $i" --kind scout --repo firstmate >/dev/null && tasks-axi "done" "fm-next-$i" >/dev/null)
  done
  "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$TMP_ROOT/rotated-fleet.json"
  jq -e --arg at "$delivery_at" 'all(.backlog.records[]; .id != "torre-etude") and ([.events[] | select(.id == "torre-etude")] | length == 1 and .[0].at == $at and .[0].what == "Étude du projet")' "$TMP_ROOT/rotated-fleet.json" >/dev/null || fail "retention removed or duplicated the scout delivery"
  "$ROOT/bin/fm-projets-board.sh" init >/dev/null
  "$ROOT/bin/fm-projets-board.sh" compose --no-quota > "$TMP_ROOT/rotated-page.json"
  jq -e --arg at "$delivery_at" '.projects[] | select(.id == "torre") | (.journal | length) == 1 and .journal[0].at == $at' "$TMP_ROOT/rotated-page.json" >/dev/null || fail "rotated delivery disappeared from its project"
  rm "$FM_HOME/data/torre-etude/events.jsonl"
  "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$TMP_ROOT/archive-fleet.json"
  jq -e --arg day "${delivery_at%%T*}" '[.events[] | select(.id == "torre-etude")] | length == 1 and .[0].kind == "landed" and .[0].at == $day' "$TMP_ROOT/archive-fleet.json" >/dev/null || fail "legacy archived delivery was not recovered with its known date"
  pass "scout deliveries survive real Done rotation, with an archive fallback"

  (cd "$FM_HOME" && tasks-axi add torre-choix-etude 'Étude : choix' --kind scout --repo agent-platform >/dev/null && tasks-axi start torre-choix-etude >/dev/null)
  fm_write_meta "$FM_HOME/state/torre-choix-etude.meta" "window=firstmate:fm-torre-choix-etude" "endpoint_task_id=torre-choix-etude" "backend=tmux" "worktree=$FM_HOME/projects/absent" "project=agent-platform" "harness=claude" "kind=scout" "mode=" "spawn_gen=choice-one"
  mkdir -p "$FM_HOME/data/torre-choix-etude"
  printf 'Choix à confirmer.\n' > "$FM_HOME/data/torre-choix-etude/report.md"
  "$ROOT/bin/fm-captain-hold.sh" hold torre-choix-etude --reason 'Confirmer le choix' >/dev/null
  "$ROOT/bin/fm-captain-hold.sh" complete torre-choix-etude torre-choix-etude >/dev/null
  "$ROOT/bin/fm-teardown.sh" torre-choix-etude > "$TMP_ROOT/held-scout-teardown.txt"
  jq -se 'length == 1 and .[0].kind == "landed" and .[0].what == "Étude : choix"' "$FM_HOME/data/torre-choix-etude/events.jsonl" >/dev/null || fail "retained scout lost its titled delivery"
  "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$TMP_ROOT/held-delivery.json"
  jq -e 'any(.backlog.records[]; .id == "torre-choix-etude" and .state == "queued" and .hold_kind == "captain")' "$TMP_ROOT/held-delivery.json" >/dev/null || fail "delivery closed the captain decision"
  "$ROOT/bin/fm-captain-hold.sh" answer torre-choix-etude --decision-file "$TMP_ROOT/answer.txt" >/dev/null
  "$ROOT/bin/fm-projets-board.sh" compose --no-quota > "$TMP_ROOT/distinct-deliveries.json"
  jq -e '.projects[] | select(.id == "torre") | [.journal[] | select(.kind == "landed") | .what] | sort == ["Étude : choix","Étude du projet"]' "$TMP_ROOT/distinct-deliveries.json" >/dev/null || fail "delivered scouts became indistinguishable after answering"
  pass "retained scout deliveries remain distinct without closing their captain decisions"

  (cd "$FM_HOME" && tasks-axi add torre-42 'Préparer la démonstration' --kind scout --repo agent-platform >/dev/null && tasks-axi start torre-42 >/dev/null)
  mkdir -p "$FM_HOME/projects/demo"
  fm_write_meta "$FM_HOME/state/torre-42.meta" "window=firstmate:fm-torre-42" "endpoint_task_id=torre-42" "backend=tmux" "worktree=$FM_HOME/projects/demo" "project=agent-platform" "harness=claude" "kind=scout" "mode=" "spawn_gen=demo-one"
  child_fakebin=$(fm_fakebin "$FM_HOME")
  cat > "$child_fakebin/tmux" <<'TMUXCHILD'
#!/usr/bin/env bash
case "$1" in display-message) echo claude;; esac
exit 0
TMUXCHILD
  chmod +x "$child_fakebin/tmux"
  export PATH="$child_fakebin:$PATH"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$FM_STATE_OVERRIDE" torre-42)
  "$ROOT/bin/fm-busy-event.sh" apply "$FM_STATE_OVERRIDE" torre-42 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  printf 'mate\n' > "$FM_HOME/.fm-secondmate-home"
  printf '# Fixture home\n' > "$FM_HOME/AGENTS.md"
  "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null
  jq -e '.active_children[] | select(.id == "torre-42") | .title == "Préparer la démonstration"' "$FM_STATE_OVERRIDE/home-summary.json" >/dev/null || fail "home summary lost the active child title"
  printf -- '- mate - fixture (home: %s; scope: fixture work; projects: agent-platform; added 2026-09-11)\n' "$FM_HOME" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/mate.meta" "$FM_HOME" "fmtest:fm-mate" agent-platform claude
  parent_run "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$TMP_ROOT/titled-bearings.json"
  jq -e '.in_flight[] | select(.id == "mate/torre-42") | .title == "Préparer la démonstration"' "$TMP_ROOT/titled-bearings.json" >/dev/null || fail "parent bearings lost the child title"
  parent_run "$ROOT/bin/fm-projets-board.sh" compose --snapshot "$TMP_ROOT/titled-bearings.json" --no-quota > "$TMP_ROOT/titled-page.json"
  jq -e '.projects[] | select(.id == "torre") | any(.doing[]; .result == "Préparer la démonstration")' "$TMP_ROOT/titled-page.json" >/dev/null || fail "project result lost the child title"
  pass "the real home-summary producer carries child titles through bearings to projects"
  mv "$FM_DATA_OVERRIDE/done-archive.md" "$TMP_ROOT/saved-archive.md"
  ln -s "$TMP_ROOT/missing-archive.md" "$FM_DATA_OVERRIDE/done-archive.md"
  "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$TMP_ROOT/broken-archive-fleet.json"
  "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$TMP_ROOT/broken-archive-bearings.json"
  "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null
  for result in "$TMP_ROOT/broken-archive-fleet.json" "$TMP_ROOT/broken-archive-bearings.json" "$FM_STATE_OVERRIDE/home-summary.json"; do
    jq -e 'any(.omitted[]; .surface == "events_archive_unreadable") and any(.events[]; .id == "torre-choix-etude" and .kind == "landed")' "$result" >/dev/null || fail "unavailable archive blocked or silently degraded current reads"
  done
  jq -e 'any(.in_flight[]; .id == "torre-42")' "$TMP_ROOT/broken-archive-bearings.json" >/dev/null || fail "archive failure hid current work"
  pass "broken archives disclose partial history without blocking current projections"
)
