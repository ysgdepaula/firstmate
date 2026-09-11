#!/usr/bin/env bash
# fm-prior-art.sh - answer "what do we already know about this?" from this
# home's own records, before commissioning an investigation that would
# re-explore ground already covered.
#
# Every investigation costs tokens and machine time and leaves a report behind
# in data/<name>/report.md. Those reports accumulate, but nothing re-reads them
# before the next investigation is commissioned, so the same subject gets
# explored a second and a third time. This command is that missing read. It
# answers from records that already exist and commissions nothing.
#
# Usage:
#   fm-prior-art.sh <subject words>...
#   fm-prior-art.sh --limit 5 memoire lavish
#   fm-prior-art.sh --rebuild            rebuild the index and stop
#
# Options:
#   --limit N    how many documents to show (default 8)
#   --rebuild    discard the index and build it again, then stop
#   -h, --help   this help
#
# WHAT IT READS: every *.md under this home's data/ - the investigation
# reports, the instructions that commissioned them, the captain's notes, the
# learnings, the work queue and the archives. Nothing else.
#
# COST: no model call, ever. Reading these records must never cost more than
# the re-investigation it exists to prevent, so the work is done once and kept:
# a folded copy of the corpus lives under state/prior-art/ and is rebuilt only
# when a document actually changes. A normal answer costs a few hundred
# milliseconds and no tokens at all.
#
# PRIVACY: local files only, no network call of any kind. The only thing it
# writes is its own index, under this home's state/. These records hold
# strategy, clients and contact details, and none of it leaves this machine.
#
# DATES: every result carries a date and says where that date came from. A
# report describes what was true on the day it was written, so a fact handed
# back without its date reproduces the very mistake this command exists to
# prevent. Three sources, in this order of preference:
#
#   dated section           a dated heading at or above the passage that
#                           matched. This is what makes a 250 KB archive
#                           usable: the date belongs to the passage that
#                           matched, not to the whole file.
#   stated in the document  a date in the document's first 15 lines.
#   file last changed       the file's modification time, used only when the
#                           document dates nothing itself. This is NOT an
#                           authored date and is labelled so it can never be
#                           read as one.
#
# A yearless date such as "(06/09)" is a real convention in these records. Its
# year is completed from the file and the result is labelled "year inferred",
# never silently. Slash dates are read day/month/year, matching how these
# records are written; an out-of-range reading is rejected rather than guessed.
#
# HONEST ABOUT ITS GAPS: a word found in no document at all is named as found
# nowhere, because that is the most valuable answer this command can give - it
# means the ground really is new. A word too common to tell two documents apart
# is dropped from the ranking and named as dropped. When nothing matches, it
# says so and returns nothing, rather than offering something adjacent that
# would read like an answer.
#
# ACCENTS AND CASE: half of these records are written with accents and half
# without, so "memoire" and "mémoire" are one word here, as are "MEMOIRE" and
# "Memoire". Both the index and the query are folded by explicit byte
# substitution under LC_ALL=C, never by locale folding, so the same question
# gets the same answer on every machine.
#
# Environment:
#   FM_HOME   operational home whose data/ is read and whose state/ holds the
#             index.
set -euo pipefail

# Byte-deterministic throughout. Folding is done by explicit byte substitution
# rather than by asking the locale, so this answers identically everywhere.
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CACHE="$STATE/prior-art"
INDEX="$CACHE/index"
DOCS="$CACHE/docs"
MANIFEST="$CACHE/manifest"
ORIGINALS="$CACHE/originals"

LIMIT=8
REBUILD_ONLY=0
US=$'\037'
TAB=$'\t'

die() { printf 'fm-prior-art: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'; }

