#!/usr/bin/env bash
# Behavior tests for bin/fm-projets-board.sh: grouping fleet rows by project
# from the correspondence table, rail ordering by decisions waiting on the
# captain, fail-closed payload validation (types, HTTPS links, the captain
# vocabulary filter), the render slot round-trip, and the serve-then-arm build
# sequence that deliberately never binds the page to the keyed-answer intake.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-projets-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-projets-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_hold() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

# A bearings projection with work spread over three projects: two repos, one
# id prefix that overrides its repo, a decision without a repo, and a row that
# matches nothing. Internal wording in details must never reach the page.
write_snapshot() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings.v1",
  "home": "test/home",
  "generated": "2026-09-11T00:30:00Z",
  "prs": "not_requested",
  "in_flight": [
    {"id": "torre-interfaces", "kind": "ship", "state": "done", "repo": "agent-platform",
     "title": "Torre : interfaces v0 pour la direction", "doing": "run passed: PR merged/closed"},
    {"id": "torre-audit", "kind": "scout", "state": "working", "repo": "agent-platform",
     "title": "Torre : audit Shopify contre Stripe", "doing": "harness busy (claude-hook)"},
    {"id": "torre-site", "kind": "ship", "state": "paused", "repo": "agent-platform",
     "title": "Torre : site click and collect", "doing": "en attente du numero Meta de Bechir"},
    {"id": "torre-hermes", "kind": "ship", "state": "working", "repo": "agent-platform",
     "title": null, "doing": "harness busy (claude-hook)"},
    {"id": "chef-parcours", "kind": "scout", "state": "blocked", "repo": "agent-platform",
     "title": "Chef: parcours client", "doing": "worktree missing, brief unreadable"},
    {"id": "core-sync", "kind": "ship", "state": "working", "repo": "x-deep-core",
     "title": "Sync du cerveau", "doing": "harness busy"}
  ],
  "secondmates": [],
  "secondmate_reconcile": [],
  "decisions_open": [
    {"id": "torre-hebergement", "key": "torre-hebergement", "verb": "captain-hold",
     "summary": "Torre: hebergement: choisir", "title": "Torre : trancher l hebergement", "owner": "(main)", "repo": "agent-platform"},
    {"id": "chef-domaine", "key": "chef-domaine", "verb": "captain-hold",
     "summary": "Chef: basculer le domaine", "title": "Chef: basculer le domaine", "owner": "(main)", "repo": "agent-platform"},
    {"id": "chef-rose", "key": "chef-rose", "verb": "captain-hold",
     "summary": "Chef: le rose", "title": "Chef: le rose des Anglades", "owner": "(main)", "repo": null},
    {"id": "sacem-relance", "key": "sacem-relance", "verb": "captain-hold",
     "summary": "SACEM: relancer Sabine", "title": "SACEM: relancer Sabine", "owner": "(main)", "repo": null},
    {"id": "core-source-de-verite", "key": "core-source-de-verite", "verb": "captain-hold",
     "summary": "Cerveau: source de verite", "title": "Cerveau : trancher la source de verite", "owner": "(main)", "repo": "x-deep-core"}
  ],
  "landed": [
    {"id": "torre-cerveau-v0", "what": "Torre : cerveau achats v0", "artifact": "https://github.com/acme/agent-platform/pull/56", "owner": "(main)", "repo": "agent-platform", "date": "2026-09-09"},
    {"id": "torre-cerveau-v1", "what": "Torre : cerveau achats v1", "artifact": "https://github.com/acme/agent-platform/pull/61", "owner": "(main)", "repo": "agent-platform", "date": "2026-09-10"},
    {"id": "torre-archi", "what": "Torre : page architecture", "artifact": "https://github.com/acme/x-deep/pull/229", "owner": "(main)", "repo": "x-deep-core", "date": "2026-09-10"},
    {"id": "torre-hermes-v0", "what": "Torre : agent interne Hermes v0", "artifact": "https://github.com/acme/agent-platform/pull/59", "owner": "(main)", "repo": "agent-platform", "date": "2026-09-10"},
    {"id": "torre-whatsapp-v0", "what": "Torre : agent client WhatsApp v0", "artifact": "https://github.com/acme/agent-platform/pull/60", "owner": "(main)", "repo": "agent-platform", "date": "2026-09-10"},
    {"id": "torre-old", "what": "Torre : vieille livraison", "artifact": "-", "owner": "(main)", "repo": "agent-platform", "date": "2026-08-01"},
    {"id": "chef-julia", "what": "Chef: Julia moins scolaire", "artifact": "https://github.com/acme/agent-platform/pull/40", "owner": "(main)", "repo": "agent-platform", "date": "2026-09-08"}
  ],
  "gates": [
    {"id": "torre-machine", "title": "Torre: machine fixe", "blocked_by": "-", "reason": "held 17d: Achat", "owner": "(main)"},
    {"id": "chef-editorial", "title": "Chef: editorial", "blocked_by": "chef-catalogue", "reason": "blocked-by chef-catalogue", "owner": "(main)"}
  ],
  "reports": [],
  "recorded_prs": [
    {"id": "torre-interfaces", "url": "https://github.com/acme/agent-platform/pull/58"}
  ],
  "omitted": []
}
EOF
}

