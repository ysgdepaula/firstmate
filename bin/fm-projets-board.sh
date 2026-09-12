#!/usr/bin/env bash
# fm-projets-board.sh - compose, render, and arm the /projets Lavish page.
#
# The page is the captain's per-PROJECT view of the fleet: a rail of projects on
# the left, one project at a time on the right, seven blocks per project (what is
# under way, what is missing from the captain, what is missing from others, the
# management pages, this month's costs, the last five captain-facing events, the
# next meeting), and three badges on top (live workers, decisions to take, share
# of the subscriptions spent). The shipped template
# (.agents/skills/projets/assets/page-template.html) plus one injected
# fm-projets-board.v1 JSON payload make the page; this script owns every
# mechanic so the invoking agent's per-run work stays "compose, polish, build".
#
# Usage:
#   fm-projets-board.sh init [--force]
#   fm-projets-board.sh compose [--snapshot <fm-bearings.v1.json>] [--config <projets.json>]
#                               [--quota <quota-axi.json> | --no-quota] [--costs <couts.json>]
#                               [--agenda <agenda.json>] [--now <iso8601>]
#   fm-projets-board.sh render <payload.json>
#   fm-projets-board.sh build <payload.json>
#   fm-projets-board.sh path
#
# init       Copy the shipped seven-project seed (six projects plus the captain's
#            brain card, flagged `brain: true`) to config/projets.json; preserve
#            an existing table unless --force is supplied.
# compose    Print a mechanically composed fm-projets-board.v1 payload on stdout.
#            The ONLY fleet-state reader is bin/fm-bearings-snapshot.sh (run with
#            --all-events and expanded work views; upstream home bounds remain
#            disclosed). This script never parses raw fleet-state files. Grouping BY PROJECT is the
#            novelty: each row's task id and repo are matched against the private
#            correspondence table config/projets.json (schema fm-projets-config.v1,
#            owned by docs/configuration.md "Projects page"), id prefix first,
#            longest prefix wins, then repo. Without a table every repo becomes
#            its own project and the page says the table is missing. Rows that
#            match nothing land in the brain card's `unlinked`, or `unassigned`
#            when no brain card is configured. Costs come from the optional measured file
#            data/projets-couts.json (schema fm-projets-couts.v1) plus quota-axi's
#            subscription windows; anything unmeasured stays null and the page
#            prints "a mesurer" instead of a number. Calendar readings come from
#            data/projets-agenda.json and merge with chat dates in the table.
#            Readings older than a day are unavailable; differing dates stay visible.
#            Bidirectional synchronization is a following task. Every captain-facing
#            string is passed through the internal-vocabulary filter below before
#            it reaches the payload, and the composer translates each task state
#            into plain French. The rail order is decided here: projects sort by
#            how many decisions wait on the captain, most first, then by name.
# render     Validate the payload and inject it into a fresh copy of the shipped
#            template at the stable page path. No Lavish call, no registration:
#            this is what tests and screenshot captures use. Prints `board: <path>`,
#            then `stable: <url>` when config/projets-serve.json exists, because
#            bin/fm-projets-serve.sh serves that same file at a fixed tailnet
#            address that a rebuild in place never moves.
# build      render, then establish or resume the Lavish session on the page,
#            then arm it as a process-event source (arm-if-absent). Output:
#              board: <path>
#              <lavish-axi session output>
#              served: <path>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#            Serve-first is the same ordering rule as bin/fm-bearings-board.sh: a
#            registered poll can never race a session that does not exist.
#            DELIBERATELY NO keyed-answer binding (bin/fm-captain-hold.sh bind):
#            the captain decided that a page button SENDS the answer to firstmate,
#            who asks the question again in chat before acting, and that nothing
#            acts directly from the page. The template therefore queues plain
#            Lavish prompts whose context data carries `projet`, `decision`,
#            `choix`, and `nature` (never the `question`/`answer` pair the keyed
#            intake reads), so even a bound source could not close a task from
#            a click.
# path       Print the stable page path for this home.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-projets-board.v1 and every renderer-consumed field must satisfy the
# types and invariants below, including the captain-vocabulary filter on every
# captain-facing string. Anything else refuses before the existing page is
# touched; decision keys must be unique within each project.
# Recommendation and article keys include a digest of the full source title.
#
# fm-projets-board.v1 (all strings are captain-facing French unless noted):
#   schema, home, generated (iso8601), updated_label ("11/09 00h30")
#   badges: {workers:int, decisions:int, subscriptions:string|null}
#   projects[]: {id:slug, name, brain:bool, headline:string|null, team:string|null, deadline:{label,date}|null,
#     doing[]: {id, owner, local_id, result, status, next:string|null, url:allowed|null, url_refused?:string},
#     scouts[]: same shape as doing, the investigations running for this project's brain,
#     missing_from_you[]: {key:slug, owner, local_id, question, nature?:"decision"|"etat",
#       ask?:string|null, options[]: {value:slug, label}, kind?:string,
#       url:allowed|null, url_refused?:string} (kind "recommandation" or "article" marks a table-born entry),
#     creations[]: {label, kind:string|null, url:allowed|null, url_refused?:string},
#     unlinked[]: {id, what} (brain card only: rows that match no project),
#     quick_wins[]: string (brain card only),
#     missing_from_others[]: {who, what, tag:string|null},
#     pages[]: {label, url:allowed|null, url_refused?:string, state:string|null},
#     costs: {period, tokens_api:string|null, subscription_share:string|null, source},
#     journal[] (max 5): {when:string|null, what, url:allowed|null, url_refused?:string},
#     meeting: null | {title, date:YYYY-MM-DD, time:string|null, source, with:string|null, bring[], decide[]},
#     meetings[]: same meeting shape, meeting_warning:string|null, agenda_available:bool, partial:bool,
#     gaps[]: string}
#   unassigned[]: {id, what} (empty when a brain card carries them as `unlinked`)
#   table_missing: bool, warnings[]: captain-facing collection limitations
# The brain card (the table's single `brain: true` project) swaps two blocks: "pas
# encore rattache a un projet" replaces "il manque des autres", and "quick wins du
# cerveau" replaces the meeting; its articles to validate and every project's
# recommendations join "il manque de toi" as closed choices sent to firstmate.
# Allowed links: HTTPS, or HTTP on loopback, RFC1918 IPv4, the Tailscale range 100.64/10, and .ts.net hosts.
# Refused links retain url_refused and render an explicit refusal.
# bin/fm-projets-data.jq owns this shared composition/validation policy.
#
# Two natures in "il manque de toi", never mixed, because the page never claims
# to know what it does not know. `nature` is "decision" (do we do it, or not) or
# "etat" (is it already done), and `ask` is the line the card shows to declare
# which one it asks. A held task records neither nature, so the composer's
# fallback is always a decision - "on y va / on ne le fait pas / pas maintenant /
# on en parle" - and never guesses a state question out of free text. A state
# question exists only where config/projets.json recorded `"nature": "etat"` for
# that task, which is firstmate's recorded reason to believe the captain may
# already have done the thing; its `ask` is then always the admission "je ne sais
# pas si c'est deja fait", and its fallback affirmative is the captain's own
# declaration "je l'ai fait", followed by "pas encore / on en parle", never a
# claim firstmate makes. A table entry with nonempty options keeps them verbatim;
# only a decision entry then sets `ask` to null, while an "etat" entry retains its
# admission. Without configured options, a decision's `ask` is "on le fait, ou
# on ne le fait pas ?". The composer emits both fields; older payloads may omit
# them, and a click without `nature` sends "decision". The validator requires a
# nonempty captain-facing `ask` for "etat", but does not enforce its exact text.
#
# Captain vocabulary: no string may carry an internal term (crewmate, brief,
# gate, teardown, worktree, watcher, heartbeat, wake, harness, backend, stale,
# checkout, spawn, hook, pane, needs-decision, ask-user, fail-closed,
# fail-open); the composer drops such details and the validator refuses them.
# "worker" is the captain's own word for a live helper and stays allowed.
#
# The page path is stable - $FM_HOME/.lavish/projets.html - so a rebuild keeps
# the same Lavish session URL and the same canonical process-event source id.
# Injection escapes every `<` in the compact JSON as the \u003c string escape,
# so a payload string containing "</script>" can never end the data block early.
#
# FM_PROJETS_BOARD_TEMPLATE overrides the shipped template path (tests only).
# FM_PROJETS_QUOTA_TIMEOUT bounds the quota-axi call in seconds (default 15).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

