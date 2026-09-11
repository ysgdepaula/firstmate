#!/usr/bin/env bash
# Exercise the canonical fleet reader and bearings journal projection with durable events.
set -eu
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-projets-events)
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$TMP_ROOT/root"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config"
mkdir -p "$FM_HOME/state/terminal-outcomes" "$FM_HOME/data" "$FM_HOME/config" "$FM_ROOT_OVERRIDE"
cat > "$FM_HOME/data/backlog.md" <<'DATA'
## In flight
- [ ] torre-pr - Page client (repo: agent-platform) (kind: ship) (since 2026-09-11)
## Queued
## Done
- [x] torre-livraison - Livraison client (repo: agent-platform) (done 2026-09-10)
- [x] torre-choix - Hébergement choisi (repo: agent-platform) (hold-kind: captain) (done 2026-09-11)
  Resolution recorded by fm-captain-hold.
  Decision digest: example
  Resolution mode: answered
  Captain decision:
  Chez Torre.
DATA
cat > "$FM_HOME/state/torre-livraison.pr-poll-merge-notified" <<'DATA'
fm-pr-poll-merge-notified-v1
github
github.com
acme/agent-platform
42
DATA
cat > "$FM_HOME/state/terminal-outcomes/example.reported" <<'DATA'
schema=fm-terminal-outcome.v1
task_id=torre-livraison
state=done
created_epoch=1789128000
pr=
DATA
mkdir -p "$FM_HOME/projects/page"
fm_write_meta "$FM_HOME/state/torre-pr.meta" "window=firstmate:fm-torre-pr" "backend=tmux" "worktree=$FM_HOME/projects/page" "project=agent-platform" "kind=ship" "pr=https://github.com/acme/agent-platform/pull/43" "pr_recorded_at=2026-09-11T09:15:00Z"
fakebin=$(fm_fakebin "$FM_HOME")
fm_fake_exit0 "$fakebin" no-mistakes
printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tmux"
chmod +x "$fakebin/tmux"
export PATH="$fakebin:$PATH"
"$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$TMP_ROOT/summary.json"
jq -e '.events | any(.[]; .kind == "pr" and .at == "2026-09-11T09:15:00Z")' "$TMP_ROOT/summary.json" >/dev/null || fail "home summary omitted PR clock"
"$ROOT/bin/fm-bearings-snapshot.sh" --json --all-landed > "$TMP_ROOT/bearings.json"
jq -e '.events | any(.[]; .kind == "decision" and .id == "torre-choix" and .at == "2026-09-11")
  and any(.[]; .kind == "merge" and .id == "torre-livraison" and .url == "https://github.com/acme/agent-platform/pull/42" and (.at | contains("T")))
  and any(.[]; .kind == "landed" and .id == "torre-livraison" and (.at | contains("T")))' "$TMP_ROOT/bearings.json" >/dev/null || fail "canonical event projection lost durable events or clocks"
"$ROOT/bin/fm-projets-board.sh" init >/dev/null
"$ROOT/bin/fm-projets-board.sh" compose --snapshot "$TMP_ROOT/bearings.json" --no-quota > "$TMP_ROOT/payload.json"
"$ROOT/bin/fm-projets-board.sh" render "$TMP_ROOT/payload.json" >/dev/null
jq -e '.projects[] | select(.id == "torre") | (.journal | length) == 4 and any(.journal[]; .kind == "decision" and .when == "11/09")' "$TMP_ROOT/payload.json" >/dev/null || fail "journal did not consume projected events"
pass "canonical events preserve merge and receipt clocks plus day-only captain answers"