write_table() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-projets-config.v1",
  "projects": [
    {"id": "torre", "name": "Torre", "prefixes": ["torre-"],
     "headline": "Pilote le 14/09 avec Eli",
     "missing_from_others": [{"who": "Eli", "what": "les factures fournisseur", "tag": "avant le 11/09"}],
     "pages": [{"label": "Espace client", "url": "https://example.test/client", "state": "à jour 10/09"}],
     "meeting": {"title": "Pilote sur place", "date": "2026-09-14", "with": "Eli", "bring": ["la démo"], "decide": ["l enveloppe"]},
     "decisions": {"torre-hebergement": {"question": "Hébergement : chez toi ou chez Torre ?",
       "options": [{"value": "chez-toi", "label": "chez toi"}, {"value": "chez-torre", "label": "chez Torre"}]}}},
    {"id": "club", "name": "Club Julien Dumas", "prefixes": ["chef-"], "repos": ["agent-platform"]},
    {"id": "ydeep", "name": "YDEEP", "prefixes": ["cerveau-"], "repos": ["x-deep-core"]},
    {"id": "solos", "name": "Solos", "prefixes": ["solos-"], "repos": ["Solos"]}
  ]
}
EOF
}

write_quota() {  # <path>
  cat > "$1" <<'EOF'
{"schemaVersion": 1, "generatedAt": "2026-09-11T00:00:00Z", "providers": [
  {"provider": "claude", "plan": "max", "quotaSemantics": {"effectiveAvailability": [
    {"scope": "all_models", "effectivePercentRemaining": 59},
    {"scope": "model:fable", "effectivePercentRemaining": 22}]}},
  {"provider": "codex", "plan": "pro", "quotaSemantics": {"effectiveAvailability": [
    {"scope": "all_models", "effectivePercentRemaining": 34}]}},
  {"provider": "cursor", "plan": null, "quotaSemantics": {"effectiveAvailability": []}}
]}
EOF
}

compose() {  # <home> [extra args...]; quota-axi stays out unless the caller passes --quota
  local home=$1 quota=--no-quota
  shift
  [ "${1:-}" = --quota ] && quota=""
  write_snapshot "$home/snapshot.json"
  run_board "$home" compose --snapshot "$home/snapshot.json" --now 2026-09-11T00:30:00Z ${quota:+"$quota"} "$@"
}

extract_payload() {  # <page-path>
  sed -n '/<script id="projets-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/projets.html" ] \
    || fail "the page path is not the stable home-scoped location"
  pass "path prints the stable home-scoped page location"
}

test_compose_groups_rows_by_project_prefix_then_repo() {
  local home out
  home=$(make_home group)
  write_table "$home/config/projets.json"
  out=$(compose "$home") || fail "compose failed with a table present"
  printf '%s' "$out" | jq -e '
    .schema == "fm-projets-board.v1" and .table_missing == false
    and ([.projects[] | select(.id == "torre") | .doing[].id] == ["torre-interfaces", "torre-audit", "torre-site", "torre-hermes"])
    and ([.projects[] | select(.id == "club") | .doing[].id] == ["chef-parcours"])
    and ([.projects[] | select(.id == "ydeep") | .doing[].id] == ["core-sync"])
    and ([.projects[] | select(.id == "torre") | .missing_from_you[].key] == ["torre-hebergement"])
    and ([.projects[] | select(.id == "club") | .missing_from_you[].key] == ["chef-domaine", "chef-rose"])
    and ([.projects[] | select(.id == "ydeep") | .missing_from_you[].key] == ["core-source-de-verite"])
    and ([.projects[] | select(.id == "solos") | (.doing + .missing_from_you + .journal) | length] == [0])
    and ([.unassigned[].id] == ["sacem-relance"])
  ' >/dev/null || fail "rows were not grouped by id prefix first, then repo: $out"
  pass "compose groups every row by id prefix first, then by repo, and keeps the rest as unassigned"
}

