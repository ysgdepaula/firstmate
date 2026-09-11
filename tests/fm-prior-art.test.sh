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
TOOL="${FM_PRIOR_ART_TEST_TOOL:-$ROOT/bin/fm-prior-art.sh}"

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v perl >/dev/null 2>&1 || { printf 'ok - skipped (perl not installed)\n'; exit 0; }

HOME_DIR=$(fm_test_tmproot fm-prior-art) || fail "could not make a temp home"
DATA="$HOME_DIR/data"
mkdir -p "$DATA"

case_run() { FM_HOME="$case_home" "$TOOL" "$@" 2>&1; }

check_search_options() {
  local case_home="$HOME_DIR/search-options" out
  mkdir -p "$case_home/data"
  printf 'Use --resolve-key to identify the source.\n' > "$case_home/data/options.md"
  out=$(case_run -- --resolve-key) || fail "dash-prefixed search failed: $out"
  assert_contains "$out" "source: data/options.md" "dash-prefixed subjects must be searched as text"
  assert_contains "$out" "> Use --resolve-key" "the matching quotation must be returned"
  assert_not_contains "$out" "FOUND NOWHERE" "a dash-prefixed match must not be reported absent"
  pass "dash-prefixed subjects are searched as text"
}

check_search_failure() {
  local case_home="$HOME_DIR/search-failure" out rc status partial
  mkdir -p "$case_home/data" "$case_home/bin"
  printf 'documentedword\n' > "$case_home/data/report.md"
  cat > "$case_home/bin/grep" <<'SH'
#!/usr/bin/env bash
if [ "${PRIOR_ART_PARTIAL:-0}" = 1 ]; then
  printf '1\t1\tdocumentedword\n'
fi
printf 'simulated search failure\n' >&2
exit "$PRIOR_ART_SEARCH_STATUS"
SH
  chmod +x "$case_home/bin/grep"
  for status in 2 3; do
    for partial in 0 1; do
      out=$(PATH="$case_home/bin:$PATH" PRIOR_ART_SEARCH_STATUS="$status" PRIOR_ART_PARTIAL="$partial" case_run documentedword absentword)
      rc=$?
      [ "$rc" -ne 0 ] || fail "search errors must fail even after partial output: $out"
      assert_contains "$out" "search could not be completed" "the operational failure must be reported"
      assert_not_contains "$out" "FOUND NOWHERE" "failed searches cannot establish absence"
      assert_not_contains "$out" "NOTHING FOUND" "failed searches cannot establish empty results"
      assert_not_contains "$out" "source: data/" "partial search output must not become an answer"
    done
  done
  pass "search failures never become absence claims or partial answers"
}

