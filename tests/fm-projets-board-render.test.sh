#!/usr/bin/env bash
# Behavior tests for the shipped projets page renderer
# (.agents/skills/projets/assets/page-template.html), exercised through a real
# `fm-projets-board.sh render` and then executed under the minimal DOM shim in
# tests/assets/projets-render-harness.mjs. The assertions are on what the page
# renders - the three badges, the rail order, the seven blocks and their empty
# states, the three-line cap, the unassigned card, the brain card, the phone
# layout (stacked cells, folded blocks that keep no box), and what a choice
# button queues for firstmate - never on the template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-projets-board.sh"
HARNESS="$ROOT/tests/assets/projets-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-projets-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# An empty project: every block must still render with its empty state.
empty_project() {  # <id> <name>
  jq -n --arg id "$1" --arg name "$2" '{
    id: $id, name: $name, headline: null, doing: [], missing_from_you: [], missing_from_others: [],
    pages: [], costs: {period: "septembre", tokens_api: null, subscription_share: null, source: "à brancher"},
    journal: [], meeting: null, gaps: []}'
}

# Render <projects-json> (an array) with the given badges and print what the
# renderer produced. Extra harness options follow.
render() {  # <home> <projects-json> <badges-json> <unassigned-json> [harness opts...]
  local home=$1 projects=$2 badges=$3 unassigned=$4 data="$1/payload.json"
  shift 4
  jq -n --argjson projects "$projects" --argjson badges "$badges" --argjson unassigned "$unassigned" '{
    schema: "fm-projets-board.v1", home: "render/home", generated: "2026-09-11T00:30:00Z",
    updated_label: "11/09 00h30", badges: $badges, projects: $projects, unassigned: $unassigned,
    table_missing: false}' > "$data"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$BOARD" render "$data" >/dev/null || fail "the page did not render"
  node "$HARNESS" "$home/.lavish/projets.html" "$@" || fail "the built page could not be rendered"
}