test_compose_orders_the_rail_by_decisions_waiting_on_the_captain() {
  local home out
  home=$(make_home rail)
  write_table "$home/config/projets.json"
  out=$(compose "$home") || fail "compose failed"
  [ "$(printf '%s' "$out" | jq -r '[.projects[].id] | join(",")')" = "club,torre,ydeep,solos" ] \
    || fail "the rail is not ordered by decisions waiting on the captain, then name: $out"
  printf '%s' "$out" | jq -e '
    .badges.workers == 3 and .badges.decisions == 6 and .badges.subscriptions == null
  ' >/dev/null || fail "the badges do not count live workers and every decision: $out"
  pass "compose orders the rail by decisions waiting on the captain and counts the badges"
}

test_compose_translates_states_and_keeps_internal_wording_off_the_page() {
  local home out
  home=$(make_home wording)
  write_table "$home/config/projets.json"
  out=$(compose "$home") || fail "compose failed"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.id == "torre") | .doing) as $d
    | ($d[] | select(.id == "torre-interfaces") | .result == "interfaces v0 pour la direction" and .status == "livré"
        and .next == "fusion à confirmer" and .url == "https://github.com/acme/agent-platform/pull/58")
    and ($d[] | select(.id == "torre-audit") | .status == "en cours" and .next == null and .url == null)
    and ($d[] | select(.id == "torre-site") | .status == "en pause, attente extérieure · en attente du numero Meta de Bechir")
    and ($d[] | select(.id == "torre-hermes") | .result == "hermes")
    and (.projects[] | select(.id == "club") | .doing[0] | .status == "bloqué" and .next == "firstmate doit débloquer")
    and (.projects[] | select(.id == "torre") | .missing_from_you[0]
         | .question == "Hébergement : chez toi ou chez Torre ?" and [.options[].value] == ["chez-toi", "chez-torre"])
    and (.projects[] | select(.id == "club") | .missing_from_you[0]
         | .question == "basculer le domaine" and [.options[].value] == ["fait", "on-en-parle", "plus-tard"])
  ' >/dev/null || fail "task states were not translated into captain wording: $out"
  printf '%s' "$out" | jq -r '.. | strings' | grep -Eiq '\b(harness|worktree|brief|hook)\b' \
    && fail "internal wording leaked into the composed page: $out"
  pass "compose translates states into captain wording and drops internal details"
}

test_compose_fills_the_seven_blocks_from_table_and_fleet() {
  local home out
  home=$(make_home blocks)
  write_table "$home/config/projets.json"
  write_quota "$home/quota.json"
  out=$(compose "$home" --quota "$home/quota.json") || fail "compose failed"
  printf '%s' "$out" | jq -e '
    .updated_label == "11/09 00h30"
    and .badges.subscriptions == "Claude 41 % · Codex 66 %"
    and (.projects[] | select(.id == "torre")
      | .headline == "Pilote le 14/09 avec Eli"
      and .missing_from_others == [{"who": "Eli", "what": "les factures fournisseur", "tag": "avant le 11/09"}]
      and .pages == [{"label": "Espace client", "url": "https://example.test/client", "state": "à jour 10/09"}]
      and .costs.period == "septembre" and .costs.tokens_api == null and .costs.subscription_share == null
      and (.journal | length) == 5
      and (.journal | map(.what)) == ["cerveau achats v1", "page architecture", "agent interne Hermes v0", "agent client WhatsApp v0", "cerveau achats v0"]
      and .journal[0].when == "10/09" and .journal[0].url == "https://github.com/acme/agent-platform/pull/61"
      and .meeting.date == "2026-09-14" and .meeting.with == "Eli"
      and (.gaps | index("coûts à mesurer") != null)
      and (.gaps | index("1 décision mise de côté, datée ou ancienne") != null)
      and ([.gaps[] | select(test("page de gestion"))] | length) == 0)
    and (.projects[] | select(.id == "club")
      | .meeting == null and .pages == [] and .missing_from_others == []
      and (.gaps | index("aucune réunion enregistrée, agenda non connecté") != null)
      and (.gaps | index("2 décisions sans choix fermés, boutons génériques") != null))
  ' >/dev/null || fail "the seven blocks were not filled from the table and the fleet: $out"
  pass "compose fills the seven blocks from the table and the fleet and names each gap"
}