check_fenced_dates() {
  local case_home="$HOME_DIR/fenced-dates" out word
  mkdir -p "$case_home/data"
  cat > "$case_home/data/report.md" <<'MD'
# Investigation
Date: 2025-01-01
## Findings 2026-08-01
```sh
# Install dependencies
insidefenceword
```
afterfenceword
~~~sh
# Another comment 1999-01-01
~~~
aftertildeword
   ````sh
```
# Still fenced 1998-01-01
~~~~
# Still the same example
   ````
afterlongfenceword
## Undated sibling
afterrealsiblingword
MD
  for word in insidefenceword afterfenceword aftertildeword afterlongfenceword; do
    out=$(case_run "$word") || fail "fenced section lookup failed: $out"
    assert_contains "$out" "2026-08-01  (dated section)" "fenced comments must preserve the enclosing section date"
    assert_contains "$out" "under: Findings 2026-08-01" "a code comment must not become the section heading"
  done
  out=$(case_run afterrealsiblingword) || fail "sibling after fence lookup failed: $out"
  assert_contains "$out" "2025-01-01  (stated in the document)" "real headings after fences must still end dated sections"
  cat > "$case_home/data/header.md" <<'MD'
# Note
```text
Date: 1999-01-01
```
~~~text
Date: 1998-01-01
~~~
Date: 2025-07-10
headerfenceword
MD
  out=$(case_run headerfenceword) || fail "fenced header lookup failed: $out"
  assert_contains "$out" "2025-07-10  (stated in the document)" "dates inside examples must not date the document"
  pass "Markdown fences protect both section and document dates"
}

check_source_snapshot() {
  local case_home="$HOME_DIR/source-snapshot" out real_grep
  mkdir -p "$case_home/data" "$case_home/bin"
  cat > "$case_home/data/dated.md" <<'MD'
# Investigation
## Findings 2026-08-01
La mémoire contient snapshotneedle.
MD
  cat > "$case_home/data/yearless.md" <<'MD'
# Learning
## Findings (06/09)
A yearless snapshotneedle.
MD
  printf 'An undated snapshotneedle.\n' > "$case_home/data/undated.md"
  touch -t 202407101200 "$case_home/data/dated.md" "$case_home/data/yearless.md" "$case_home/data/undated.md"
  case_run snapshotneedle >/dev/null || fail "source snapshot setup failed"
  real_grep=$(command -v grep)
  cat > "$case_home/bin/grep" <<'SH'
#!/usr/bin/env bash
"$PRIOR_ART_REAL_GREP" "$@"
rc=$?
if [ "${1:-}" = -E ]; then
  for name in dated yearless undated; do
    cat > "$FM_HOME/data/$name.md" <<'MD'
# Replacement 2030-01-02

This is unrelated replacement text.

A newer replacementword snapshotneedle.
MD
    touch -t 203107101200 "$FM_HOME/data/$name.md"
  done
  : > "$FM_HOME/mutated"
fi
exit "$rc"
SH
  chmod +x "$case_home/bin/grep"
  out=$(PATH="$case_home/bin:$PATH" PRIOR_ART_REAL_GREP="$real_grep" case_run snapshotneedle) || fail "lookup during record replacement failed: $out"
  [ -f "$case_home/mutated" ] || fail "the records were not replaced during the search"
  assert_contains "$out" "source: data/dated.md, line 3" "the original match must retain its source line"
  assert_contains "$out" "> La mémoire contient snapshotneedle." "the quotation must come from the matched text"
  assert_contains "$out" "2026-08-01  (dated section)" "the section date must come from the matched text"
  assert_contains "$out" "2024-09-06  (dated section, year inferred)" "inferred years must use the matched file date"
  assert_contains "$out" "2024-07-10  (file last changed" "undated matches must retain their file date"
  assert_not_contains "$out" "replacement" "live replacements must not supply quotations or dates"
  out=$(case_run replacementword) || fail "lookup after record replacement failed: $out"
  assert_contains "$out" "> A newer replacementword snapshotneedle." "the next question must see the edited records"
  assert_contains "$out" "2030-01-02  (dated section)" "the next question must use the edited date"
  pass "matches, quotations, and dates share the same saved source"
}


check_binary_records() {
  local case_home="$HOME_DIR/binary-records" out rc word
  mkdir -p "$case_home/data"
  printf 'An ordinary documentedword.\n' > "$case_home/data/report.md"
  printf 'A binaryword beside a zero byte: \000\n' > "$case_home/data/binary.md"
  for word in documentedword binaryword absentword; do
    out=$(case_run "$word")
    rc=$?
    [ "$rc" -ne 0 ] || fail "zero bytes must fail the search instead of establishing absence: $out"
    assert_contains "$out" "binary.md" "the unsupported source must be identified"
    assert_contains "$out" "zero byte" "the unsupported byte must be explained"
    assert_not_contains "$out" "FOUND NOWHERE" "unsupported records cannot establish absence"
    assert_not_contains "$out" "NOTHING FOUND" "unsupported records cannot establish empty results"
  done
  printf 'A repaired binaryword.\n' > "$case_home/data/binary.md"
  out=$(case_run documentedword) || fail "search after record repair failed: $out"
  assert_contains "$out" "source: data/report.md" "repairing unsupported content must restore the search"
  out=$(case_run binaryword) || fail "repaired record lookup failed: $out"
  assert_contains "$out" "> A repaired binaryword." "the repaired record must be read on the next question"
  pass "zero bytes cannot turn matching records into absence claims"
}

check_malformed_matches() {
  local case_home="$HOME_DIR/malformed-matches" out rc record
  mkdir -p "$case_home/data" "$case_home/bin"
  printf 'documentedword\n' > "$case_home/data/report.md"
  cat > "$case_home/bin/grep" <<'SH'
#!/usr/bin/env bash
printf '%s' "$PRIOR_ART_MATCH_OUTPUT"
exit 0
SH
  chmod +x "$case_home/bin/grep"
  for record in $'Binary file index matches\n' $'1\t0\tdocumentedword\n' \
    $'999\t1\tdocumentedword\n' $'1\t1\tdocumentedword\textra\n' \
    $'1\t1\tdocumentedword\nBinary file index matches\n' ''; do
    out=$(PATH="$case_home/bin:$PATH" PRIOR_ART_MATCH_OUTPUT="$record" case_run documentedword absentword)
    rc=$?
    [ "$rc" -ne 0 ] || fail "unreadable matching text must fail the search: $out"
    assert_contains "$out" "search could not be completed" "malformed matches must report an operational failure"
    assert_not_contains "$out" "FOUND NOWHERE" "malformed matches cannot establish absence"
    assert_not_contains "$out" "NOTHING FOUND" "malformed matches cannot establish empty results"
    assert_not_contains "$out" "source: data/" "valid fragments cannot rescue malformed search output"
  done
  pass "unreadable matching text fails before any answer is printed"
}

check_crlf_dates() {
  local case_home="$HOME_DIR/crlf-dates" out
  mkdir -p "$case_home/data"
  perl -pe 's/\n/\r\n/g' > "$case_home/data/report.md" <<'MD'
# Report
## Alpha 2026-08-01
```sh
# A comment
```
## Beta 2026-09-02
La mémoire crlfword.
~~~sh
# Another comment
~~~
## Gamma 2026-09-03
aftercrlftildeword
MD
  out=$(case_run crlfword) || fail "CRLF section lookup failed: $out"
  assert_contains "$out" "2026-09-02  (dated section)" "CRLF fences must close before the next dated section"
  assert_contains "$out" $'> La mémoire crlfword.\r' "the original quotation must retain its text and line ending"
  assert_not_contains "$out" "2026-08-01" "a previous section must not date a CRLF sibling"
  out=$(case_run aftercrlftildeword) || fail "CRLF tilde fence lookup failed: $out"
  assert_contains "$out" "2026-09-03  (dated section)" "CRLF tilde fences must also close"
  perl -pe 's/\n/\r\n/g' > "$case_home/data/header.md" <<'MD'
# Note
```text
Date: 1999-01-01
```
Date: 2025-07-10
crlfheaderword
MD
  out=$(case_run crlfheaderword) || fail "CRLF header lookup failed: $out"
  assert_contains "$out" "2025-07-10  (stated in the document)" "CRLF header dates must be parsed outside fences"
  pass "CRLF parsing preserves correct dates and original quotations"
}

check_indented_headings() {
  local case_home="$HOME_DIR/indented-headings" out indent
  mkdir -p "$case_home/data"
  for indent in ' ' '  ' '   '; do
    cat > "$case_home/data/report.md" <<MD
# Note
Date: 2025-07-10
## Alpha 2026-08-01
${indent}## Beta
indentedsiblingword
${indent}## Gamma 2026-09-02
${indent}### Nested
indentedchildword
    ## Not a heading 1999-01-01
####### Not a heading 1998-01-01
protectedheadingword
${indent}##
emptyheadingword
MD
    out=$(case_run indentedsiblingword) || fail "indented sibling lookup failed: $out"
    assert_contains "$out" "2025-07-10  (stated in the document)" "indented sibling headings must end earlier section dates"
    assert_contains "$out" "under: Beta" "heading indentation must not enter the heading text"
    out=$(case_run indentedchildword) || fail "indented child lookup failed: $out"
    assert_contains "$out" "2026-09-02  (dated section)" "indented nested sections must inherit the applicable date"
    out=$(case_run protectedheadingword) || fail "non-heading lookup failed: $out"
    assert_contains "$out" "2025-07-10  (stated in the document)" "indented content must use conservative document provenance"
    out=$(case_run emptyheadingword) || fail "empty heading lookup failed: $out"
    assert_contains "$out" "2025-07-10  (stated in the document)" "empty indented headings must also end a sibling section"
  done
  pass "Markdown heading indentation preserves section boundaries and dates"
}


assert_private_cache() {
  perl -MFile::Find -e '
    find({no_chdir => 1, wanted => sub {
      my @s = lstat $File::Find::name;
      my $want = -d _ ? 0700 : 0600;
      die sprintf("Wrong cache mode %04o: %s\n", $s[2] & 07777, $File::Find::name)
        if ($s[2] & 07777) != $want;
    }}, $ARGV[0]);
  ' "$1" || fail "cache permissions must remain owner-only"
}

check_cache_permissions() {
  local case_home="$HOME_DIR/cache-permissions" out source_before source_after
  mkdir -p "$case_home/data" "$case_home/state"
  chmod 755 "$case_home" "$case_home/state"
  printf 'Confidential privateword.\n' > "$case_home/data/report.md"
  chmod 600 "$case_home/data/report.md"
  source_before=$(perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$case_home/data/report.md")
  out=$(umask 022; case_run privateword) || fail "private record lookup failed: $out"
  assert_contains "$out" "source: data/report.md" "a private record must remain searchable"
  assert_private_cache "$case_home/state/prior-art"
  perl -MFile::Find -e '
    find({no_chdir => 1, wanted => sub {
      chmod(-d $File::Find::name ? 0755 : 0644, $File::Find::name) or die $!;
    }}, $ARGV[0]);
  ' "$case_home/state/prior-art" || fail "could not prepare permissive legacy cache"
  out=$(umask 022; case_run privateword) || fail "legacy cache reuse failed: $out"
  assert_contains "$out" "index reused" "permission repair must not require re-reading the records"
  assert_private_cache "$case_home/state/prior-art"
  source_after=$(perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$case_home/data/report.md")
  [ "$source_before" = "$source_after" ] || fail "cache protection must not change source permissions"
  [ "$(cat "$case_home/data/report.md")" = 'Confidential privateword.' ] || fail "source text must remain untouched"
  pass "cache creation and reuse enforce owner-only file and directory modes"
}

check_linked_records() {
  local case_home="$HOME_DIR/linked-records" out rc kind
  mkdir -p "$case_home/data" "$case_home/linked-directory"
  printf 'publicword\n' > "$case_home/data/public.md"
  printf 'linkedword\n' > "$case_home/target.md"
  printf 'linkedword\n' > "$case_home/linked-directory/report.md"
  for kind in file broken directory; do
    case "$kind" in
      file) ln -s "$case_home/target.md" "$case_home/data/report.md" ;;
      broken) ln -s "$case_home/missing.md" "$case_home/data/report.md" ;;
      directory) ln -s "$case_home/linked-directory" "$case_home/data/reports" ;;
    esac
    out=$(case_run linkedword)
    rc=$?
    [ "$rc" -ne 0 ] || fail "linked records must report incomplete coverage: $out"
    assert_contains "$out" "symbolic link; coverage is incomplete" "the skipped link must be explained"
    assert_contains "$out" "$case_home/data/" "the skipped source must be named"
    assert_not_contains "$out" "FOUND NOWHERE" "a skipped link cannot establish absence"
    assert_not_contains "$out" "NOTHING FOUND" "a skipped link cannot establish empty results"
    if [ "$kind" = directory ]; then unlink "$case_home/data/reports"; else unlink "$case_home/data/report.md"; fi
  done
  cp "$case_home/target.md" "$case_home/data/report.md"
  out=$(case_run linkedword) || fail "lookup after resolving the link failed: $out"
  assert_contains "$out" "source: data/report.md" "a regular replacement must restore coverage"
  [ "$(cat "$case_home/target.md")" = linkedword ] || fail "the target of a link must remain unchanged"
  pass "linked records and directories cannot produce false absence"
}

check_setext_dates() {
  local case_home="$HOME_DIR/setext-dates" out word
  mkdir -p "$case_home/data"
  cat > "$case_home/data/report.md" <<'MD'
# Notes
Date: 2025-07-10
## Alpha 2026-08-01

Betatitleword 2026-09-02
---
setextbodyword
### Nested ATX
setextnestedword

Undated sibling
---
setextsiblingword

New root
===
setextrootword
MD
  for word in setextbodyword Betatitleword setextnestedword; do
    out=$(case_run "$word") || fail "Setext lookup failed: $out"
    assert_contains "$out" "2026-09-02  (dated section)" "Setext headings must establish their own section date"
  done
  for word in setextsiblingword setextrootword; do
    out=$(case_run "$word") || fail "Setext boundary lookup failed: $out"
    assert_contains "$out" "2025-07-10  (stated in the document)" "Setext siblings and roots must end earlier dates"
  done
  perl -pe 's/\n/\r\n/g' > "$case_home/data/multiline.md" <<'MD'
# Notes















  Multilineheadingword
  continued title
  2026-10-03
  ---
multilinebodyword
~~~text
False 1999-01-01
===
~~~
aftersetextfenceword

---

afterruleword
MD
  for word in Multilineheadingword multilinebodyword aftersetextfenceword afterruleword; do
    out=$(case_run "$word") || fail "multiline Setext lookup failed: $out"
    assert_contains "$out" "2026-10-03  (dated section)" "multiline indented CRLF Setext headings must share the heading parser"
    assert_contains "$out" "under: Multilineheadingword continued title 2026-10-03" "fences and standalone rules must not replace the real heading"
  done
  out=$(case_run Multilineheadingword) || fail "Setext title quotation failed: $out"
  assert_contains "$out" $'>   Multilineheadingword\r' "a Setext heading quotation must retain its original text"
  pass "ATX and Setext headings share section, fence, and date handling"
}


check_query_separators() {
  local case_home="$HOME_DIR/query-separators" out word grouped separate
  mkdir -p "$case_home/data"
  cat > "$case_home/data/report.md" <<'MD'
L'agent avance d'abord aujourd'hui avec l’agent.
La mémoire de chaque agent compte.
Use C++ and agent[prod], agent\memoire or agent/memoire with foo&bar.
MD
  printf 'lagent dabord aujourdhui memoireagent\n' > "$case_home/data/joined.md"
  for word in "l'agent" "d'abord" "aujourd'hui" 'l’agent' 'C++' 'agent[prod]' 'agent\memoire' 'agent/memoire' 'foo&bar'; do
    out=$(case_run "$word") || fail "literal query failed: $out"
    assert_contains "$out" "source: data/report.md" "query separators must preserve literal matches"
    assert_not_contains "$out" "source: data/joined.md" "query separators must never disappear"
    assert_not_contains "$out" "FOUND NOWHERE" "an existing literal subject cannot be declared absent"
  done
  grouped=$(case_run 'mémoire agent') || fail "grouped query failed: $grouped"
  separate=$(case_run mémoire agent) || fail "separate query failed: $separate"
  assert_contains "$grouped" "ALREADY KNOWN ABOUT: memoire agent" "multiword arguments must keep word boundaries"
  [ "$(printf '%s\n' "$grouped" | sed -n '/source:/p')" = "$(printf '%s\n' "$separate" | sed -n '/source:/p')" ] || fail "grouped and separate words must find the same sources"
  out=$(case_run $'mémoire\tagent\nl\x27agent') || fail "whitespace query failed: $out"
  assert_contains "$out" "ALREADY KNOWN ABOUT: memoire agent l'agent" "all ASCII whitespace must separate words"
  for word in '???' $'agent\001memoire'; do
    out=$(case_run "$word")
    [ "$?" -ne 0 ] || fail "unsupported query input must be refused: $out"
    assert_not_contains "$out" "FOUND NOWHERE" "unsupported input cannot establish absence"
  done
  pass "literal separators and multiword queries preserve indexed spelling"
}

check_container_dates() {
  local case_home="$HOME_DIR/container-dates" out
  mkdir -p "$case_home/data"
  cat > "$case_home/data/report.md" <<'MD'
# Note
> ```text
> Date: 1999-01-01
> ```
Date: 2025-07-10
containerword
MD
  touch -t 202407101200 "$case_home/data/report.md"
  out=$(case_run containerword) || fail "container lookup failed: $out"
  assert_contains "$out" "2024-07-10  (file last changed" "container examples must degrade to a trusted file date"
  assert_not_contains "$out" "1999-01-01" "a quoted example must not date the document"
  assert_not_contains "$out" "dated section" "unsupported container context must not assert a section date"
  pass "container examples cannot supply authored dates"
}

check_uncertain_dates() {
  local case_home="$HOME_DIR/uncertain-dates" out variant metadata
  mkdir -p "$case_home/data"
  for metadata in 'Date: 2025-07-10' ''; do
    for variant in html list quote directive; do
      {
        printf '# Note\n%s\n## Known 2026-08-01\nknownbeforeword\n\n' "$metadata"
        case "$variant" in
          html) printf '<div>\n## Example 1999-01-01\nambiguousword\n</div>\n' ;;
          list) printf -- '- ```text\n  Date: 1999-01-01\n  ```\n  ambiguousword\n' ;;
          quote) printf '> > ```\n> > Date: 1999-01-01\n> > ```\nambiguousword\n' ;;
          directive) printf ':::example\n## Example 1999-01-01\nambiguousword\n:::\n' ;;
        esac
      } > "$case_home/data/report.md"
      touch -t 202407101200 "$case_home/data/report.md"
      out=$(case_run ambiguousword) || fail "ambiguous context lookup failed: $out"
      if [ -n "$metadata" ]; then
        assert_contains "$out" "2025-07-10  (stated in the document)" "uncertain sections must fall back to earlier trusted metadata"
      else
        assert_contains "$out" "2024-07-10  (file last changed" "uncertain sections without trusted metadata must use the file date"
      fi
      assert_not_contains "$out" "dated section" "uncertainty must never claim precise section provenance"
      assert_not_contains "$out" "1999-01-01" "unsupported examples must not provide a date"
      out=$(case_run knownbeforeword) || fail "earlier supported context lookup failed: $out"
      assert_contains "$out" "2026-08-01  (dated section)" "later uncertainty must not change an earlier known section"
    done
  done
  pass "uncertain block context consistently weakens date provenance"
}


check_mixed_indentation() {
  local case_home="$HOME_DIR/mixed-indentation" out indent metadata location
  mkdir -p "$case_home/data"
  for metadata in 'Date: 2025-07-10' ''; do
    for indent in $' \t' $'  \t' $'   \t' $'\t ' $'\t\t' '    '; do
      for location in title underline; do
        {
          printf '# Note\n%s\n\n## Earlier 2026-08-01\n\n' "$metadata"
          if [ "$location" = title ]; then
            printf '%sExample 1999-01-01\n---\n' "$indent"
          else
            printf 'Example 1999-01-01\n%s---\n' "$indent"
          fi
          printf 'mixedindentword\n'
        } > "$case_home/data/report.md"
        touch -t 202407101200 "$case_home/data/report.md"
        out=$(case_run mixedindentword) || fail "mixed indentation lookup failed: $out"
        if [ -n "$metadata" ]; then
          assert_contains "$out" "2025-07-10  (stated in the document)" "mixed indentation must fall back to the trusted document date"
        else
          assert_contains "$out" "2024-07-10  (file last changed" "mixed indentation without metadata must use the file date"
        fi
        assert_not_contains "$out" "1999-01-01" "indented examples must not supply dates"
        assert_not_contains "$out" "dated section" "uncertain indentation must not claim a section date"
      done
    done
  done
  printf '# Note\n## Known 2026-08-01\n```\n \tExample 1999-01-01\n \t```\n---\n```\nfencedindentword\n' > "$case_home/data/report.md"
  out=$(case_run fencedindentword) || fail "fenced indentation lookup failed: $out"
  assert_contains "$out" "2026-08-01  (dated section)" "indentation inside a known fence must remain code"
  pass "space and tab indentation cannot manufacture section dates"
}

