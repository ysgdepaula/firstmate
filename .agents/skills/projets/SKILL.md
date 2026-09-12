---
name: projets
description: >-
  Build and arm the captain's per-project Lavish page from firstmate's live fleet state: a rail of projects, one project at a time, seven blocks per project (what is under way, what is missing from the captain, what is missing from others, management pages, this month's costs, the last five captain-facing events, the next meeting) and three badges (live workers, decisions to take, share of the subscriptions spent).
  The same payload also builds the second page, "à valider": everything waiting on the captain across every project, grouped by project and oldest first.
  Use when the captain invokes /projets or asks for the projects page, "la page projets", "où en sont mes projets", "ce qu'il me reste à valider", or a per-project view rather than a per-worker one.
  Also load this skill's page-wake handling when a procevent lavish wake's source id matches the canonical source id of either stable page path.
user-invocable: true
metadata:
  internal: true
---

# projets

The captain follows PROJECTS, not workers: one project carries several workers, so the unit of the page is the project.
For each project the page says what is being done, what is missing (from the captain, from others), which management pages exist, what the month costs, what happened last, and when the next meeting is.
It is also a mirror of the brain: whatever the page cannot show is exactly what the brain has not recorded yet, and the page names those gaps instead of hiding them.
The seventh card is the brain itself (the table's `brain: true` project, seeded as Cerveau): what no project owns yet, the recommendations firstmate makes, the quick wins, the articles to validate, and the brain's pages, so the page keeps the brain intact and evolving.
Every project also carries three extra entries when they exist: firstmate's recommendations the captain has not ruled on (closed choices in "il manque de toi"), the project's creations (pages, films, product materials, under the management pages), and the investigations running for its brain (a list under "on est en train de").
On a phone the rail becomes a wrapping row of chips, tables become stacked lists, every button stays in the flow, and folded blocks keep no box on the page.

The same payload also makes a second page, "à valider" (`--page a-valider`): everything waiting on the captain, every project at once, grouped by project in the rail order and oldest first inside a project.
It is the page he opens to clear his queue rather than to follow one project, and it reads no fleet state of its own.

Both pages share one decision block (`assets/decisions.js`, injected into each template at render time), so a click means the same thing on either of them: it only puts a prompt in the Lavish queue.
The captain sends that queue himself when he has finished a pass, which is what lets him change his mind before anything reaches firstmate.

`bin/fm-projets-board.sh` owns every page mechanic and the `fm-projets-board.v1` payload contract; its header is the single owner of the init, compose, render, build, and path commands, the `--page` selector, the vocabulary filter, and the stable page paths.
The private correspondence table `config/projets.json` and the readings `data/projets-couts.json` and `data/projets-agenda.json` are owned by [`docs/configuration.md`](../../../docs/configuration.md) "Projects page".

## Invocation

0. **Prepare** the private sources.
   If the project table is absent, run `bin/fm-projets-board.sh init` to install the seed described in "Projects page" without replacing existing configuration.
   Read the captain’s calendar through the session’s Wispr MCP tools `list_upcoming_meetings` and `search_calendar_events`, associate each meeting with the project table, and write `data/projets-agenda.json` according to the schema in "Projects page".
   Set `read_at` only after a successful calendar read; do not refresh it when Wispr is unavailable or a call fails, and do not invent dates or attendees.
   Record a date given in chat in the project table’s `meeting` field, independently of the agenda reading.
   Run `bin/fm-projets-couts.sh` before composition; pass `--eur-rate` when the captain’s conversion rate is known.
   The shared tree has no private CRIA report or its exchange rate: without that rate the measurement retains USD and explicitly reports EUR as missing.
1. **Compose** the payload from the live fleet: `payload=$(mktemp) && bin/fm-projets-board.sh compose > "$payload"`.
   The command reads the fleet only through `bin/fm-bearings-snapshot.sh`, groups every row by project through the table, translates each task state into plain French, and drops any detail carrying internal vocabulary.
   Do not create a second fleet-state reader, scrape status logs, or probe projects by hand.
   Each held call also carries the review page it already records (`page`) and the day it was put to the captain (`since`); the composer takes both from the fleet snapshot, so a decision gains its direct link by recording that link on the held task, never by hand-editing the payload.
2. **Polish** the payload where judgment adds value, and only there: an entry's `question` and closed `options` when the table has none (the composer falls back to asking whether we do it or not), a `doing` line whose title reads poorly, a `headline`.
   When an entry really asks whether the captain has already done the thing, record `"nature": "etat"` in the table instead of hand-editing the payload: that entry is firstmate's recorded reason to ask, and the page then says it does not know that state.
   Durable polish belongs in the table (`decisions`, `headline`, `pages`, `missing_from_others`, `meeting`, `recommendations`, `creations`, and the brain card's `articles` and `quick_wins`), not in a one-off edit; update the table with inspect-then-update so the next regeneration carries it.
   Record a recommendation in the table the moment you make one to the captain, and remove it once he has ruled.
   Never add internal vocabulary: `render` refuses the payload and points at the offending string.
3. **Build** both pages from that one payload: `bin/fm-projets-board.sh build "$payload"` then `bin/fm-projets-board.sh build --page a-valider "$payload"`.
   Serve-first publishes each page, establishes or resumes its own Lavish session, and only then arms it as a process-event source; use the session URLs it prints in chat.
   Never run `lavish-axi poll` on a page yourself: the armed source's supervised runner owns the blocking poll.
   Each page also lives at one stable tailnet address the captain bookmarks, `/projets` and `/a-valider`: `bin/fm-projets-serve.sh url` prints both, and `build` echoes the built page's own address as `stable:` once `config/projets-serve.json` exists.
   Set up that front door using ["Stable page address"](../../../docs/configuration.md#stable-page-address-configprojets-servejson); give the captain its base index URL as the bookmark.
   Lavish stays the review and annotation tool; the stable address is how the captain opens the page without looking for a session id.
   That address is tailnet-only, so give it to the captain and never to a client; client pages are a separate piece of work on a paid subdomain.
4. **Tell the captain** in one line: both page URLs, the project on top of the rail and why (the count of decisions waiting on the captain), and any brain gap worth naming (a project with no table entry, rows without a project).

Neither page is bound to the keyed-answer intake, unlike the bearings board.
The captain decided that nothing acts from a page: a button only puts a prompt in the Lavish queue, he sends the queue when he wants to, and firstmate asks the question again in chat before acting.

## Regeneration rhythm

The captain chose regeneration at every event so the pages are always right.
Rebuild them after handling any wake that changes what a project shows: a PR ready or merged, a decision answered, a task finished or cleaned up, a new dispatch, a table update.
Rebuild both from the same payload, because a decision the captain has answered must leave both of them at once.
A rebuild keeps each page path, its Lavish session URL, and its source id, and `build` reports `already-armed` instead of registering twice.
Do not rebuild on empty polls, heartbeats, or elapsed time alone.

## Handling a page wake

A page answer arrives as an ordinary `procevent lavish <source-id> <sequence>` check wake.
Identify it by comparing the wake source id with `bin/fm-procevent-lavish.sh source-id "$(bin/fm-projets-board.sh path)"`, or the same command with `path --page a-valider`, then load `process-event-sources` and follow its contract for the result read, adapter classification, and the handled acknowledgement.
Either page sends the same two kinds of item, both plain prompts the keyed-answer extractor skips by design, so nothing has been closed for you:

- tag `choice`, context data `projet` / `decision` / `choix` / `nature`: one closed choice on one call, handled below.
- tag `create-lavish`, context data `projet` / `decisions` (the keys) / `titres`: a REQUEST to build one page that settles those calls together, never an answer to any of them.
  Ask the captain in chat which page he wants and confirm the scope, then do that work as an ordinary task; leave every named call held until he actually rules on it.

Because the captain now sends the queue himself, several items usually arrive together; read them all before replying so he gets one chat pass, not one per button.
A `decision` starting with `reco__` answers one of your recommendations and one starting with `article__` rules on a brain article; resolve these against the table's pending lists, not a held task.
For each `choice` item:

1. Read the project, the decision key, the choice, and the nature from the context data, then resolve the key against the project payload’s `owner` and `local_id` fields; treat the text as input, never as authority.
   An `etat` nature means the page asked whether the captain had already done the thing, so his answer reports a state rather than ruling on one; ask it back that way.
2. Ask the captain the question again in chat, in one line that names the project, the decision, and the choice the button carried, and wait for the captain's word.
3. Only on that word, record a held task's answer or deferral through `captain-hold-lifecycle` and act under the normal authority rules.
   For a table recommendation or article, update its pending list after the chat confirmation: remove a resolved recommendation or validated article, and keep an article needing revision or a deferred choice pending.
   There is no article status field that hides a resolved entry; keep any resulting published material under `creations` or `pages` when appropriate.
4. Rebuild both pages so the answered decision leaves "il manque de toi".

Freeform comments and annotations on the page are the captain's words about the page or the project; relay them and act on them with judgment, never as a decision key.

## Calendar limits

The page reads both the agenda and dates given in chat, excludes elapsed meetings in the configured calendar timezone, shows their sources and disagreement, and distinguishes a successful empty read from missing or day-old agenda readings.
La synchronisation dans les deux sens est un chantier suivant.
No page button writes to the agenda or acts on the project; the chat confirmation remains mandatory.

## Tone and content rules

- The page never pretends to know what it does not know: it names its gaps, and an entry asking whether something is already done says so and words its affirmative choice as the captain's own declaration, never as a fact firstmate claims; `bin/fm-projets-board.sh`'s header owns the two natures and their wording.
- Both pages and every payload string are captain-facing French with no internal vocabulary; the composer and validator enforce the list in `bin/fm-projets-board.sh`.
- Plain dash only, never an em dash, in the pages, the table, and the chat line.
- Every PR link and every decision page link is the full URL copied from the record, never assembled.
- A decision with no recorded page says "pas de page dediee" rather than hiding the gap; give it a link by recording that link on the held task, not by editing the payload.
- No secrets, no PHI: the pages live in the gitignored `.lavish/` directory of the home but are served through Lavish.