test_compose_without_a_table_uses_repos_and_says_so() {
  local home out
  home=$(make_home notable)
  out=$(compose "$home") || fail "compose failed without a table"
  printf '%s' "$out" | jq -e '
    .table_missing == true
    and ([.projects[].id] == ["agent-platform", "x-deep-core"])
    and (.projects[] | select(.id == "agent-platform") | (.missing_from_you | length) == 2)
    and ([.unassigned[].id] == ["chef-rose", "sacem-relance"])
  ' >/dev/null || fail "a missing table did not fall back to one project per repo: $out"
  pass "compose without a table groups by repo and marks the table missing"
}

test_compose_refuses_a_malformed_table_and_measured_costs_replace_a_mesurer() {
  local home out rc
  home=$(make_home costs)
  printf '{"schema":"fm-projets-config.v1","projects":[{"id":"Bad Id","name":"x"}]}\n' > "$home/config/projets.json"
  set +e; out=$(compose "$home" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a malformed project table was accepted"
  assert_contains "$out" "fm-projets-config.v1" "the table refusal did not name the contract: $out"

  write_table "$home/config/projets.json"
  cat > "$home/data/projets-couts.json" <<'EOF'
{"schema": "fm-projets-couts.v1", "period": "2026-09",
 "projects": {"torre": {"tokens_api_eur": 123.9, "subscription_share_pct": 14.5}}}
EOF
  out=$(compose "$home") || fail "compose failed with a costs file"
  printf '%s' "$out" | jq -e '
    (.projects[] | select(.id == "torre") | .costs.tokens_api == "123 EUR au prix API"
      and .costs.subscription_share == "14.5 % de tes abonnements" and ((.gaps | index("coûts à mesurer")) == null))
    and (.projects[] | select(.id == "club") | .costs.tokens_api == null and (.gaps | index("coûts à mesurer") != null))
  ' >/dev/null || fail "measured costs did not replace the unmeasured marker: $out"
  pass "compose refuses a malformed table and shows measured costs only where they exist"
}

test_render_refuses_malformed_payloads_before_touching_the_page() {
  local home data board rc out
  home=$(make_home refusal)
  write_table "$home/config/projets.json"
  board="$home/.lavish/projets.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" render "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-projets-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" render "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-projets-board.v1" "the schema refusal did not name the contract: $out"

  compose "$home" > "$data" || fail "compose failed"
  run_board "$home" render "$data" >/dev/null || fail "a composed payload did not render"
  rm -f -- "$board"

  jq '.projects[0].doing[0].status = "worker bloqué : worktree perdu"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" render "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "internal vocabulary in a captain-facing string was accepted"
  assert_contains "$out" "internal vocabulary at projects.0.doing.0.status" "the vocabulary refusal did not point at the string: $out"

  compose "$home" > "$data"
  jq '.projects[0].missing_from_you[0].options = []' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" render "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a decision without any closed choice was accepted"

  compose "$home" > "$data"
  jq '.projects[0].journal = [range(6) | {"when": null, "what": "événement \(.)", "url": null}]' "$data" \
    > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" render "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a journal longer than five events was accepted"

  compose "$home" > "$data"
  jq '.projects[0].pages[0].url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" render "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS page link was accepted"

  compose "$home" > "$data"
  jq '.projects[0].meeting = {"title": "x", "date": "demain", "with": null, "bring": [], "decide": []}' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" render "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a meeting without an ISO date was accepted"

  compose "$home" > "$data"
  jq '.badges.workers = -1' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" render "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a negative badge count was accepted"

  compose "$home" > "$data"
  jq '.projects[1].id = .projects[0].id' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" render "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "two projects sharing one id were accepted"

  assert_absent "$board" "a refused payload still produced a page"
  pass "render refuses malformed payloads before touching the page"
}

test_render_round_trips_the_payload_and_neutralises_script_closers() {
  local home data board
  home=$(make_home roundtrip)
  write_table "$home/config/projets.json"
  data="$home/payload.json"
  board="$home/.lavish/projets.html"
  compose "$home" > "$data" || fail "compose failed"
  jq '.projects[0].headline = "un titre qui tente </script><b>x</b> de sortir"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" render "$data" >/dev/null || fail "render failed"
  extract_payload "$board" | jq -S . > "$home/extracted.json" || fail "the built page does not carry parseable payload JSON"
  jq -S . "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/extracted.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_PROJETS_BOARD_DATA__' "$board" && fail "the data slot survived injection"
  pass "render injects the payload verbatim and neutralises script closers"
}

test_build_serves_then_arms_and_never_binds() {
  local home data board out sid records
  home=$(make_home build)
  write_table "$home/config/projets.json"
  data="$home/payload.json"
  board="$home/.lavish/projets.html"
  compose "$home" > "$data" || fail "compose failed"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the page path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "armed: " "the first build did not arm the page source: $out"
  assert_not_contains "$out" "bound: " "build bound the page to the keyed-answer intake: $out"

  sid=$(run_lavish_source_id "$home" "$board")
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the page source is not registered after build"
  ! run_hold "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "the page source carries a keyed-answer binding, so a click could close a task"

  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "build serves, then arms once, and never binds the page to the keyed-answer intake"
}

test_build_does_not_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  write_table "$home/config/projets.json"
  data="$home/payload.json"
  compose "$home" > "$data" || fail "compose failed"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"
  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/projets.html")
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the page before its Lavish session existed"
  pass "build establishes the Lavish session before arming"
}