check_quotation_prefixes() {
  local case_home="$HOME_DIR/quotation-prefixes" out line
  mkdir -p "$case_home/data"
  for line in '-10% marge nette pour signword' '+10% marge nette pour signword' \
    '>10% marge nette pour signword' '- -10% marge nette pour signword' \
    '> -10% marge nette pour signword' '* -10% marge nette pour signword' \
    '**-10%** marge nette pour signword' $' \t-10% marge nette pour signword\t\r'; do
    printf '# Note\nDate: 2025-07-10\n\n%s\n' "$line" > "$case_home/data/report.md"
    out=$(case_run signword) || fail "quotation prefix lookup failed: $out"
    assert_contains "$out" "   > $line" "quotations must preserve meaningful signs and source prefixes"
  done
  pass "quotations preserve numeric signs and original prefixes"
}

if [ -n "${FM_PRIOR_ART_TEST_CASE:-}" ]; then
  case "$FM_PRIOR_ART_TEST_CASE" in
    search-options) check_search_options ;;
    search-failure) check_search_failure ;;
    fenced-dates) check_fenced_dates ;;
    source-snapshot) check_source_snapshot ;;
    binary-records) check_binary_records ;;
    malformed-matches) check_malformed_matches ;;
    crlf-dates) check_crlf_dates ;;
    indented-headings) check_indented_headings ;;
    cache-permissions) check_cache_permissions ;;
    linked-records) check_linked_records ;;
    setext-dates) check_setext_dates ;;
    query-separators) check_query_separators ;;
    container-dates) check_container_dates ;;
    uncertain-dates) check_uncertain_dates ;;
    mixed-indentation) check_mixed_indentation ;;
    quotation-prefixes) check_quotation_prefixes ;;
    *) fail "unknown focused test case: $FM_PRIOR_ART_TEST_CASE" ;;
  esac
  exit 0