TEMPLATE="${FM_PROJETS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/projets/assets/page-template.html}"
PLACEHOLDER='__FM_PROJETS_BOARD_DATA__'
BOARD_SCHEMA=fm-projets-board.v1
CONFIG_SCHEMA=fm-projets-config.v1
COSTS_SCHEMA=fm-projets-couts.v1
QUOTA_TIMEOUT=${FM_PROJETS_QUOTA_TIMEOUT:-15}
case "$QUOTA_TIMEOUT" in ''|*[!0-9]*|0) QUOTA_TIMEOUT=15 ;; esac

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-projets-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/projets.html\n' "$FM_HOME"; }

# One owner for the vocabulary rule: the composer filters with it, the
# validator refuses with it. Word-bounded, case-insensitive.
INTERNAL_RE='(?i)(^|[^a-z0-9_-])(crewmate|crewmates|brief|briefs|gate|gates|teardown|worktree|worktrees|watcher|heartbeat|wake|wakes|harness|backend|backends|stale|checkout|spawn|spawned|hook|hooks|pane|panes|needs-decision|ask-user|fail-closed|fail-open)([^a-z0-9_-]|$)'

# FM_PROJETS_TIMEZONE overrides the table timezone (default Europe/Paris).
# --- compose ----------------------------------------------------------------
snapshot_default() {
  FM_BEARINGS_IN_FLIGHT=500 FM_BEARINGS_DECISIONS=500 FM_BEARINGS_LANDED=500 \
  FM_BEARINGS_LANDED_PER_HOME=500 FM_BEARINGS_GATES=500 FM_BEARINGS_RECORDED_PRS=500 \
    "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --all-events --all-in-flight --all-landed --all-queued --all-secondmates --all-recorded-prs
}

quota_default() {  # prints quota-axi JSON or nothing
  command -v quota-axi >/dev/null 2>&1 || return 0
  fm_run_timed "$QUOTA_TIMEOUT" quota-axi --json 2>/dev/null || true
}

