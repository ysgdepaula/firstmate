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

touch -t 202407101200 "$DATA/learnings.md" "$DATA/beta-sujet/report.md"

run() { FM_HOME="$HOME_DIR" "$TOOL" "$@" 2>&1; }

# --- dates ------------------------------------------------------------------

out=$(run --limit 9 memoire) || fail "lookup failed: $out"

assert_contains "$out" "2026-08-25" "the report's stated date must be reported"
assert_contains "$out" "stated in the document" "a header date must be labelled as stated"
assert_contains "$out" "2026-09-02" "the archive passage must take its own section's date"
assert_contains "$out" "dated section" "a section date must be labelled as such"

# The yearless "(06/09)" heading must be completed from the file and labelled.
assert_contains "$out" "year inferred" "a yearless section date must say the year was inferred"
year=2024
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
assert_contains "$out_beta" "2024-07-10" "modification-time fallback must use the file date"
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

case_home="$HOME_DIR/cases"
mkdir -p "$case_home/data"
case_run() { FM_HOME="$case_home" "$TOOL" "$@" 2>&1; }
printf 'alpha\n' > "$case_home/data/fresh.md"
perl -MTime::HiRes=utime -e 'utime 1700000000.1, 1700000000.1, $ARGV[0] or die $!' "$case_home/data/fresh.md"
initial=$(case_run alpha) || fail "initial same-size lookup failed: $initial"
assert_contains "$initial" "source: data/fresh.md" "the original word must be found"
printf 'omega\n' > "$case_home/data/fresh.md"
perl -MTime::HiRes=utime -e 'utime 1700000000.8, 1700000000.8, $ARGV[0] or die $!' "$case_home/data/fresh.md"
fresh=$(case_run omega) || fail "same-size lookup failed: $fresh"
assert_contains "$fresh" "source: data/fresh.md" "same-size edits within one second must be found"
assert_contains "$(case_run alpha)" "FOUND NOWHERE: alpha" "replaced text must stop matching"
pass "same-size subsecond edits invalidate the saved search"

cat > "$case_home/data/sections.md" <<'MD'
# Notes
Date: 2025-07-10
## Alpha 2026-08-01
firstdatedword
### Nested
nesteddateword
### Nested dated 2026-08-02
childdatedword
### Nested sibling
parentsiblingword
## Beta
siblingdateword
### Deeper
siblingchildword
# New root
rootdateword
MD
for word in firstdatedword nesteddateword parentsiblingword; do
  out=$(case_run "$word") || fail "section lookup failed: $out"
  assert_contains "$out" "2026-08-01  (dated section)" "a date must reach its nested sections"
done
out=$(case_run childdatedword) || fail "child section lookup failed: $out"
assert_contains "$out" "2026-08-02  (dated section)" "a nested date must override its ancestor"
for word in siblingdateword siblingchildword rootdateword; do
  out=$(case_run "$word") || fail "sibling section lookup failed: $out"
  assert_contains "$out" "2025-07-10  (stated in the document)" "a sibling must fall back to document metadata"
  assert_not_contains "$out" "dated section" "an expired heading must not date a sibling"
done
cat > "$case_home/data/no-header.md" <<'MD'
# Notes
## Alpha 2026-08-01
unrelatedword
## Beta
unparentedword
MD
touch -t 202407101200 "$case_home/data/no-header.md"
out=$(case_run unparentedword) || fail "undated sibling lookup failed: $out"
assert_contains "$out" "2024-07-10  (file last changed" "an unrelated section date must not become a document date"
pass "dated sections end at siblings and preserve applicable ancestor dates"

case_home="$HOME_DIR/passages"
mkdir -p "$case_home/data"
cat > "$case_home/data/report.md" <<'MD'
# Report
## 2026-08-01
chantier chantier chantier chantier
## 2026-09-02
La mémoire est reconstruite a chaque tour.
MD
for n in 1 2 3; do printf 'chantier courant\n' > "$case_home/data/brief$n.md"; done
out=$(case_run chantier memoire) || fail "passage lookup failed: $out"
assert_contains "$out" "TOO COMMON TO RANK ON" "the boilerplate must be excluded"
assert_contains "$out" "> La mémoire est reconstruite" "the quotation must use the remaining subject"
assert_contains "$out" "2026-09-02  (dated section)" "the date must belong to the selected quotation"
assert_not_contains "$out" "> chantier" "excluded boilerplate must not select the quotation"
pass "excerpts and dates follow the terms retained for ranking"