test_render_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  write_table "$home/config/projets.json"
  data="$home/payload.json"
  compose "$home" > "$data" || fail "compose failed"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_PROJETS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" render "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template without a data slot was accepted"
  assert_contains "$out" "exactly one data slot" "the slot refusal did not say why: $out"
  pass "render refuses a template without exactly one data slot"
}

test_review_inputs_survive_composition_and_render() {
  local home out initial
  home=$(make_home review)
  run_board "$home" init >/dev/null || fail "init failed"
  initial=$(cat "$home/config/projets.json")
  jq -e '[.projects[].name] == ["Torre","Solos","Club Julien Dumas","CRIA","YDEEP","Firstmate"]' "$home/config/projets.json" >/dev/null || fail "seed missing projects"
  printf 'preserve me\n' > "$home/config/projets.json"
  run_board "$home" init >/dev/null || fail "init did not preserve table"
  [ "$(cat "$home/config/projets.json")" = "preserve me" ] || fail "init overwrote table"
  run_board "$home" init --force >/dev/null || fail "forced init failed"
  [ "$(cat "$home/config/projets.json")" = "$initial" ] || fail "forced init did not restore seed"
  jq '.projects[0] += {team:"Eli et Yan",deadline:{label:"Pilote",date:"2026-09-14"},meeting:{title:"Pilote",date:"2026-09-14",with:"Eli"},pages:[{label:"Revue",url:"http://machine.ts.net:4387/session/1"},{label:"Refus",url:"http://public.example/page"}]}' "$home/config/projets.json" > "$home/table.json"
  cat > "$home/snapshot.json" <<'EOF'
{"schema":"fm-bearings.v1","home":"test","in_flight":[{"id":"mate/torre-backend","state":"working","title":"Torre : backend"}],"decisions_open":[{"id":"mate/torre-backend","title":"backend","url":"http://public.example/decision"},{"id":"sans-projet","title":"Choisir"}],"landed":[],"events":[{"id":"torre-un","kind":"pr","what":"PR ouverte","at":"2026-09-11T10:00:00Z","url":"http://public.example/pr"},{"id":"torre-deux","kind":"decision","what":"Choix reçu","at":"2026-09-11T12:00:00Z"},{"id":"torre-trois","kind":"landed","what":"Livraison une","at":"2026-09-10"},{"id":"torre-quatre","kind":"landed","what":"Livraison deux","at":"2026-09-10"}],"recorded_prs":[{"id":"mate/torre-backend","url":"http://public.example/work"}],"omitted":[{"surface":"secondmate unreadable"}],"secondmates":[{"id":"mate","state":"unknown"}]}
EOF
  cat > "$home/data/projets-agenda.json" <<'EOF'
{"schema":"fm-projets-agenda.v1","read_at":"2026-09-11T08:00:00+02:00","meetings":[{"project":"torre","title":"Pilote","date":"2026-09-15","time":"10:00","with":"Eli","source":"agenda"}]}
EOF
  printf '%s\n' '{"schema":"fm-projets-couts.v1","period":"2026-08","projects":{"torre":{"tokens_api_eur":999}}}' > "$home/data/projets-couts.json"
  out=$(run_board "$home" compose --snapshot "$home/snapshot.json" --config "$home/table.json" --no-quota --now 2026-09-11T12:00:00Z) || fail "review composition failed"
  printf '%s' "$out" > "$home/payload.json"
  jq -e '
    (.projects | length) == 6 and .badges.decisions == 2 and (.warnings | length) > 0
    and (all(.projects[]; .partial))
    and (.projects[] | select(.id == "torre") |
      .team == "Eli et Yan" and .deadline.label == "Pilote"
      and .doing[0].owner == "mate" and .doing[0].local_id == "torre-backend"
      and .doing[0].result == "mate/torre-backend" and .doing[0].url == null and .doing[0].url_refused == "http://public.example/work"
      and .missing_from_you[0].key == "mate__torre-backend" and .missing_from_you[0].url_refused == "http://public.example/decision"
      and .pages[0].url == "http://machine.ts.net:4387/session/1" and .pages[1].url == null and .pages[1].url_refused == "http://public.example/page"
      and .costs.tokens_api == null and (.costs.source | contains("mesure de 2026-08, pas encore de mesure pour 2026-09"))
      and (.meetings | map(.source)) == ["chat","agenda"] and (.meeting_warning | contains("ne disent pas"))
      and (.journal | map(.what)) == ["Choix reçu","PR ouverte","Livraison une","Livraison deux"]
      and .journal[0].when == "11/09 12:00" and .journal[2].when == "10/09")
  ' "$home/payload.json" >/dev/null || fail "review inputs not preserved: $out"
  run_board "$home" render "$home/payload.json" >/dev/null || fail "composed review payload rejected"
  if command -v node >/dev/null 2>&1; then
    node "$ROOT/tests/assets/projets-render-harness.mjs" "$home/.lavish/projets.html" > "$home/rendered.json"
    jq -e '.error == "" and (.notice | contains("partiel"))
      and (.cards[] | select(.id == "torre") | .deadline == "Prochaine échéance : Pilote, 14/09" and .team == "Eli et Yan"
        and (.blocs[3].text | contains("lien refusé")) and (.blocs[6].text | contains("La prochaine reunion est lue depuis ton agenda")))
      and (.cards[] | select(.id == "solos") | (.blocs[0].empty | contains("État partiel")) and (.blocs[1].empty | contains("État partiel")))' "$home/rendered.json" >/dev/null || fail "review rendering lost details"
  fi
  out=$(run_board "$home" compose --snapshot "$home/snapshot.json" --config "$home/table.json" --no-quota --now 2026-09-13T12:00:00Z) || fail "stale calendar composition failed"
  printf '%s' "$out" | jq -e '.projects[] | select(.id == "torre") | (.meetings | length) == 1 and (.meeting_warning | contains("vieux de plus"))' >/dev/null || fail "stale calendar remained visible"
  pass "seed, owned decisions, current periods, calendar divergence, event order and partial state survive render"
}

