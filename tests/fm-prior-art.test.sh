#!/usr/bin/env bash
# tests/fm-prior-art.test.sh - behavior tests for the "what do we already know
# about this?" lookup that firstmate runs before commissioning an investigation.
#
# The contracts under test are the ones a wrong answer would quietly break:
#
#   Dates      Every result carries a date AND the provenance of that date. A
#              dated section wins over a date stated in the document's header,
#              which wins over the file's modification time, and a modification
#              time is always labelled as not an authored date. A yearless
#              heading date is completed and labelled, never silently.
#   Recall     A query matches regardless of accents and case, because half of
#              these records are written with accents and half without.
#   Honesty    A word present in no document is named as such; a word too common
#              to discriminate is set aside and named; a subject with no match
#              returns nothing rather than something adjacent.
#   Scope      A word that appears only in a document's PATH is never reported
#              as something that document says.
#   Read-only  The lookup never modifies the records it reads.
#   Freshness  An edited document is picked up without anyone refreshing
#              anything by hand.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/bin/fm-prior-art.sh"

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v perl >/dev/null 2>&1 || { printf 'ok - skipped (perl not installed)\n'; exit 0; }

HOME_DIR=$(fm_test_tmproot fm-prior-art) || fail "could not make a temp home"
DATA="$HOME_DIR/data"
mkdir -p "$DATA"

# A report that states its own date in the header.
mkdir -p "$DATA/alpha-sujet"
cat > "$DATA/alpha-sujet/report.md" <<'MD'
# Etude sur la memoire des agents

> Date : 2026-08-25. Auteur : un equipier.

## Ce que l'on a trouve

La memoire de l'agent est reconstruite a chaque tour. Le cout est reel.
MD

# A report that dates nothing, so only its modification time can answer.
mkdir -p "$DATA/beta-sujet"
cat > "$DATA/beta-sujet/report.md" <<'MD'
# Note sans aucune date

Le sujet betaterme est traite ici sans qu'aucune date ne soit ecrite.
MD

# An archive whose entries are dated sections: the date belongs to the passage.
cat > "$DATA/done-archive.md" <<'MD'
## Archived 2026-08-24

- [x] un premier chantier, sans rapport avec le reste.

## Archived 2026-09-02

- [x] chantier sur la memoire du club, livre ce jour la.
MD

# A learning file using the yearless heading convention these records really use.
cat > "$DATA/learnings.md" <<'MD'
# Learnings

## Codex et la memoire (06/09)

Le modele oublie entre deux tours.
MD

# Accented and uppercase spellings of one word, plus a word common to most
# documents so the ranking has boilerplate to set aside.
cat > "$DATA/captain.md" <<'MD'
# Preferences

## Gout

Yan veut une MEMOIRE fiable, et une mémoire datee. Chantier courant.
MD

mkdir -p "$DATA/gamma-sujet"
cat > "$DATA/gamma-sujet/brief.md" <<'MD'
# Task
Chantier courant, instructions standard.
MD
mkdir -p "$DATA/delta-sujet"
cat > "$DATA/delta-sujet/brief.md" <<'MD'
# Task
Chantier courant, instructions standard, second exemplaire.
MD

mkdir -p "$DATA/epsilon-sujet"
cat > "$DATA/epsilon-sujet/brief.md" <<'MD'
# Task
Chantier courant, instructions standard, troisieme exemplaire.
MD
mkdir -p "$DATA/zeta-sujet"
cat > "$DATA/zeta-sujet/brief.md" <<'MD'
# Task
Chantier courant, instructions standard, quatrieme exemplaire.
MD

# The word "zzpathonly" appears ONLY in this path, never in any document text.
mkdir -p "$DATA/zzpathonly"
cat > "$DATA/zzpathonly/report.md" <<'MD'
# Un rapport dont le contenu ne nomme jamais le dossier

Rien ici ne reprend le nom du dossier. Chantier courant.
MD

run() { FM_HOME="$HOME_DIR" "$TOOL" "$@" 2>&1; }

# --- dates ------------------------------------------------------------------

out=$(run --limit 9 memoire) || fail "lookup failed: $out"

assert_contains "$out" "2026-08-25" "the report's stated date must be reported"
assert_contains "$out" "stated in the document" "a header date must be labelled as stated"
assert_contains "$out" "2026-09-02" "the archive passage must take its own section's date"
assert_contains "$out" "dated section" "a section date must be labelled as such"