ARGS=("$@")
TERMS_RAW=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --rebuild) REBUILD_ONLY=1; shift ;;
    --limit) [ $# -ge 2 ] || die "--limit needs a number"; LIMIT=$2; shift 2 ;;
    --limit=*) LIMIT=${1#--limit=}; shift ;;
    --) shift; while [ $# -gt 0 ]; do TERMS_RAW+=("$1"); shift; done ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) TERMS_RAW+=("$1"); shift ;;
  esac
done

case "$LIMIT" in ''|*[!0-9]*) die "--limit needs a whole number, got: $LIMIT" ;; esac
[ "$LIMIT" -gt 0 ] || die "--limit needs to be at least 1"
# What was asked is checked before where it would be looked up, so a missing
# subject is reported as the usage mistake it is rather than as a broken home.
if [ "$REBUILD_ONLY" -eq 0 ] && [ ${#TERMS_RAW[@]} -eq 0 ]; then
  die "say what subject to look up (try --help)"
fi
[ -d "$DATA" ] || die "no records to read: $DATA does not exist"
command -v perl >/dev/null 2>&1 || die "perl is needed to build the index and is not on PATH"

# Fold the accented letters of a query word down to plain ASCII so it is spelled
# the way the index is. Literal byte replacement, correct in any locale, and the
# same table the index build uses.
fold_ascii() {
  local s=$1
  s=${s//à/a}; s=${s//á/a}; s=${s//â/a}; s=${s//ä/a}; s=${s//å/a}
  s=${s//À/a}; s=${s//Á/a}; s=${s//Â/a}; s=${s//Ä/a}; s=${s//Å/a}
  s=${s//ç/c}; s=${s//Ç/c}
  s=${s//è/e}; s=${s//é/e}; s=${s//ê/e}; s=${s//ë/e}
  s=${s//È/e}; s=${s//É/e}; s=${s//Ê/e}; s=${s//Ë/e}
  s=${s//ì/i}; s=${s//í/i}; s=${s//î/i}; s=${s//ï/i}
  s=${s//Ì/i}; s=${s//Í/i}; s=${s//Î/i}; s=${s//Ï/i}
  s=${s//ò/o}; s=${s//ó/o}; s=${s//ô/o}; s=${s//ö/o}
  s=${s//Ò/o}; s=${s//Ó/o}; s=${s//Ô/o}; s=${s//Ö/o}
  s=${s//ù/u}; s=${s//ú/u}; s=${s//û/u}; s=${s//ü/u}
  s=${s//Ù/u}; s=${s//Ú/u}; s=${s//Û/u}; s=${s//Ü/u}
  s=${s//ñ/n}; s=${s//Ñ/n}; s=${s//ÿ/y}
  printf '%s' "$s"
}

literal_regex() {
  local t=$1 out='' i c
  for (( i=0; i<${#t}; i++ )); do
    c=${t:i:1}
    case "$c" in
      '.'|'['|']'|'\'|'*'|'^'|'$'|'+'|'?'|'('|')'|'{'|'}'|'|') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# ---- the index --------------------------------------------------------------

# Every line of every document, lowercased and stripped of accents, so a query
# needs no accent alternatives and matching stays fast however the corpus grows.
# The fold is line for line, so a line number in the index is the same line
# number in the original document.
fold_program() {
  cat <<'PL'
use Time::HiRes ();
my %F = (
  "\xc3\xa0"=>"a","\xc3\xa1"=>"a","\xc3\xa2"=>"a","\xc3\xa4"=>"a","\xc3\xa5"=>"a",
  "\xc3\x80"=>"a","\xc3\x81"=>"a","\xc3\x82"=>"a","\xc3\x84"=>"a","\xc3\x85"=>"a",
  "\xc3\xa7"=>"c","\xc3\x87"=>"c",
  "\xc3\xa8"=>"e","\xc3\xa9"=>"e","\xc3\xaa"=>"e","\xc3\xab"=>"e",
  "\xc3\x88"=>"e","\xc3\x89"=>"e","\xc3\x8a"=>"e","\xc3\x8b"=>"e",
  "\xc3\xac"=>"i","\xc3\xad"=>"i","\xc3\xae"=>"i","\xc3\xaf"=>"i",
  "\xc3\x8c"=>"i","\xc3\x8d"=>"i","\xc3\x8e"=>"i","\xc3\x8f"=>"i",
  "\xc3\xb2"=>"o","\xc3\xb3"=>"o","\xc3\xb4"=>"o","\xc3\xb6"=>"o",
  "\xc3\x92"=>"o","\xc3\x93"=>"o","\xc3\x94"=>"o","\xc3\x96"=>"o",
  "\xc3\xb9"=>"u","\xc3\xba"=>"u","\xc3\xbb"=>"u","\xc3\xbc"=>"u",
  "\xc3\x99"=>"u","\xc3\x9a"=>"u","\xc3\x9b"=>"u","\xc3\x9c"=>"u",
  "\xc3\xb1"=>"n","\xc3\x91"=>"n","\xc3\xbf"=>"y",
);
# The list of documents is read here rather than handed over as arguments, so
# one process numbers every document. Splitting the work would restart the
# numbering and silently misattribute every line after the split.
open(my $list, "<", $ARGV[0]) or die "cannot read the document list: $!\n";
my $id = 0;
while (my $path = <$list>) {
  chomp $path;
  $id++;
  open(my $fh, "<", $path) or die "Not read: $path: $!\n";
  my @before = Time::HiRes::stat($fh);
  @before or die "Cannot date the source: $path: $!\n";
  open(my $original, ">", "$ARGV[1]/$id") or die "Cannot keep the source: $path: $!\n";
  my $n = 0;
  $! = 0;
  while (my $line = <$fh>) {
    $n++;
    die "Not read: $path: contains a zero byte; save it as plain text\n" if index($line, "\0") >= 0;
    print {$original} $line or die "Cannot keep the source: $path: $!\n";
    $line =~ s/\t/ /g;
    $line =~ s/(\xc3[\x80-\xbf])/exists $F{$1} ? $F{$1} : $1/ge;
    $line =~ tr/A-Z/a-z/;
    chomp $line;
    print "$id\t$n\t$line\n" or die "Cannot prepare the local search: $!\n";
  }
  die "Not read completely: $path: $!\n" if $!;
  my @after = Time::HiRes::stat($fh);
  @after or die "Cannot date the source: $path: $!\n";
  die "Source changed while being read: $path; try again\n"
    if join(":", @before[0,1,7,9,10]) ne join(":", @after[0,1,7,9,10]);
  close $fh or die "Not read completely: $path: $!\n";
  close $original or die "Cannot keep the source: $path: $!\n";
  utime $before[9], $before[9], "$ARGV[1]/$id" or die "Cannot keep the source date: $path: $!\n";
}
close STDOUT or die "Cannot prepare the local search: $!\n";
PL
}

umask 077
if [ "${FM_PRIOR_ART_LOCK_OWNER:-}" != "$$" ]; then
  [ ! -L "$CACHE" ] || die "cannot keep the local search private: $CACHE is a symbolic link"
  mkdir -p "$CACHE"
  chmod 700 "$CACHE"
  exec perl -MFcntl=:flock,:mode,F_SETFD -MFile::Find -e '
    my $cache = shift @ARGV;
    die "Cannot keep the local search private: $cache/lock is a symbolic link\n" if -l "$cache/lock";
    open(my $lock, ">>", "$cache/lock") or die "Cannot prepare the local search: $!\n";
    flock($lock, LOCK_EX) or die "Cannot wait for the local search: $!\n";
    find({no_chdir => 1, wanted => sub {
      my $path = $File::Find::name;
      my @s = lstat $path;
      @s or die "Cannot keep the local search private: $path: $!\n";
      die "Cannot keep the local search private: unsupported file $path\n"
        unless S_ISDIR($s[2]) || S_ISREG($s[2]);
      my $mode = S_ISDIR($s[2]) ? 0700 : 0600;
      chmod($mode, $path) or die "Cannot keep the local search private: $path: $!\n"
        if ($s[2] & 07777) != $mode;
    }}, $cache);
    fcntl($lock, F_SETFD, 0) or die "Cannot keep the local search protected: $!\n";
    $ENV{FM_PRIOR_ART_LOCK_OWNER} = $$;
    exec "bash", @ARGV;
    die "Cannot start the local search: $!\n";
  ' "$CACHE" "${BASH_SOURCE[0]}" "${ARGS[@]}"
fi

STAT_STYLE=bsd
case "$(stat --version 2>/dev/null || true)" in *GNU*) STAT_STYLE=gnu ;; esac
DATE_STYLE=bsd
case "$(date --version 2>/dev/null || true)" in *GNU*) DATE_STYLE=gnu ;; esac

TMPDIR_RUN=$(mktemp -d "$CACHE/run.XXXXXX")
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CORPUS="$TMPDIR_RUN/corpus"
WANT="$TMPDIR_RUN/manifest"
HITS="$TMPDIR_RUN/hits"
RANKED="$TMPDIR_RUN/ranked"
TOP="$TMPDIR_RUN/top"

find "$DATA" \( -type l -o \( -type f -name '*.md' \) \) -print0 > "$TMPDIR_RUN/all" \
  || die "not all records could be listed under $DATA; coverage is incomplete"
perl -0ne '
  chomp;
  die "Not read, ambiguous source name: $_\n" if /[\t\r\n]/;
  if (-l $_) {
    die "Not read: $_: symbolic link; coverage is incomplete\n" if /\.md$/ || -d $_ || !-e $_;
    next;
  }
  die "Not read: $_: permission denied\n" unless -r $_;
  print "$_\n";
' "$TMPDIR_RUN/all" | sort > "$CORPUS"

NDOCS=$(wc -l < "$CORPUS" | tr -d ' ')
[ "$NDOCS" -gt 0 ] || die "no records to read: found no documents under $DATA"

# The freshness test: what is on disk now, against what the index was built
# from. Cheap enough to run every time, which is what keeps the index honest
# without anyone having to remember to refresh it.
printf 'text-sources-1\n' > "$WANT"
if [ "$STAT_STYLE" = gnu ]; then
  tr '\n' '\0' < "$CORPUS" | xargs -0 stat -c '%y %z %s %i %a %n'
else
  tr '\n' '\0' < "$CORPUS" | xargs -0 stat -f '%.9Fm %.9Fc %z %i %p %N'
fi >> "$WANT"

build_index() {
  mkdir -p "$CACHE"
  fold_program > "$TMPDIR_RUN/fold.pl"
  mkdir "$TMPDIR_RUN/originals.new"
  perl "$TMPDIR_RUN/fold.pl" "$CORPUS" "$TMPDIR_RUN/originals.new" > "$TMPDIR_RUN/index.new"
  rm -f "$MANIFEST"
  rm -rf "$ORIGINALS"
  mv "$TMPDIR_RUN/originals.new" "$ORIGINALS"
  cp -f "$CORPUS" "$TMPDIR_RUN/docs.new"
  mv -f "$TMPDIR_RUN/docs.new" "$DOCS"
  mv -f "$TMPDIR_RUN/index.new" "$INDEX"
  cp -f "$WANT" "$TMPDIR_RUN/manifest.new"
  mv -f "$TMPDIR_RUN/manifest.new" "$MANIFEST"
}

INDEX_STATE=reused
if [ "$REBUILD_ONLY" -eq 1 ]; then
  rm -f "$INDEX" "$DOCS" "$MANIFEST"
fi
if [ ! -d "$ORIGINALS" ] || [ ! -s "$INDEX" ] || [ ! -s "$DOCS" ] || [ ! -s "$MANIFEST" ] || ! cmp -s "$WANT" "$MANIFEST"; then
  BUILD_START=$(date +%s)
  build_index
  BUILD_TOOK=$(( $(date +%s) - BUILD_START ))
  INDEX_STATE="rebuilt in ${BUILD_TOOK}s"
fi

if [ "$REBUILD_ONLY" -eq 1 ]; then
  printf 'Index %s: %s documents from %s\n' "$INDEX_STATE" "$NDOCS" "$DATA"
  exit 0
fi

# ---- the query --------------------------------------------------------------

NAMES=()
REGEXES=()
DROPPED_EMPTY=()
for raw in "${TERMS_RAW[@]}"; do
  # shellcheck disable=SC2018,SC2019
  clean=$(fold_ascii "$raw" | tr 'A-Z' 'a-z' | tr '[:space:]' ' ')
  if [[ "$clean" =~ [[:cntrl:]] ]]; then die "the subject contains unsupported control bytes"; fi
  WORDS=()
  IFS=' ' read -r -a WORDS <<< "$clean"
  if [ ${#WORDS[@]} -eq 0 ]; then DROPPED_EMPTY+=("$raw"); continue; fi
  for word in "${WORDS[@]}"; do
    case "$word" in *[a-z0-9]*) ;; *) die "nothing searchable in subject: $word" ;; esac
    already=0
    for seen in ${NAMES[@]+"${NAMES[@]}"}; do
      if [ "$seen" = "$word" ]; then already=1; break; fi
    done
    [ "$already" -eq 1 ] && continue
    NAMES+=("$word")
    REGEXES+=("(^|[^a-z0-9])$(literal_regex "$word")")
  done
done
[ ${#NAMES[@]} -gt 0 ] || die "nothing searchable in that subject: give at least one word with letters or digits"

# The prefilter is deliberately wider than the real rule: plain words, no word
# boundary. A boundary in this pattern costs stock grep about half its speed on
# a corpus this size, and buys nothing, because the scoring pass below applies
# the exact rule to the text column anyway. Wider is safe here; narrower would
# silently lose documents.
COMBINED=""
for name in "${NAMES[@]}"; do
  [ -n "$COMBINED" ] && COMBINED+="|"
  COMBINED+="$(literal_regex "$name")"
done

START=$(date +%s)
# grep only narrows; the scoring below re-checks every hit against the text
# column alone, so a word that happens to occur in a file's path can never be
# counted as something the document says.
search_status=0
grep -E -e "$COMBINED" "$INDEX" > "$HITS" 2> "$TMPDIR_RUN/search-error" || search_status=$?
case "$search_status" in
  0) [ -s "$HITS" ] || die "search could not be completed: matching text was missing" ;;
  1) [ ! -s "$HITS" ] || die "search could not be completed: unexpected matching text" ;;
  *) die "search could not be completed (exit $search_status); no answer was produced" ;;
esac

TERMRE=$(printf '%s\n' "${REGEXES[@]}" | paste -sd "$US" -)
TERMNAME=$(printf '%s\n' "${NAMES[@]}" | paste -sd "$US" -)

# Rarer words weigh more. That is what makes the boilerplate shared by every
# set of commissioning instructions weigh nothing: a word in nearly every
# document cannot tell one document from another.
TERMRE="$TERMRE" TERMNAME="$TERMNAME" awk -F"$TAB" -v NDOCS="$NDOCS" -v DOCS="$DOCS" '
function search_failed() {
  print "fm-prior-art: search could not be completed: unreadable matching text; no answer was produced" > "/dev/stderr"
  invalid = 1
  exit 1
}
function count_matches(s, re,   n) {
  n = 0
  while (match(s, re)) { n++; if (RLENGTH <= 0) break; s = substr(s, RSTART + RLENGTH) }
  return n
}
BEGIN {
  nt = split(ENVIRON["TERMRE"], RE, "\037"); split(ENVIRON["TERMNAME"], TN, "\037")
  while ((readstatus = getline line < DOCS) > 0) { docpath[++nd] = line }
  if (readstatus < 0 || nd != NDOCS) search_failed()
  close(DOCS)
}
{
  if (NF != 3 || $1 !~ /^[1-9][0-9]*$/ || $2 !~ /^[1-9][0-9]*$/) search_failed()
  path = docpath[$1 + 0]; lno = $2 + 0; text = $3
  if (path == "") search_failed()
  here = 0
  for (i = 1; i <= nt; i++) {
    c = count_matches(text, RE[i])
    if (c > 0) {
      tf[path, i] += c
      if (!((path, i) in seen)) { seen[path, i] = 1; df[i]++ }
      here++; linecount[NR, i] = c
    }
  }
  if (here == 0) next
  files[path] = $1 + 0
  linepath[NR] = path; linenumber[NR] = lno
}
END {
  if (invalid) exit 1
  anyused = 0
  for (i = 1; i <= nt; i++) {
    if (df[i] == 0)               state[i] = "nowhere"
    else if (df[i] / NDOCS > 0.6) state[i] = "common"
    else                        { state[i] = "used"; anyused = 1 }
  }
  # The whole subject turned out to be boilerplate. Rank on it anyway rather
  # than returning nothing, and say plainly that the subject is not specific.
  if (!anyused)
    for (i = 1; i <= nt; i++) if (state[i] == "common") { state[i] = "used-weak"; anyused = 1 }
  for (i = 1; i <= nt; i++) printf "T\t%s\t%d\t%s\n", TN[i], df[i] + 0, state[i]
  for (ln = 1; ln <= NR; ln++) {
    path = linepath[ln]
    if (path == "") continue
    here = 0; dense = 0
    for (i = 1; i <= nt; i++) {
      if (state[i] != "used" && state[i] != "used-weak") continue
      c = linecount[ln, i] + 0
      if (c > 0) { here++; dense += c }
    }
    if (here > bestn[path] || (here == bestn[path] && dense > bestd[path])) {
      bestn[path] = here; bestd[path] = dense; bestline[path] = linenumber[ln]
    }
  }
  for (path in files) {
    s = 0; cov = 0; sum = ""
    for (i = 1; i <= nt; i++) {
      if (state[i] != "used" && state[i] != "used-weak") continue
      c = tf[path, i] + 0
      if (c <= 0) continue
      cov++
      idf = log(NDOCS / df[i]); if (idf < 0.05) idf = 0.05
      s += (1 + log(c)) * idf
      sum = sum (sum == "" ? "" : ", ") TN[i] " (" c ")"
    }
    if (cov == 0) continue
    printf "D\t%.4f\t%d\t%s\t%d\t%d\t%s\n", s, cov, path, bestline[path], files[path], sum
  }
}
' "$HITS" > "$RANKED"

# Read a ranked document just far enough to date the passage that matched, and
# to quote it as it was actually written rather than as the index folded it.
describe() {  # <path> <best line number> <fallback year>
  awk -v BEST="$2" -v YEAR="$3" '
  function finddate(s, allowbare,   t, a, y, m, d, before, after) {
    if (match(s, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
      t = substr(s, RSTART, RLENGTH)
      y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) return sprintf("%04d-%02d-%02d\tfull", y, m, d)
    }
    if (match(s, /[0-9][0-9]?\/[0-9][0-9]?\/[0-9][0-9][0-9][0-9]/)) {
      t = substr(s, RSTART, RLENGTH); split(t, a, "/")
      d = a[1] + 0; m = a[2] + 0; y = a[3] + 0
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) return sprintf("%04d-%02d-%02d\tfull", y, m, d)
    }
    if (allowbare && match(s, /[0-9][0-9]?\/[0-9][0-9]?/)) {
      t = substr(s, RSTART, RLENGTH)
      before = (RSTART > 1) ? substr(s, RSTART - 1, 1) : " "
      after = substr(s, RSTART + RLENGTH, 1)
      if (before != "/" && after != "/" && before !~ /[0-9]/ && after !~ /[0-9]/) {
        split(t, a, "/"); d = a[1] + 0; m = a[2] + 0
        if (m >= 1 && m <= 12 && d >= 1 && d <= 31)
          return sprintf("%04d-%02d-%02d\tinferred", YEAR, m, d)
      }
    }
    return ""
  }
  function section(level, title, first,   depth) {
    headings++
    if (level > 1 || headings > 1) insection = 1
    if (first <= BEST) {
      heading = title
      for (depth in dates) if (depth >= level) delete dates[depth]
      dates[level] = finddate(title, 1)
      hdate = ""
      for (depth = 1; depth <= level; depth++)
        if (dates[depth] != "") hdate = dates[depth]
    }
  }
  function document_date(s) {
    if (s ~ /^ ? ? ?[Dd][Aa][Tt][Ee][ \t]*:/) return finddate(s, 0)
    return ""
  }
  function endparagraph(astext) {
    if (astext && !insection && hdrdate == "") hdrdate = paragraphdate
    paragraph = ""; paragraphdate = ""; firstline = 0
  }
  function markdown(s, n,   prefix, rest, level, title) {
    sub(/\r$/, "", s)
    if (uncertain_at) return
    if (fencechar == "" &&
        (s ~ /^ ? ? ?(>|[-+*]([ \t]+|$)|[0-9]+[.)][ \t]+)/ ||
         s ~ /^ ? ? ?(<|\[|!\[|:::+|\\)/ ||
         (n == 1 && s ~ /^(---|[+][+][+])[ \t]*$/))) {
      endparagraph(1)
      uncertain_at = n
      return
    }
    if (match(s, /^ ? ? ?(```+|~~~+)/)) {
      prefix = substr(s, 1, RLENGTH)
      sub(/^ +/, "", prefix)
      rest = substr(s, RLENGTH + 1)
      if (fencechar != "") {
        if (substr(prefix, 1, 1) == fencechar && length(prefix) >= fencelen && rest ~ /^[ \t]*$/)
          fencechar = ""
        return
      }
      if (substr(prefix, 1, 1) != "`" || rest !~ /`/) {
        endparagraph(1)
        fencechar = substr(prefix, 1, 1); fencelen = length(prefix)
        return
      }
    }
    if (fencechar != "") return
    if (match(s, /^ ? ? ?#+([ \t]+|$)/)) {
      title = substr(s, RLENGTH + 1)
      prefix = substr(s, 1, RLENGTH)
      gsub(/[ \t]/, "", prefix)
      level = length(prefix)
      if (level <= 6) {
        sub(/[ \t]+#+[ \t]*$/, "", title)
        endparagraph(1)
        section(level, title, n)
        return
      }
    }
    if (firstline && s ~ /^ ? ? ?(=+|-+)[ \t]*$/) {
      prefix = s; sub(/^ +/, "", prefix)
      section(substr(prefix, 1, 1) == "=" ? 1 : 2, paragraph, firstline)
      endparagraph(0)
      return
    }
    if (!firstline && (s ~ /^    / || s ~ /^\t/)) return
    prefix = s; gsub(/[ \t]/, "", prefix)
    if (s ~ /^[ \t]*$/ || prefix ~ /^---+$/ || prefix ~ /^\*\*\*+$/ || prefix ~ /^___+$/) {
      endparagraph(1)
      if (!insection && n <= 15 && hdrdate == "") hdrdate = document_date(s)
      return
    }
    if (!firstline) firstline = n
    title = s; sub(/^ +/, "", title); sub(/[ \t]+$/, "", title)
    paragraph = paragraph (paragraph == "" ? "" : " ") title
    if (n <= 15 && paragraphdate == "") paragraphdate = document_date(s)
  }
  NR > BEST && NR > 15 && !firstline { exit }
  {
    if (NR == BEST) quote = $0
    markdown($0, NR)
  }
  END {
    endparagraph(1)
    if (uncertain_at && uncertain_at <= BEST) { hdate = ""; heading = "" }
    gsub(/\t/, " ", heading); gsub(/\t/, " ", quote)
    sub(/^[ \t>*+-]+/, "", quote)
    print heading; print hdate; print hdrdate; print quote
  }
  ' "$1"
}

mtime_epoch() {
  if [ "$STAT_STYLE" = gnu ]; then stat -c '%Y' "$1"; else stat -f '%m' "$1"; fi
}
epoch_date() {
  if [ "$DATE_STYLE" = gnu ]; then date -d "@$1" "+$2"; else date -r "$1" "+$2"; fi
}

kind_of() {  # <path relative to data/>
  case "$1" in
    captain.md|captain-shared.md)    printf "the captain's notes" ;;
    learnings.md)                    printf 'a learning' ;;
    backlog.md)                      printf 'the work queue' ;;
    done-archive.md|note-archive.md) printf 'the archive' ;;
    */report.md)                     printf 'an investigation' ;;
    */brief.md|*/launch-brief.md)    printf 'instructions that were given' ;;
    *)                               printf 'a note' ;;
  esac
}

subject_of() {  # <path relative to data/>
  case "$1" in
    */*) printf '%s' "${1%%/*}" ;;
    *)   printf '%s' "${1%.md}" ;;
  esac
}

# ---- the answer -------------------------------------------------------------

printf 'ALREADY KNOWN ABOUT: %s\n' "${NAMES[*]}"
printf 'Looked through %s documents in this home. Nothing was sent anywhere.\n' "$NDOCS"

if [ ${#DROPPED_EMPTY[@]} -gt 0 ]; then
  printf '\nIgnored, nothing searchable in it: %s\n' "${DROPPED_EMPTY[*]}"
fi

NOWHERE=$(awk -F"$TAB" '$1=="T" && $4=="nowhere" {print $2}' "$RANKED" | paste -sd ',' - | sed 's/,/, /g')
COMMON=$(awk -F"$TAB" -v n="$NDOCS" '$1=="T" && $4=="common" {printf "%s (in %s of the %s documents)\n", $2, $3, n}' "$RANKED")
WEAK=$(awk -F"$TAB" '$1=="T" && $4=="used-weak" {print $2}' "$RANKED" | paste -sd ',' - | sed 's/,/, /g')

if [ -n "$NOWHERE" ]; then
  printf '\nFOUND NOWHERE: %s\n' "$NOWHERE"
  printf '  No document in this home mentions it. On that word this is new ground.\n'
fi
if [ -n "$COMMON" ]; then
  printf '\nTOO COMMON TO RANK ON, SET ASIDE:\n'
  printf '%s\n' "$COMMON" | sed 's|^|  |'
  printf '  A word in most documents cannot tell one from another; the ranking below\n'
  printf '  uses the rest of the subject.\n'
fi
if [ -n "$WEAK" ]; then
  printf '\nEVERY WORD OF THIS SUBJECT IS IN MOST DOCUMENTS: %s\n' "$WEAK"
  printf '  The ranking below is weak. Narrow the subject to get a usable answer.\n'
fi

awk -F"$TAB" '$1=="D"' "$RANKED" | sort -t"$TAB" -k3,3nr -k2,2nr > "$TOP"
NHITS=$(wc -l < "$TOP" | tr -d ' ')

if [ "$NHITS" -eq 0 ]; then
  printf '\nNOTHING FOUND.\n'
  printf '  No document in this home covers this subject. Nothing is being guessed\n'
  printf '  at and nothing adjacent is being offered instead: as far as these\n'
  printf '  records go, this has not been looked into.\n'
  printf '\nLooked through %s documents in %ss (index %s). No model was called.\n' \
    "$NDOCS" "$(( $(date +%s) - START ))" "$INDEX_STATE"
  exit 0
fi

printf '\n'
RANK=0
while IFS="$TAB" read -r _ _ cov path bestline docid summary; do
  RANK=$(( RANK + 1 ))
  [ "$RANK" -le "$LIMIT" ] || break
  rel=${path#"$DATA"/}
  original="$ORIGINALS/$docid"
  mt=$(mtime_epoch "$original")
  describe "$original" "$bestline" "$(epoch_date "$mt" %Y)" > "$TMPDIR_RUN/description"
  { read -r heading; read -r hdate; read -r hdrdate; read -r quote; } < "$TMPDIR_RUN/description"

  if [ -n "$hdate" ]; then
    when=${hdate%%"$TAB"*}
    if [ "${hdate##*"$TAB"}" = inferred ]; then origin='dated section, year inferred'; else origin='dated section'; fi
  elif [ -n "$hdrdate" ]; then
    when=${hdrdate%%"$TAB"*}; origin='stated in the document'
  else
    when=$(epoch_date "$mt" %Y-%m-%d); origin='file last changed, NOT an authored date'
  fi

  printf '%d. %s - %s\n' "$RANK" "$(subject_of "$rel")" "$(kind_of "$rel")"
  printf '   %s  (%s)\n' "$when" "$origin"
  printf '   source: data/%s, line %s\n' "$rel" "$bestline"
  printf '   found: %s   covers %s of %s words\n' "$summary" "$cov" "${#NAMES[@]}"
  [ -n "$heading" ] && printf '   under: %s\n' "$(printf '%s' "$heading" | cut -c1-110)"
  printf '   > %s\n\n' "$(printf '%s' "$quote" | cut -c1-200)"
done < "$TOP"

if [ "$NHITS" -gt "$LIMIT" ]; then
  printf '%s more documents matched and are not shown. Raise --limit to see them.\n\n' "$(( NHITS - LIMIT ))"
fi
printf 'Looked through %s documents in %ss (index %s). No model was called.\n' \
  "$NDOCS" "$(( $(date +%s) - START ))" "$INDEX_STATE"
printf 'Read what is above before commissioning new work on this subject.\n'