test_an_empty_project_renders_all_seven_blocks_with_empty_states() {
  local home out
  home=$(make_home empty)
  out=$(render "$home" "[$(empty_project solos Solos)]" '{"workers":0,"decisions":0,"subscriptions":null}' '[]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the page rendered its refusal instead of the project: $out"
  printf '%s' "$out" | jq -e '
    (.cards | length) == 1 and (.cards[0].blocs | map(.num)) == [1, 2, 3, 4, 5, 6, 7]
    and (.cards[0].blocs | map(.open) | all)
    and (.cards[0].blocs[0].empty | test("Rien en cours"))
    and (.cards[0].blocs[1].empty | test("Rien ne manque de toi"))
    and (.cards[0].blocs[2].empty | test("Aucune attente des autres"))
    and (.cards[0].blocs[3].empty | test("Aucune page de gestion"))
    and (.cards[0].blocs[4].cells == ["à mesurer", "à mesurer"])
    and (.cards[0].blocs[5].empty | test("Aucun événement"))
    and (.cards[0].blocs[6].empty | test("Agenda non lu"))
    and (.badges | map(.value)) == ["0", "0", "à mesurer"]
    and (.badges[2].soft == true)
    and (.rail == [{"id": "solos", "name": "Solos", "count": 0, "on": true}])
  ' >/dev/null || fail "an empty project did not render every block with its empty state: $out"
  pass "an empty project renders all seven blocks with their empty states and unmeasured badges"
}

test_the_rail_keeps_payload_order_and_shows_one_project_at_a_time() {
  local home out projects
  home=$(make_home rail)
  projects=$(jq -n --argjson a "$(empty_project ydeep YDEEP)" --argjson b "$(empty_project torre Torre)" '
    [ ($a | .missing_from_you = [
        {key: "ydeep-un", question: "Un ?", options: [{value: "oui", label: "oui"}], url: null},
        {key: "ydeep-deux", question: "Deux ?", options: [{value: "oui", label: "oui"}], url: null}]),
      ($b | .missing_from_you = [{key: "torre-un", question: "Un ?", options: [{value: "oui", label: "oui"}], url: null}]) ]')
  out=$(render "$home" "$projects" '{"workers":2,"decisions":3,"subscriptions":"Claude 41 %"}' '[]')
  printf '%s' "$out" | jq -e '
    (.rail | map(.id)) == ["ydeep", "torre"] and (.rail | map(.count)) == [2, 1]
    and .rail[0].on == true and .rail[1].on == false
    and (.cards | map(.hidden)) == [false, true]
    and (.badges | map(.value)) == ["2", "3", "Claude 41 %"]
    and (.badges | map(.kind)) == ["workers", "decisions", "subscriptions"]
    and (.badges[1].label | test("décisions à prendre"))
    and (.meta | test("11/09 00h30"))
  ' >/dev/null || fail "the rail did not keep the payload order with one visible card: $out"
  pass "the rail keeps the payload order, counts what is missing from the captain, and shows one project at a time"
}

test_doing_shows_three_rows_and_folds_the_rest_behind_voir_tout() {
  local home out projects
  home=$(make_home doing)
  projects=$(jq -n --argjson p "$(empty_project torre Torre)" '
    [ ($p | .doing = [range(5) | {id: "torre-\(.)", result: "résultat \(.)", status: "en cours", next: null, url: null}]) ]')
  out=$(render "$home" "$projects" '{"workers":5,"decisions":0,"subscriptions":null}' '[]')
  printf '%s' "$out" | jq -e '
    (.cards[0].blocs[0].doing | length) == 5
    and (.cards[0].blocs[0].doing | map(.hidden)) == [false, false, false, true, true]
    and .cards[0].blocs[0].more == "voir tout (5)"
  ' >/dev/null || fail "the doing block did not cap at three visible rows: $out"
  pass "the doing block shows three rows and folds the rest behind voir tout"
}

test_a_choice_button_queues_a_prompt_for_firstmate_without_a_keyed_answer() {
  local home out projects
  home=$(make_home click)
  projects=$(jq -n --argjson p "$(empty_project torre Torre)" '
    [ ($p | .missing_from_you = [{key: "torre-hebergement", question: "Hébergement : chez toi ou chez Torre ?",
        options: [{value: "chez-toi", label: "chez toi"}, {value: "chez-torre", label: "chez Torre"}], url: null}]) ]')
  out=$(render "$home" "$projects" '{"workers":0,"decisions":1,"subscriptions":null}' '[]' click=torre/torre-hebergement/chez-torre)
  printf '%s' "$out" | jq -e '
    .calls == ["queuePrompt", "sendQueuedPrompts"]
    and (.cards[0].blocs[1].decisions[0].message | contains("envoyé à firstmate"))
    and (.queued | length) == 1
    and .queued[0].tag == "choice"
    and (.queued[0].prompt | test("Torre") and test("Hébergement") and test("chez Torre"))
    and .queued[0].data == {"projet": "torre", "decision": "torre-hebergement", "choix": "chez-torre", "nature": "decision"}
    and (.queued[0].data | has("question") | not) and (.queued[0].data | has("answer") | not)
    and .cards[0].blocs[1].decisions[0].sent == true and .cards[0].blocs[1].decisions[0].refused == false
    and (.cards[0].blocs[1].decisions[0].choices == ["chez-toi", "chez-torre"])
  ' >/dev/null || fail "a choice button did not queue a plain prompt for firstmate: $out"
  for mode in absent queue-only reject; do
    out=$(render "$home" "$projects" '{"workers":0,"decisions":1,"subscriptions":null}' '[]' click=torre/torre-hebergement/chez-torre "lavish=$mode")
    printf '%s' "$out" | jq -e '.cards[0].blocs[1].decisions[0] | .sent == false and .refused == true and (.message | contains("non transmis")) and (.message | contains("envoyé") | not)' >/dev/null || fail "unavailable delivery was confirmed: $out"
  done
  pass "a choice button queues a prompt for firstmate and never a keyed answer that could close a task"
}

test_a_card_says_what_it_asks_and_admits_a_state_it_does_not_know() {
  local home out projects
  home=$(make_home natures)
  projects=$(jq -n --argjson p "$(empty_project torre Torre)" '
    [ ($p | .missing_from_you = [
        {key: "torre-hebergement", question: "Hébergement : chez toi ou chez Torre ?", nature: "decision", ask: null,
         options: [{value: "chez-toi", label: "chez toi"}, {value: "chez-torre", label: "chez Torre"}], url: null},
        {key: "torre-relance", question: "relancer le fournisseur", nature: "decision", ask: "on le fait, ou on ne le fait pas ?",
         options: [{value: "on-y-va", label: "on y va"}, {value: "on-ne-le-fait-pas", label: "on ne le fait pas"}], url: null},
        {key: "torre-domaine", question: "Le domaine est basculé ?", nature: "etat", ask: "je ne sais pas si c\u2019est déjà fait",
         options: [{value: "je-l-ai-fait", label: "je l\u2019ai fait"}, {value: "pas-encore", label: "pas encore"}], url: null}]) ]')
  out=$(render "$home" "$projects" '{"workers":0,"decisions":3,"subscriptions":null}' '[]')
  printf '%s' "$out" | jq -e '
    (.cards[0].blocs[1].decisions | map({key, nature, ask})) == [
      {key: "torre-hebergement", nature: "decision", ask: null},
      {key: "torre-relance", nature: "decision", ask: "on le fait, ou on ne le fait pas ?"},
      {key: "torre-domaine", nature: "etat", ask: "je ne sais pas si c\u2019est déjà fait"}]
  ' >/dev/null || fail "the card did not show what it asks beside the question: $out"
  pass "a card shows the question it asks, and a state it cannot establish says so on the page"
}
test_a_card_says_what_it_asks_and_admits_a_state_it_does_not_know

test_filled_blocks_render_their_content_and_gaps() {
  local home out projects
  home=$(make_home filled)
  projects=$(jq -n --argjson p "$(empty_project torre Torre)" '
    [ ($p | .headline = "Pilote le 14/09"
         | .missing_from_others = [{who: "Eli", what: "les factures", tag: "avant le 11/09"}]
         | .pages = [{label: "Espace client", url: "https://example.test/c", state: "à jour 10/09"}]
         | .costs = {period: "septembre", tokens_api: "123 EUR au prix API", subscription_share: null, source: "mesure de nuit"}
         | .journal = [{when: "10/09", what: "cerveau v1", url: "https://example.test/pr/61"}]
         | .meeting = {title: "Pilote sur place", date: "2026-09-14", with: "Eli", bring: ["la démo"], decide: ["l enveloppe"]}
         | .gaps = ["coûts à mesurer"]) ]')
  out=$(render "$home" "$projects" '{"workers":0,"decisions":1,"subscriptions":null}' '[]')
  printf '%s' "$out" | jq -e '
    .cards[0].headline == "Pilote le 14/09"
    and (.cards[0].blocs[2].items == ["Eli : les facturesavant le 11/09"])
    and (.cards[0].blocs[3].items == ["Espace clientà jour 10/09"])
    and (.cards[0].blocs[4].cells == ["123 EUR au prix API", "à mesurer"])
    and (.cards[0].blocs[5].items == ["10/09 · cerveau v1"])
    and (.cards[0].blocs[6].items == ["Pilote sur place, 14/09 avec Eli", "À emporter : la démo", "À décider : l enveloppe"])
    and .cards[0].gaps == ["coûts à mesurer"]
  ' >/dev/null || fail "filled blocks did not render their content: $out"
  pass "filled blocks render their content, the meeting date in French, and the brain gaps"
}

test_unassigned_rows_get_their_own_rail_entry() {
  local home out
  home=$(make_home unassigned)
  out=$(render "$home" "[$(empty_project torre Torre)]" '{"workers":0,"decisions":0,"subscriptions":null}' \
    '[{"id":"sacem-relance","what":"SACEM : relancer Sabine"}]')
  printf '%s' "$out" | jq -e '
    (.rail | map(.id)) == ["torre", "sans-projet"] and .rail[1].count == 1
    and (.cards[1].blocs | length) == 1 and .cards[1].blocs[0].num == 0
    and (.cards[1].blocs[0].items == ["SACEM : relancer Sabine"])
  ' >/dev/null || fail "unassigned rows did not get their own rail entry: $out"
  pass "unassigned rows get their own rail entry that reveals what the brain cannot place"
}

test_a_narrow_screen_keeps_only_il_manque_de_toi_open() {
  local home out
  home=$(make_home narrow)
  out=$(render "$home" "[$(empty_project torre Torre)]" '{"workers":0,"decisions":0,"subscriptions":null}' '[]' width=390)
  printf '%s' "$out" | jq -e '(.cards[0].blocs | map(.open)) == [false, true, false, false, false, false, false]' >/dev/null \
    || fail "a narrow screen did not fold every block but il manque de toi: $out"
  pass "a narrow screen keeps only il manque de toi open"
}

test_unreadable_data_refuses_instead_of_showing_an_empty_fleet() {
  local home out page
  home=$(make_home refuse)
  render "$home" "[$(empty_project torre Torre)]" '{"workers":0,"decisions":0,"subscriptions":null}' '[]' >/dev/null
  page="$home/.lavish/projets.html"
  perl -0pi -e 's/"schema":"fm-projets-board.v1"/"schema":"fm-projets-board.v9"/' "$page"
  out=$(node "$HARNESS" "$page") || fail "the harness could not run the tampered page"
  printf '%s' "$out" | jq -e '(.error | test("pas au format attendu")) and (.cards | length) == 0' >/dev/null \
    || fail "a wrong-schema page did not refuse plainly: $out"
  pass "unreadable page data refuses plainly instead of showing an empty fleet"
}

test_fresh_empty_calendar() {
  local home out projects
  home=$(make_home empty-calendar)
  projects=$(empty_project torre Torre | jq '[. + {agenda_available:true,meetings:[]}]')
  out=$(render "$home" "$projects" '{"workers":0,"decisions":0,"subscriptions":null}' '[]')
  printf '%s' "$out" | jq -e '.cards[0].blocs[6].text | contains("Aucune reunion a venir dans ton agenda pour ce projet") and (contains("Agenda non lu") | not)' >/dev/null || fail "empty calendar misreported as unavailable"
  pass "a fresh empty calendar is distinguished from an unread calendar"
}
test_fresh_empty_calendar

test_the_brain_card_swaps_its_blocks_and_carries_unlinked_rows() {
  local home out projects
  home=$(make_home brain)
  projects=$(jq -n --argjson a "$(empty_project torre Torre)" --argjson b "$(empty_project cerveau Cerveau)" '
    [ $a,
      ($b | .brain = true
          | .missing_from_you = [
              {key: "cerveau-index", question: "Adopter gbrain en index ?", options: [{value: "oui", label: "oui"}], url: null},
              {key: "reco__gbrain", question: "Adopter gbrain comme index", kind: "recommandation", options: [{value: "on-y-va", label: "on y va"}], url: null},
              {key: "article__doctrine", question: "Article à valider : Doctrine de dépense", kind: "article", options: [{value: "valide", label: "validé"}], url: null}]
          | .unlinked = [{id: "sacem-relance", what: "SACEM : relancer Sabine"}]
          | .pages = [{label: "Index du cerveau", url: "https://example.test/brain", state: "à jour 10/09"}]
          | .quick_wins = ["Indexer les rapports"]) ]')
  out=$(render "$home" "$projects" '{"workers":0,"decisions":3,"subscriptions":null}' '[]')
  printf '%s' "$out" | jq -e '
    (.rail | map(.id)) == ["torre", "cerveau"] and .rail[1].count == 3
    and (.cards[1].brain == true)
    and (.cards[1].blocs | map(.title)) == ["1. On est en train de", "2. Il manque de toi", "3. Pas encore rattaché à un projet", "4. Pages du cerveau", "5. Coûts du mois (septembre)", "6. Journal, les 5 derniers événements", "7. Quick wins du cerveau"]
    and (.cards[1].blocs[1].decisions | map(.kind)) == [null, "recommandation", "article"]
    and (.cards[1].blocs[2].unlinked == ["sacem-relance"])
    and (.cards[1].blocs[3].items[0] | contains("Index du cerveau"))
    and (.cards[1].blocs[6].items == ["Indexer les rapports"])
    and (.cards[0].brain == false)
    and (.cards[0].blocs | map(.title))[2] == "3. Il manque des autres"
  ' >/dev/null || fail "the brain card did not swap its blocks or carry the unlinked rows: $out"
  pass "the brain card swaps two blocks, tags recommendations and articles, and carries what no project owns"
}

test_unassigned_rows_join_the_brain_card_instead_of_a_synthetic_entry() {
  local home out projects
  home=$(make_home brain-unassigned)
  projects=$(jq -n --argjson b "$(empty_project cerveau Cerveau)" '[ ($b | .brain = true | .unlinked = [{id: "x", what: "Un élément"}]) ]')
  out=$(render "$home" "$projects" '{"workers":0,"decisions":0,"subscriptions":null}' '[]')
  printf '%s' "$out" | jq -e '(.rail | map(.id)) == ["cerveau"] and (.cards | length) == 1 and (.cards[0].blocs[2].unlinked == ["x"])' >/dev/null \
    || fail "a brain card still produced a synthetic sans-projet entry: $out"
  pass "with a brain card, nothing renders as a separate sans-projet entry"
}

test_scouts_and_creations_render_as_extra_entries() {
  local home out projects
  home=$(make_home extras)
  projects=$(jq -n --argjson p "$(empty_project torre Torre)" '
    [ ($p | .doing = [{id: "torre-site", result: "site click and collect", status: "en cours", next: null, url: null}]
         | .scouts = [{id: "torre-audit", result: "audit Shopify contre Stripe", status: "en cours", next: null, url: null}]
         | .creations = [{label: "Démo de l interface", url: "https://example.test/demo", kind: "page"}]) ]')
  out=$(render "$home" "$projects" '{"workers":2,"decisions":0,"subscriptions":null}' '[]')
  printf '%s' "$out" | jq -e '
    (.cards[0].blocs[0].doing | map(.id)) == ["torre-site"]
    and (.cards[0].blocs[0].scouts | map(.id)) == ["torre-audit"]
    and (.cards[0].blocs[0].scouts[0].text | contains("audit Shopify") and contains("en cours"))
    and (.cards[0].blocs[3].creations | map(.label)) == ["Démo de l interface"]
    and (.cards[0].blocs[3].links == ["https://example.test/demo"])
  ' >/dev/null || fail "scouts and creations did not render as extra entries: $out"
  pass "scouts for the brain and creations render as extra entries of blocks 1 and 4"
}

test_cells_carry_their_column_label_for_the_stacked_phone_layout() {
  local home out projects
  home=$(make_home labels)
  projects=$(jq -n --argjson p "$(empty_project torre Torre)" '
    [ ($p | .doing = [{id: "torre-site", result: "site", status: "en cours", next: "fusion à confirmer", url: null}]) ]')
  out=$(render "$home" "$projects" '{"workers":1,"decisions":0,"subscriptions":null}' '[]')
  printf '%s' "$out" | jq -e '
    (.cards[0].blocs[0].labels == ["Résultat", "Où ça en est", "Ensuite"])
    and (.cards[0].blocs[0].cells == ["site", "en cours", "fusion à confirmer"])
    and (.cards[0].blocs[4].labels == ["Jetons, valeur API", "Part de tes abonnements"])
  ' >/dev/null || fail "table cells do not carry their column label: $out"
  pass "every table cell carries its column label so the phone layout can stack it"
}

test_a_folded_block_keeps_no_body_until_its_toggle_is_clicked() {
  local home out
  home=$(make_home toggle)
  out=$(render "$home" "[$(empty_project torre Torre)]" '{"workers":0,"decisions":0,"subscriptions":null}' '[]' width=390 toggle=torre/1)
  printf '%s' "$out" | jq -e '(.cards[0].blocs | map(.open)) == [true, true, false, false, false, false, false]' >/dev/null \
    || fail "clicking a folded block did not open it, or opened others: $out"
  pass "a folded block opens on its toggle and folded bodies stay hidden"
}
test_the_brain_card_swaps_its_blocks_and_carries_unlinked_rows
test_unassigned_rows_join_the_brain_card_instead_of_a_synthetic_entry
test_scouts_and_creations_render_as_extra_entries
test_cells_carry_their_column_label_for_the_stacked_phone_layout
test_a_folded_block_keeps_no_body_until_its_toggle_is_clicked

test_an_empty_project_renders_all_seven_blocks_with_empty_states
test_the_rail_keeps_payload_order_and_shows_one_project_at_a_time
test_doing_shows_three_rows_and_folds_the_rest_behind_voir_tout
test_a_choice_button_queues_a_prompt_for_firstmate_without_a_keyed_answer
test_filled_blocks_render_their_content_and_gaps
test_unassigned_rows_get_their_own_rail_entry
test_a_narrow_screen_keeps_only_il_manque_de_toi_open
test_unreadable_data_refuses_instead_of_showing_an_empty_fleet