command_compose() {
  local snapshot="" config="" quota="" no_quota=0 costs="" now="" agenda=""
  local agenda_json calendar_now calendar_timezone
  local snap_json cfg_json quota_json costs_json decision_hashes
  while [ $# -gt 0 ]; do
    case "$1" in
      --snapshot) shift; snapshot=${1:?--snapshot needs a file} ;;
      --config) shift; config=${1:?--config needs a file} ;;
      --quota) shift; quota=${1:?--quota needs a file} ;;
      --no-quota) no_quota=1 ;;
      --costs) shift; costs=${1:?--costs needs a file} ;;
      --agenda) shift; agenda=${1:?--agenda needs a file} ;;
      --now) shift; now=${1:?--now needs an iso8601 timestamp} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -n "$now" ] || now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ -n "$snapshot" ]; then
    [ -f "$snapshot" ] || fail "snapshot does not exist: $snapshot"
    snap_json=$(cat "$snapshot")
  else
    snap_json=$(snapshot_default) || fail "cannot read the fleet snapshot"
  fi
  printf '%s' "$snap_json" | jq -e '.schema == "fm-bearings.v1"' >/dev/null 2>&1 \
    || fail "the snapshot is not an fm-bearings.v1 document"

  [ -n "$config" ] || config="$CONFIG/projets.json"
  if [ -f "$config" ]; then
    cfg_json=$(jq -c . "$config" 2>/dev/null) || fail "the project table is not valid JSON: $config"
    printf '%s' "$cfg_json" | jq -e --arg s "$CONFIG_SCHEMA" '
      .schema == $s and (.projects | type == "array")
      and ([.projects[] | type == "object"
            and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))
            and (.name | type == "string" and length > 0)
            and ((has("prefixes") | not) or (.prefixes | type == "array" and all(.[]; type == "string" and length > 0)))
            and ((has("repos") | not) or (.repos | type == "array" and all(.[]; type == "string" and length > 0)))
            and ((has("brain") | not) or (.brain | type == "boolean"))
           ] | all)
      and ([.projects[].id] | unique | length) == (.projects | length)
      and ([.projects[] | select(.brain == true)] | length) <= 1
    ' >/dev/null 2>&1 || fail "the project table does not satisfy $CONFIG_SCHEMA: $config"
  else
    cfg_json='null'
  fi

  decision_hashes=$(printf '%s' "$cfg_json" | python3 -c '
import hashlib, json, sys
cfg = json.load(sys.stdin) or {}
hashes = {}
for project in cfg.get("projects", []):
    for field, title in (("recommendations", "what"), ("articles", "title")):
        for entry in project.get(field) or []:
            text = entry.get(title) if isinstance(entry, dict) else entry
            if isinstance(entry, dict) and (text is None or text is False):
                text = ""
            if not isinstance(text, str):
                text = json.dumps(text, ensure_ascii=False, separators=(",", ":"))
            hashes[text] = hashlib.sha256(text.encode()).hexdigest()[:12]
print(json.dumps(hashes))
') || fail "cannot identify project recommendations and articles"

  calendar_timezone=${FM_PROJETS_TIMEZONE:-$(printf '%s' "$cfg_json" | jq -r '.timezone // "Europe/Paris"')}
  calendar_now=$(python3 - "$now" "$calendar_timezone" <<'PYTIME'
import datetime, sys
from zoneinfo import ZoneInfo
now = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
if now.tzinfo is None:
    raise ValueError("--now requires a timezone")
print(now.astimezone(ZoneInfo(sys.argv[2])).strftime("%Y-%m-%dT%H:%M:%S"))
PYTIME
  ) || fail "invalid calendar timezone or current timestamp"

  if [ "$no_quota" = 1 ]; then
    quota_json='null'
  elif [ -n "$quota" ]; then
    [ -f "$quota" ] || fail "quota file does not exist: $quota"
    quota_json=$(jq -c . "$quota" 2>/dev/null) || fail "the quota file is not valid JSON: $quota"
  else
    quota_json=$(quota_default)
    [ -n "$quota_json" ] && printf '%s' "$quota_json" | jq -e . >/dev/null 2>&1 || quota_json='null'
  fi

  [ -n "$costs" ] || costs="$DATA/projets-couts.json"
  if [ -f "$costs" ]; then
    costs_json=$(jq -c . "$costs" 2>/dev/null) || fail "the costs file is not valid JSON: $costs"
    printf '%s' "$costs_json" | jq -e --arg s "$COSTS_SCHEMA" '.schema == $s and (.projects | type == "object")' >/dev/null 2>&1 \
      || fail "the costs file does not satisfy $COSTS_SCHEMA: $costs"
  else
    costs_json='null'
  fi

  [ -n "$agenda" ] || agenda="$DATA/projets-agenda.json"
  agenda_json=null
  if [ -f "$agenda" ]; then
    agenda_json=$(jq -c 'select(.schema == "fm-projets-agenda.v1" and (.meetings | type == "array"))' "$agenda" 2>/dev/null) || agenda_json=null
    [ -n "$agenda_json" ] || agenda_json=null
  fi

  printf '%s' "$snap_json" | jq -L "$SCRIPT_DIR" \
    --argjson agenda "$agenda_json" \
    --arg now "$now" --arg calendar_now "$calendar_now" \
    --arg internal_re "$INTERNAL_RE" \
    --argjson cfg "$cfg_json" \
    --argjson decision_hashes "$decision_hashes" \
    --argjson quota "$quota_json" \
    --argjson costs "$costs_json" '
  include "fm-projets-data";
  def clean: tostring | gsub("\\s+"; " ") | gsub("^ | $"; "");
  def trunc($n): clean | if length > $n then .[:($n - 1)] + "…" else . end;
  def safe: test($internal_re) | not;
  def fr_day: if . == null then null else
    ((capture("^(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})")? // null) | if . == null then null else "\(.d)/\(.m)" end) end;
  def local_id: split("/") | last;
  def identity: {owner:(.owner // (if (.id | contains("/")) then (.id | split("/") | .[0]) else "(main)" end)), local_id:(.id | local_id)};
  def state_label:
    {working: "en cours", parked: "attend une réponse", paused: "en pause, attente extérieure",
     blocked: "bloqué", done: "livré", failed: "en échec", unknown: "état inconnu", dead: "arrêté"}[.]
    // "état inconnu";
  def month_label:
    (["janvier","février","mars","avril","mai","juin","juillet","août","septembre","octobre","novembre","décembre"]) as $m
    | ($now | capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})")?) as $c
    | if $c == null then "ce mois" else $m[($c.mo | tonumber) - 1] end;
  def updated_label:
    ($now | capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2})")?)
    | if . == null then $now else "\(.d)/\(.mo) \(.h)h\(.mi)" end;
  def id_words($prefixes):
    . as $id
    | ([ $prefixes[] | . as $pre | select($id | startswith($pre)) ] | sort_by(-length) | .[0]) as $p
    | (if $p == null then $id else ($id | ltrimstr($p)) end)
    | gsub("[-_]+"; " ") | clean;
  def fallback($pfx): . as $id | (local_id | id_words($pfx)) | if safe and length > 0 then . else ($id | if safe and length > 0 then . else "travail en cours" end) end;
  def slugify: ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "") | .[:60] | if length == 0 then "x" else . end;
  def captain_text: tostring | clean | select(length > 0 and safe);
  def optional_captain_text: if . == null then null else (captain_text // null) end;
  # A title that opens with the project name or its id prefix ("Torre : ...",
  # "chef: ...") repeats the card heading, so the card drops that label.
  def strip_label($name; $prefixes):
    . as $s
    | ([ $name, ($prefixes[] | rtrimstr("-") | rtrimstr("_")) ] | map(select(length > 0))
       | map(ascii_downcase) | unique) as $labels
    | (reduce $labels[] as $l ($s;
         if (. | ascii_downcase | test("^" + ($l | gsub("[^a-z0-9]"; ".")) + " ?: ")) then
           (. | sub("^[^:]*: "; "")) else . end))
    | clean;

  ($cfg.projects // []) as $projects
  | ($projects | length > 0) as $has_table
  | ([ $projects[] | select(.brain == true) | .id ] | .[0] // null) as $brain_id
  | ($calendar_now[:10]) as $today
  | def prefix_match($id):
      ([ $projects[] | . as $p | ($p.prefixes // [])[] | . as $pre | select($id | local_id | startswith($pre)) | {id: $p.id, n: ($pre | length)} ]
       | sort_by(-.n) | .[0].id);
  def repo_match($repo):
      if $repo == null then null
      else ([ $projects[] | select(((.repos // []) | index($repo)) != null) | .id ] | if length == 1 then .[0] else null end) end;
  def project_of($id; $repo):
      if $has_table then (prefix_match($id) // repo_match($repo)) else $repo end;
  def project_cfg($pid): ([ $projects[] | select(.id == $pid) ] | .[0]) // {};
  def prefixes_of($pid): (project_cfg($pid).prefixes // []);

  ([.omitted[]? | select((.surface // "") | test("unreadable|unavailable|showing|capped|truncated|omitted|cached|no child metadata|unstructured")) | "Collecte partielle : certaines informations ne sont pas disponibles."]
   + [.secondmates[]? | select((.state // "" | test("unknown|unavailable|unreadable")) or (.freshness // "" | test("unavailable|stale|unknown")) or (.provenance // "" | test("cache|fallback"))) | "État partiel : une équipe ne peut pas être lue à jour."] | unique) as $warnings
  | (($agenda.read_at | project_epoch) as $read | ($now | project_epoch) as $clock
     | $read != null and $clock != null and $clock - $read >= 0 and $clock - $read <= 86400) as $agenda_fresh
  | ([ .recorded_prs[]? | {key: .id, value: .url} ] | from_entries) as $pr_by_id
  | ([ .in_flight[] | . + {project: project_of(.id; .repo)} ]) as $doing_rows
  | ([ .decisions_open[] | . + {project: project_of(.id; (.repo // null))} ]) as $decision_rows
  | ([ .landed[] | . + {project: project_of(.id; (.repo // null))} ]) as $landed_rows
  | ([ (.events // [.landed[]? | {id,repo,owner,what,url:.artifact,at:.date,kind:"landed"}])[] | . + {project:project_of(.id; .repo)} ]) as $event_rows
  | ([ .gates[]? | select(.reason | test("^(until |held [0-9]+d)")) | . + {project: project_of(.id; null)} ]) as $deferred_rows
  | (if $has_table then [ $projects[] | {id, name} ]
     else ([ ($doing_rows + $decision_rows + $landed_rows + $event_rows)[] | .project | select(. != null) ] | unique | map({id: ., name: .})) end) as $project_list
  | ($quota.providers // [] | [ .[]
       | select(type == "object")
       | (.provider // "?") as $p
       | ((.quotaSemantics.effectiveAvailability // []) | map(select(.scope == "all_models")) | .[0].effectivePercentRemaining) as $left
       | select($left != null and ($left | type) == "number")
       | "\($p | (.[:1] | ascii_upcase) + .[1:]) \(100 - ($left | floor)) %" ]
     | if length == 0 then null else join(" · ") end) as $subscriptions
  | (if $costs.period == $now[:7] then ($costs.projects // {}) else {} end) as $cost_map
  | ([ ($doing_rows + $decision_rows + $landed_rows + $event_rows)[] | select(.project == null)
       | {id, what: ((.title // .summary // .what // .id) | clean | if safe then trunc(110) else "élément sans projet" end)} ]
     | unique_by(.id)) as $unassigned
  | [ $project_list[] | . as $proj
      | ($proj.id == $brain_id) as $is_brain
      | (prefixes_of($proj.id)) as $pfx
      | (project_cfg($proj.id)) as $pc
      | ([ $doing_rows[] | select(.project == $proj.id)
           | . as $r
           | (($r.doing // "") | clean) as $detail
           | ($r.state | state_label) as $label
           | ($pr_by_id[$r.id] // null) as $url
           # The words of the worker explain a pause, a block, or a failure; every
           # detail of every other state is machinery and stays off the page.
           | (($r.state == "paused" or $r.state == "blocked" or $r.state == "failed")
              and ($detail | length) > 0 and ($detail | safe)) as $keep_detail
           | {id: $r.id, kind: ($r.kind // "ship"),
              result: (($r.title // null) as $t
                       | if $t != null and ($t | clean | length) > 0 and ($t | safe)
                         then ($t | strip_label($proj.name; $pfx) | trunc(110))
                         else ($r.id | fallback($pfx)) end | if safe and length > 0 then . else ($r.id | fallback($pfx)) end),
              status: (if $keep_detail then ($label + " · " + ($detail | trunc(90))) else $label end),
              next: (if $r.state == "done" and $url != null then "fusion à confirmer"
                     elif $r.state == "parked" then "ta réponse débloque la suite"
                     elif $r.state == "blocked" then "firstmate doit débloquer"
                     else null end),
              url: null} + ($r | identity) + ($url | project_link) ]) as $doing_all
      | ([ $doing_all[] | select(.kind != "scout") | del(.kind) ]) as $doing
      | ([ $doing_all[] | select(.kind == "scout") | del(.kind) ]) as $scouts
      | ([ $decision_rows[] | select(.project == $proj.id)
           | . as $d
           | (($pc.decisions // {})[$d.id] // ($pc.decisions // {})[($d.id | local_id)] // {}) as $dc
           | (($dc.question // $d.title // $d.summary // $d.id) | clean) as $q
           # The header owns nature selection and the unknown-state admission.
           | (if ($dc.nature // "") == "etat" then "etat" else "decision" end) as $nature
           | ((($dc.options // []) | length) > 0) as $closed
           | {key: ($d.id | gsub("/"; "__")),
              question: (if ($q | safe) then ($q | strip_label($proj.name; $pfx) | trunc(160)) else ($d.id | fallback($pfx)) end | if safe and length > 0 then . else ($d.id | fallback($pfx)) end),
              nature: $nature,
              ask: (if $nature == "etat" then "je ne sais pas si c\u2019est d\u00e9j\u00e0 fait"
                    elif $closed then null
                    else "on le fait, ou on ne le fait pas ?" end),
              options: (if $closed then [ $dc.options[] | {value, label} ]
                        elif $nature == "etat" then
                          [{value: "je-l-ai-fait", label: "je l\u2019ai fait"},
                           {value: "pas-encore", label: "pas encore"},
                           {value: "on-en-parle", label: "on en parle"}]
                        else
                          [{value: "on-y-va", label: "on y va"},
                           {value: "on-ne-le-fait-pas", label: "on ne le fait pas"},
                           {value: "pas-maintenant", label: "pas maintenant"},
                           {value: "on-en-parle", label: "on en parle"}] end),
              url: null,
              configured: $closed} + ($d | identity) + (($dc.url // $d.url // $pr_by_id[$d.id]) | project_link) ]) as $decisions_you
      # Recommendations are what firstmate proposes and the captain has not ruled
      # on yet: they wait on him exactly like a decision, as closed choices.
      | ([ ($pc.recommendations // [])[] | . as $rc
           | ((if ($rc | type) == "object" then ($rc.what // "") else $rc end) | tostring) as $text
           | ($text | captain_text) as $w
           | ("reco__" + ($w | slugify) + "-" + $decision_hashes[$text]) as $key
           | ((if ($rc | type) == "object" then ($rc.why // null) else null end) | optional_captain_text) as $why
           | {key: $key, owner: "(main)", local_id: $key,
              question: (($w + (if $why != null then " : " + $why else "" end)) | trunc(200)),
              nature: "decision", ask: null,
              options: [{value: "on-y-va", label: "on y va"}, {value: "pas-maintenant", label: "pas maintenant"}, {value: "on-en-parle", label: "on en parle"}],
              kind: "recommandation", configured: true}
             + ((if ($rc | type) == "object" then ($rc.url // null) else null end) | project_link) ]) as $recommendations
      | (if $is_brain then
           [ ($pc.articles // [])[] | . as $ar
             | ((if ($ar | type) == "object" then ($ar.title // "") else $ar end) | tostring) as $text
             | ($text | captain_text) as $t
             | ("article__" + ($t | slugify) + "-" + $decision_hashes[$text]) as $key
             | {key: $key, owner: "(main)", local_id: $key,
                question: (("Article à valider : " + $t) | trunc(200)),
                nature: "decision", ask: null,
                options: [{value: "valide", label: "validé"}, {value: "a-revoir", label: "à revoir"}, {value: "plus-tard", label: "plus tard"}],
                kind: "article", configured: true}
               + ((if ($ar | type) == "object" then ($ar.url // null) else null end) | project_link) ]
         else [] end) as $articles
      | ($decisions_you + $recommendations + $articles) as $missing_you
      | ([ ($pc.creations // [])[] | . as $cr
           | ((if ($cr | type) == "object" then ($cr.label // "") else $cr end) | captain_text) as $l
           | {label: $l, kind: ((if ($cr | type) == "object" then ($cr.kind // null) else null end) | optional_captain_text)}
             + ((if ($cr | type) == "object" then ($cr.url // null) else null end) | project_link) ]) as $creations
      | (if $is_brain then [ ($pc.quick_wins // [])[] | captain_text ] else [] end) as $quick_wins
      | ([ ($pc.missing_from_others // [])[] | {who: (.who // "?"), what: (.what // "?"), tag: (.tag // null)} ]) as $missing_others
      | ([ ($pc.pages // [])[] | {label:(.label // "?"),state:(.state // null)} + (.url | project_link) ]) as $pages
      | ([ $event_rows[] | select(.project == $proj.id)
           | {at:.at, kind:.kind, when:((.at | fr_day) as $day | if (.at // "" | contains("T")) then $day + " " + .at[11:16] else $day end),
              what:((.what // .id) | clean | if safe then (strip_label($proj.name; $pfx) | trunc(110)) else "événement du projet" end),
              sort: ((.at | project_epoch) // (try (.at + "T00:00:00Z" | fromdateiso8601) catch 0))} + (.url | project_link) ]
         | to_entries | sort_by([-.value.sort, .key]) | map(.value | del(.sort)) | .[:5]) as $journal
      | ($cost_map[$proj.id] // null) as $cost
      | ({period: month_label,
          tokens_api: (if $cost != null and ($cost.tokens_api_eur // null) != null then "\($cost.tokens_api_eur | floor) EUR au prix API" elif $cost != null and $cost.tokens_api_usd != null then "\($cost.tokens_api_usd) USD au prix API" else null end),
          subscription_share: (if $cost != null and ($cost.subscription_share_pct // null) != null then "\($cost.subscription_share_pct) % de tes abonnements" else null end),
          source: (if $costs != null and $costs.period != $now[:7] then "mesure de \($costs.period), pas encore de mesure pour \($now[:7])"
                   elif $cost != null then (($cost.sources.measured // ["journaux de sessions, prix API publics"]) + ($cost.sources.missing // []) | join(" · "))
                   else "Claude : journaux non mesurés · Codex : journaux non lus" end)}) as $costs_block
      | def upcoming: .date > $today or (.date == $today and ((.time // "") == "" or (.date + "T" + .time + ":00") >= $calendar_now));
        def meeting_row($source): {title:(.title // "réunion"),date,time:(.time // null),with:(.with // null),bring:(.bring // []),decide:(.decide // []),source:$source};
        ([($pc.meeting // empty) | select(upcoming) | meeting_row("chat")]) as $chat
      | ([if $agenda_fresh then $agenda.meetings[]? | select(.project == $proj.id and .source == "agenda") | select(upcoming) | meeting_row("agenda") else empty end]
         | sort_by([.date,.time]) | .[:1]) as $calendar
      | (if ($chat | length) > 0 and ($calendar | length) > 0 and ($chat[0] | {date,time,title,with}) == ($calendar[0] | {date,time,title,with})
         then [$chat[0] + {source:"agenda et chat"}] else $chat + $calendar end | sort_by([.date,.time])) as $meetings
      | ($meetings[0] // null) as $meeting
      | (if ($meetings | length) > 1 then "l\u2019agenda et le chat ne disent pas la même chose"
         elif ($agenda_fresh | not) then "Agenda non lu : fichier absent ou vieux de plus d\u2019un jour" else null end) as $meeting_warning
      | ([ $deferred_rows[] | select(.project == $proj.id) ] | length) as $deferred_n
      | ([ (if ($is_brain | not) and ($pc.deadline // null) == null then "prochaine échéance non enregistrée" else empty end),
           (if ($is_brain | not) and ($pc.team // null) == null then "équipe non enregistrée" else empty end),
           (if ($pages | length) == 0 then (if $is_brain then "aucune page du cerveau enregistrée" else "aucune page de gestion enregistrée" end) else empty end),
           (if ($is_brain | not) and ($missing_others | length) == 0 then "aucune attente des autres enregistrée" else empty end),
           (if $is_brain and ($recommendations | length) == 0 then "aucune recommandation enregistrée pour le cerveau" else empty end),
           (if $is_brain and ($quick_wins | length) == 0 then "aucun quick win enregistré pour le cerveau" else empty end),
           (if ($is_brain | not) and $meeting == null then (if $agenda_fresh then "aucune prochaine réunion enregistrée" else "aucune réunion enregistrée, agenda non connecté" end) else empty end),
           (if $cost == null then "coûts à mesurer" else empty end),
           (([ $missing_you[] | select(.configured | not) ] | length) as $n
            | if $n > 0 then "\($n) question\(if $n > 1 then "s" else "" end) sans choix fermés : la page propose les choix par défaut" else empty end),
           (if $deferred_n > 0 then "\($deferred_n) décision\(if $deferred_n > 1 then "s" else "" end) mise\(if $deferred_n > 1 then "s" else "" end) de côté, datée\(if $deferred_n > 1 then "s" else "" end) ou ancienne\(if $deferred_n > 1 then "s" else "" end)" else empty end) ]) as $gaps
      | {id: $proj.id, name: $proj.name, brain: $is_brain,
         headline: (($pc.headline // null) | if . == null then null else clean end),
         team:($pc.team // null), deadline:($pc.deadline // null), partial:($warnings | length > 0),
         meetings:$meetings, agenda_available:$agenda_fresh, meeting_warning:$meeting_warning,
         doing: $doing, scouts: $scouts,
         missing_from_you: ($missing_you | map(del(.configured))),
         missing_from_others: $missing_others,
         pages: $pages, creations: $creations,
         unlinked: (if $is_brain then $unassigned else [] end), quick_wins: $quick_wins,
         costs: $costs_block, journal: $journal, meeting: $meeting, gaps: $gaps}
    ] as $composed
  | ($composed | sort_by([-(.missing_from_you | length), .name])) as $sorted
  | {schema: "fm-projets-board.v1",
     home: .home, generated: $now, updated_label: updated_label,
     badges: {workers: ([ $doing_rows[] | select(.state == "working") ] | length),
              decisions: (($decision_rows | length)
                          + (([ $sorted[] | (.missing_from_others | length) + ([ .missing_from_you[] | select(.kind != null) ] | length) ] | add) // 0)),
              subscriptions: $subscriptions},
     projects: $sorted,
     unassigned: (if $brain_id != null then [] else $unassigned end),
     warnings:$warnings,
     table_missing: ($has_table | not)}
  ' || fail "composition failed"
}

# --- validate / render / build ----------------------------------------------
validate_payload() {  # <data.json>
  jq -L "$SCRIPT_DIR" -e --arg schema "$BOARD_SCHEMA" --arg internal_re "$INTERNAL_RE" '
    include "fm-projets-data";
    def nonempty_string: type == "string" and length > 0;
    def captain_string: nonempty_string and (test($internal_re) | not);
    def optional_captain($name): (has($name) | not) or (.[$name] == null) or (.[$name] | captain_string);
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def https_or_null: . == null or project_url;
    def link_item: has("url") and (.url | https_or_null)
      and ((has("url_refused") | not) or (.url == null and (.url_refused | nonempty_string)));
    def doing_item: type == "object" and (.id | nonempty_string) and (.result | captain_string)
      and (.status | captain_string) and (has("next") and (.next == null or (.next | captain_string)))
      and link_item;
    def option_item: type == "object" and (.value | slug(128)) and (.label | captain_string);
    def you_item: type == "object" and (.key | slug(128)) and (.question | captain_string)
      and (.options | type == "array" and length > 0 and all(.[]; option_item))
      and optional_captain("kind")
      and optional_captain("ask")
      # An entry that says its state is unknown must carry the admission the
      # captain reads; a nature the page does not know is refused rather than
      # rendered as a question of unstated nature.
      and ((has("nature") | not) or .nature == "decision"
           or (.nature == "etat" and (.ask | captain_string)))
      and link_item;
    def creation_item: type == "object" and (.label | captain_string) and optional_captain("kind") and link_item;
    def unlinked_item: type == "object" and (.id | nonempty_string) and (.what | captain_string);
    def other_item: type == "object" and (.who | captain_string) and (.what | captain_string)
      and optional_captain("tag");
    def page_item: type == "object" and (.label | captain_string) and link_item
      and optional_captain("state");
    def journal_item: type == "object" and optional_captain("when") and (.what | captain_string)
      and link_item;
    def meeting_item: . == null or (type == "object" and (.title | captain_string)
      and (.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
      and optional_captain("with") and optional_captain("time") and optional_captain("source")
      and (.bring | type == "array" and all(.[]; captain_string))
      and (.decide | type == "array" and all(.[]; captain_string)));
    def costs_item: type == "object" and (.period | captain_string) and optional_captain("tokens_api")
      and optional_captain("subscription_share") and (.source | captain_string);
    def project_item: type == "object" and (.id | slug(64)) and (.name | captain_string)
      and optional_captain("headline") and optional_captain("team") and optional_captain("meeting_warning")
      and ((has("deadline") | not) or .deadline == null or (.deadline | type == "object" and (.label | captain_string) and (.date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))))
      and ((has("agenda_available") | not) or (.agenda_available | type == "boolean"))
      and ((has("partial") | not) or (.partial | type == "boolean"))
      and ((has("brain") | not) or (.brain | type == "boolean"))
      and ((has("scouts") | not) or (.scouts | type == "array" and all(.[]; doing_item)))
      and ((has("creations") | not) or (.creations | type == "array" and all(.[]; creation_item)))
      and ((has("unlinked") | not) or (.unlinked | type == "array" and all(.[]; unlinked_item)))
      and ((has("quick_wins") | not) or (.quick_wins | type == "array" and all(.[]; captain_string)))
      and ((has("meetings") | not) or (.meetings | type == "array" and all(.[]; . != null and meeting_item)))
      and (.doing | type == "array" and all(.[]; doing_item))
      and (.missing_from_you | type == "array" and all(.[]; you_item)
           and (map(.key) | unique | length) == length)
      and (.missing_from_others | type == "array" and all(.[]; other_item))
      and (.pages | type == "array" and all(.[]; page_item))
      and (.costs | costs_item)
      and (.journal | type == "array" and length <= 5 and all(.[]; journal_item))
      and (has("meeting") and (.meeting | meeting_item))
      and (.gaps | type == "array" and all(.[]; captain_string));
    def count: type == "number" and . >= 0 and floor == .;
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.updated_label | captain_string)
    and (.badges | type == "object" and (.workers | count) and (.decisions | count)
         and (has("subscriptions") and (.subscriptions == null or (.subscriptions | captain_string))))
    and (.projects | type == "array" and all(.[]; project_item))
    and ([.projects[].id] | unique | length) == (.projects | length)
    and ([.projects[] | select(.brain == true)] | length) <= 1
    and (.unassigned | type == "array" and all(.[]; type == "object" and (.id | nonempty_string) and (.what | captain_string)))
    and ((has("warnings") | not) or (.warnings | type == "array" and all(.[]; captain_string)))
    and (.table_missing | type == "boolean")
  ' "$1" >/dev/null
}

explain_refusal() {  # <data.json> - best-effort pointer at the first offending string
  jq -r --arg internal_re "$INTERNAL_RE" '
    [ paths(type == "string") as $p | {path: ($p | map(tostring) | join(".")), v: getpath($p)}
      | select(.v | test($internal_re)) ] | .[0]
    | if . == null then empty else "internal vocabulary at \(.path): \(.v)" end
  ' "$1" 2>/dev/null || true
}

render_page() {  # <data.json> -> prints board: <path>
  local data=$1 board json tmp extracted why
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "page data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "page data is not valid JSON: $data"
  if ! validate_payload "$data"; then
    why=$(explain_refusal "$data")
    fail "page data does not satisfy $BOARD_SCHEMA: $data${why:+ ($why)}"
  fi
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "page template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "page template does not carry exactly one data slot: $TEMPLATE"

  json=$(jq -c . "$data") || fail "cannot compact the page data"
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.projets.XXXXXX") || fail "cannot stage the page"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the page data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the page data slot survived injection"
  fi
  extracted=$(sed -n '/<script id="projets-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built page does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the page"
  fi
  printf 'board: %s\n' "$board"
  # The front door (bin/fm-projets-serve.sh) serves this file at a stable
  # tailnet address; say it whenever its table exists so the captain never
  # has to look for a session id.
  if [ -f "$CONFIG/projets-serve.json" ]; then
    printf 'stable: %s\n' "$("$SCRIPT_DIR/fm-projets-serve.sh" url | awk '/^page:/ { print $2 }')"
  fi
}

command_render() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  render_page "$1"
}

command_build() {
  local board sid
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  render_page "$1"
  board=$(board_path)

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  lavish-axi "$board" || fail "cannot establish the page Lavish session"
  printf 'served: %s\n' "$board"

  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the page source id"
  if "$SCRIPT_DIR/fm-procevent.sh" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid"; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the page as a process-event source"
    printf 'armed: %s\n' "$sid"
  fi
}

command_init() {
  local force=0 target="$CONFIG/projets.json" tmp
  case "${1:-}" in --force) force=1; shift ;; -h|--help) usage; return ;; esac
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if [ -e "$target" ] && [ "$force" = 0 ]; then
    printf 'preserved: %s\n' "$target"
    return
  fi
  (umask 077; mkdir -p "$CONFIG") || fail "cannot create project configuration"
  tmp=$(umask 077; mktemp "$CONFIG/.projets.XXXXXX") || fail "cannot stage project table"
  if ! cat "$SCRIPT_DIR/../.agents/skills/projets/assets/projets.seed.json" > "$tmp"; then
    rm -f "$tmp"
    fail "cannot read project seed"
  fi
  if [ "$force" = 1 ]; then mv -f "$tmp" "$target"
  else ln "$tmp" "$target" 2>/dev/null || { rm -f "$tmp"; fail "project table already exists"; }; rm -f "$tmp"; fi
  printf 'initialized: %s\n' "$target"
}

case "${1-}" in
  init) shift; command_init "$@" ;;
  compose) shift; command_compose "$@" ;;
  render) shift; command_render "$@" ;;
  build) shift; command_build "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