test_allowed_management_networks_and_refusals() {
  local home url out
  home=$(make_home links)
  write_snapshot "$home/snapshot.json"
  for url in https://public.example/a http://localhost:4387/a http://127.1.2.3/a 'http://[::1]/a' http://10.0.0.1/a http://172.16.0.1/a http://172.31.255.255/a http://192.168.1.1/a http://a.ts.net/a; do
    jq -n --arg url "$url" '{schema:"fm-projets-config.v1",projects:[{id:"torre",name:"Torre",prefixes:["torre-"],pages:[{label:"Revue",url:$url}]}]}' > "$home/config/projets.json"
    out=$(run_board "$home" compose --snapshot "$home/snapshot.json" --no-quota) || fail "URL composition failed"
    printf '%s' "$out" > "$home/payload.json"
    jq -e --arg url "$url" '.projects[0].pages[0].url == $url' "$home/payload.json" >/dev/null || fail "allowed URL rejected: $url"
    run_board "$home" render "$home/payload.json" >/dev/null || fail "allowed URL failed validation: $url"
  done
  for url in http://010.0.0.1/a http://0172.16.0.1/a http://public.example/a http://172.32.0.1/a http://192.169.1.1/a http://127.999.0.1/a http://a.ts.net.evil/a 'javascript:alert(1)' 'http://localhost@evil.test/a' 'http://localhost\@evil.test/a'; do
    jq -n --arg url "$url" '{schema:"fm-projets-config.v1",projects:[{id:"torre",name:"Torre",prefixes:["torre-"],pages:[{label:"Revue",url:$url}]}]}' > "$home/config/projets.json"
    out=$(run_board "$home" compose --snapshot "$home/snapshot.json" --no-quota) || fail "refused URL composition failed"
    printf '%s' "$out" > "$home/payload.json"
    jq -e --arg url "$url" '.projects[0].pages[0] | .url == null and .url_refused == $url' "$home/payload.json" >/dev/null || fail "unsafe URL not disclosed: $url"
    run_board "$home" render "$home/payload.json" >/dev/null || fail "refusal failed validation"
  done
  pass "allowed private networks navigate and rejected links stay explicit"
}