fi

# A report that states its own date in the header.
mkdir -p "$DATA/alpha-sujet"
cat > "$DATA/alpha-sujet/report.md" <<'MD'
# Etude sur la memoire des agents

Date : 2026-08-25. Auteur : un equipier.

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

touch -t 202407101200 "$DATA/learnings.md" "$DATA/beta-sujet/report.md" "$DATA/done-archive.md"

run() { FM_HOME="$HOME_DIR" "$TOOL" "$@" 2>&1; }

# --- dates ------------------------------------------------------------------

out=$(run --limit 9 memoire) || fail "lookup failed: $out"

assert_contains "$out" "2026-08-25" "the report's stated date must be reported"
assert_contains "$out" "stated in the document" "a header date must be labelled as stated"
archive_out=$(run club) || fail "archive lookup failed: $archive_out"
assert_contains "$archive_out" "2024-07-10  (file last changed" "list context must use the weaker file date"
assert_not_contains "$archive_out" "dated section" "uncertain archive structure must not claim a section date"
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
if [ "${1:-}" = -E ]; then
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

check_search_options
check_search_failure
check_fenced_dates
check_source_snapshot

check_binary_records
check_malformed_matches
check_crlf_dates
check_indented_headings

check_cache_permissions
check_linked_records
check_setext_dates

check_query_separators
check_container_dates
check_uncertain_dates

check_mixed_indentation

check_quotation_prefixes