case_home="$HOME_DIR/coverage"
mkdir -p "$case_home/data/hidden"
printf 'secretword\n' > "$case_home/data/hidden/report.md"
printf 'publicword\n' > "$case_home/data/public.md"
case_run secretword >/dev/null || fail "coverage setup failed"
chmod 000 "$case_home/data/hidden/report.md"
if [ ! -r "$case_home/data/hidden/report.md" ]; then
  out=$(case_run secretword)
  rc=$?
  chmod 644 "$case_home/data/hidden/report.md"
  [ "$rc" -ne 0 ] || fail "an unreadable record must fail the lookup: $out"
  assert_contains "$out" "Not read:" "unreadable records must be identified"
  assert_contains "$out" "hidden/report.md" "the unreadable source must be named"
  assert_not_contains "$out" "FOUND NOWHERE" "incomplete coverage must not claim absence"
  out=$(case_run secretword) || fail "restored permission lookup failed: $out"
  assert_contains "$out" "source: data/hidden/report.md" "restored read access must be retried"
  chmod 000 "$case_home/data/hidden"
  out=$(case_run secretword)
  rc=$?
  chmod 755 "$case_home/data/hidden"
  [ "$rc" -ne 0 ] || fail "a traversal failure must fail the lookup: $out"
  assert_contains "$out" "hidden" "the unsearched directory must be named"
  assert_not_contains "$out" "FOUND NOWHERE" "failed traversal must not claim absence"
  pass "unreadable records and traversal failures are explicit and recoverable"
else
  chmod 644 "$case_home/data/hidden/report.md"
  pass "permission checks skipped because this user can read mode-000 files"
fi

ambiguous="$case_home/data/ambiguous"$'\n'"name.md"
printf 'hiddenword\n' > "$ambiguous"
out=$(case_run hiddenword)
rc=$?
rm "$ambiguous"
[ "$rc" -ne 0 ] || fail "an ambiguous source must fail the lookup"
assert_contains "$out" "ambiguous source name" "an unrepresentable source must be reported"
assert_not_contains "$out" "FOUND NOWHERE" "skipped source names must not imply new ground"
pass "unrepresentable source names cannot produce false absence"

case_home="$HOME_DIR/concurrent"
mkdir -p "$case_home/data" "$case_home/bin"
printf 'uniqueneedle\n' > "$case_home/data/z-original.md"
case_run uniqueneedle >/dev/null || fail "concurrent setup failed"
real_grep=$(command -v grep)
cat > "$case_home/bin/grep" <<'SH'
#!/usr/bin/env bash
"$PRIOR_ART_REAL_GREP" "$@"
rc=$?
if [ "${1:-}" = -E ] && [ "${2:-}" = uniqueneedle ]; then
  : > "$PRIOR_ART_SYNC/ready"
  for (( i=0; i<500; i++ )); do
    [ -e "$PRIOR_ART_SYNC/release" ] && break
    sleep 0.01
  done
fi
exit "$rc"
SH
chmod +x "$case_home/bin/grep"
PATH="$case_home/bin:$PATH" PRIOR_ART_REAL_GREP="$real_grep" PRIOR_ART_SYNC="$case_home" \
  FM_HOME="$case_home" "$TOOL" uniqueneedle > "$case_home/reader.out" 2>&1 &
reader=$!
for (( i=0; i<500; i++ )); do
  [ -e "$case_home/ready" ] && break
  sleep 0.01
done
[ -e "$case_home/ready" ] || fail "reader never reached the synchronization point"
printf 'unrelated document\n' > "$case_home/data/a-inserted.md"
(case_run --rebuild > "$case_home/writer.out"; result=$?; : > "$case_home/writer.done"; exit "$result") &
writer=$!
for (( i=0; i<100; i++ )); do
  [ -e "$case_home/writer.done" ] && break
  sleep 0.01
done
: > "$case_home/release"
wait "$reader" || fail "concurrent reader failed: $(cat "$case_home/reader.out")"
wait "$writer" || fail "concurrent rebuild failed: $(cat "$case_home/writer.out")"
out=$(cat "$case_home/reader.out")
assert_contains "$out" "source: data/z-original.md" "in-flight hits must retain their original source"
assert_contains "$out" "> uniqueneedle" "the quotation must come from the matched source"
assert_not_contains "$out" "source: data/a-inserted.md" "a rebuild must not reassign document IDs under readers"
out=$(case_run uniqueneedle) || fail "lookup after concurrent rebuild failed: $out"
assert_contains "$out" "source: data/z-original.md" "the next reader must use the completed rebuild"
pass "concurrent rebuilds cannot mix a reader's document map and hits"

mkdir -p "$case_home/unused-temp"
out=$(TMPDIR="$case_home/unused-temp" case_run uniqueneedle) || fail "local scratch lookup failed: $out"
[ -z "$(find "$case_home/unused-temp" -mindepth 1 -print)" ] || fail "search scratch must stay inside its own index"
pass "search scratch stays under the tool's own state directory"