# The yearless "(06/09)" heading must be completed from the file and labelled.
assert_contains "$out" "year inferred" "a yearless section date must say the year was inferred"
year=$(date +%Y)
assert_contains "$out" "$year-09-06" "a yearless section date must be completed to a real date"

# Every result carries a date: no result line may be left undated.
results=$(printf '%s\n' "$out" | grep -c '^   source: data/')
dated=$(printf '%s\n' "$out" | grep -cE '^   [0-9]{4}-[0-9]{2}-[0-9]{2}  \(')
[ "$results" -gt 0 ] || fail "expected some results for a word that is in these records"
[ "$results" = "$dated" ] || fail "every result must carry a date: $results results but $dated dated"

# A document that dates nothing falls back to its modification time, and that
# fallback must never be presentable as an authored date.
out_beta=$(run --limit 3 betaterme) || fail "lookup failed: $out_beta"
assert_contains "$out_beta" "file last changed, NOT an authored date" \
  "a modification-time date must be labelled as not authored"
pass "every result carries a date, and the date says where it came from"

# --- accents and case -------------------------------------------------------

plain=$(run --limit 99 memoire | grep -c '^   source: data/')
acc=$(run --limit 99 mémoire | grep -c '^   source: data/')
upper=$(run --limit 99 MEMOIRE | grep -c '^   source: data/')
[ "$plain" = "$acc" ] || fail "accented query must match the unaccented one ($plain vs $acc)"
[ "$plain" = "$upper" ] || fail "uppercase query must match the lowercase one ($plain vs $upper)"
assert_contains "$(run --limit 99 memoire)" "captain" \
  "a document spelling the word with an accent must still be found"
pass "accents and case do not change what is found"

# --- honesty ----------------------------------------------------------------

none=$(run zzqqxxnotaword) || fail "lookup failed: $none"
assert_contains "$none" "NOTHING FOUND" "an absent subject must say nothing was found"
assert_contains "$none" "FOUND NOWHERE" "an absent word must be named as found nowhere"
assert_not_contains "$none" "source: data/" "an absent subject must not offer an adjacent document"

partial=$(run --limit 3 memoire zzqqxxnotaword) || fail "lookup failed: $partial"
assert_contains "$partial" "FOUND NOWHERE: zzqqxxnotaword" \
  "a word found nowhere must be named even when other words match"
assert_contains "$partial" "source: data/" "the words that do match must still be answered"

common=$(run --limit 3 chantier memoire) || fail "lookup failed: $common"
assert_contains "$common" "TOO COMMON TO RANK ON" \
  "a word in most documents must be set aside from the ranking"
assert_contains "$common" "chantier" "the word set aside must be named"
pass "it is honest about what it did not find and what it could not use"

# --- scope ------------------------------------------------------------------

pathonly=$(run zzpathonly) || fail "lookup failed: $pathonly"
assert_contains "$pathonly" "NOTHING FOUND" \
  "a word that appears only in a file path must not be reported as document content"
pass "a word in a file path is not reported as something the document says"

# --- read-only --------------------------------------------------------------

before=$(find "$DATA" -type f -exec cksum {} + | sort)
run --limit 3 memoire > /dev/null
after=$(find "$DATA" -type f -exec cksum {} + | sort)
[ "$before" = "$after" ] || fail "the lookup must not modify the records it reads"
pass "the records are only read, never written"

# --- freshness --------------------------------------------------------------

assert_not_contains "$(run --limit 9 tresnouveaumot)" "source: data/" \
  "a word not yet written must not be found"
printf '\nUn tresnouveaumot vient d apparaitre.\n' >> "$DATA/alpha-sujet/report.md"
fresh=$(run --limit 9 tresnouveaumot) || fail "lookup failed: $fresh"
assert_contains "$fresh" "source: data/alpha-sujet/report.md" \
  "an edited document must be picked up without a manual refresh"
pass "an edited document is picked up on the next question"

# A question that changes nothing must not pay to rebuild.
reused=$(run --limit 1 memoire) || fail "lookup failed: $reused"
assert_contains "$reused" "index reused" "an unchanged corpus must reuse the index"
pass "an unchanged corpus is not re-indexed"