test_meetings_use_calendar_time() {
  local home out
  home=$(make_home calendar-time)
  write_snapshot "$home/snapshot.json"
  run_board "$home" init >/dev/null
  jq '.timezone="Europe/Paris" | .projects[0].meeting={title:"Matin",date:"2026-09-11",time:"09:00"}' "$home/config/projets.json" > "$home/config/new.json"
  mv "$home/config/new.json" "$home/config/projets.json"
  cat > "$home/data/projets-agenda.json" <<'EOF'
{"schema":"fm-projets-agenda.v1","read_at":"2026-09-11T11:00:00Z","meetings":[{"project":"torre","title":"Matin","date":"2026-09-11","time":"09:00","source":"agenda"},{"project":"torre","title":"Apres-midi","date":"2026-09-11","time":"16:00","source":"agenda"}]}
EOF
  out=$(run_board "$home" compose --snapshot "$home/snapshot.json" --no-quota --now 2026-09-11T12:00:00Z) || fail "calendar compose failed"
  printf '%s' "$out" | jq -e '.projects[] | select(.id=="torre") | .agenda_available and [.meetings[].time]==["16:00"] and .meeting.source=="agenda"' >/dev/null || fail "past chat or agenda meeting retained"
  out=$(FM_PROJETS_TIMEZONE=America/New_York run_board "$home" compose --snapshot "$home/snapshot.json" --no-quota --now 2026-09-11T12:00:00Z) || fail "timezone override failed"
  printf '%s' "$out" | jq -e '.projects[] | select(.id=="torre") | .meeting.time=="09:00" and .meeting.source=="agenda et chat"' >/dev/null || fail "calendar timezone ignored"
  pass "calendar and chat meetings exclude elapsed times in the configured timezone"
}
test_meetings_use_calendar_time

test_path_is_stable_and_home_scoped
test_compose_groups_rows_by_project_prefix_then_repo
test_compose_orders_the_rail_by_decisions_waiting_on_the_captain
test_compose_translates_states_and_keeps_internal_wording_off_the_page
test_compose_fills_the_seven_blocks_from_table_and_fleet
test_compose_without_a_table_uses_repos_and_says_so
test_compose_refuses_a_malformed_table_and_measured_costs_replace_a_mesurer
test_render_refuses_malformed_payloads_before_touching_the_page
test_render_round_trips_the_payload_and_neutralises_script_closers
test_build_serves_then_arms_and_never_binds
test_build_does_not_arm_when_session_start_fails
test_render_refuses_a_template_without_exactly_one_slot

test_review_inputs_survive_composition_and_render
test_allowed_management_networks_and_refusals
