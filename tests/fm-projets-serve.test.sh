#!/usr/bin/env bash
# Behavior tests for the base's stable front door (bin/fm-projets-serve.py and
# bin/fm-projets-serve.sh): the index measures every entry with a real request,
# the projets page redirects to Lavish or warns that answers cannot be sent,
# index probes share a deadline, shared GET streams and HEAD reports metadata,
# and the launchd user agent is installed, started, stopped and removed through
# the operator commands without touching the shared repository.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVE="$ROOT/bin/fm-projets-serve.sh"
SERVER="$ROOT/bin/fm-projets-serve.py"
TMP_ROOT=$(fm_test_tmproot fm-projets-serve)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

touch "$TMP_ROOT/pids"
stop_servers() {
  local pid i
  while IFS= read -r pid; do kill "$pid" 2>/dev/null || true; done < "$TMP_ROOT/pids"
  while IFS= read -r pid; do
    wait "$pid" 2>/dev/null || true
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
      sleep 0.05
      i=$((i + 1))
    done
  done < "$TMP_ROOT/pids"
}
cleanup() {
  stop_servers
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/.lavish" "$home/share/docs"
  printf 'bonjour\n' > "$home/share/docs/lisez-moi.txt"
  printf 'secret\n' > "$home/share/secret.txt"
  fakebin=$(fm_fakebin "$home")
  # lavish-axi's own listing: one review still open, one ended
  cat > "$fakebin/lavish-axi" <<'SH'
#!/bin/sh
printf '%s\n' 'bin: /usr/local/bin/lavish-axi
sessions[2]{file,status,url,pending_prompts}:
  /tmp/a/revue-alex.html,open,"http://127.0.0.1:9/session/aaaa",0
  /tmp/b/finie.html,ended,"http://127.0.0.1:9/session/bbbb",0'
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# Start a plain static server on a free loopback port and print its port.
start_dummy() {  # <home> <dir>
  local home=$1 dir=$2 i=0 port=""
  python3 -u - "$dir" > "$home/dummy.log" 2>&1 <<'PYDUMMY' &
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import sys, time
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=sys.argv[1], **kwargs)
    def do_GET(self):
        if self.path.startswith("/slow"):
            print("probe-start", flush=True)
            time.sleep(1)
        super().do_GET()
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print("port %d" % server.server_address[1], flush=True)
server.serve_forever()
PYDUMMY
  printf '%s\n' "$!" >> "$TMP_ROOT/pids"
  while [ "$i" -lt 100 ]; do
    port=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$home/dummy.log" | head -1)
    [ -n "$port" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$port" ] || fail "the dummy service never announced its port"
  printf '%s\n' "$port"
}

# Start the front door bound to loopback on a free port and print its base URL.
start_front_door() {  # <home>
  local home=$1 i=0 url=""
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_PROJETS_SERVE_BIND=127.0.0.1 FM_PROJETS_SERVE_PORT=0 \
    FM_PROJETS_SERVE_PROBE_TIMEOUT=${FM_PROJETS_SERVE_PROBE_TIMEOUT:-1} python3 "$SERVER" > "$home/serve.log" 2>&1 &
  printf '%s\n' "$!" >> "$TMP_ROOT/pids"
  while [ "$i" -lt 100 ]; do
    url=$(sed -n 's/^listening: \(http:\/\/[^ ]*\).*/\1/p' "$home/serve.log" | head -1)
    [ -n "$url" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$url" ] || fail "the front door never announced its address: $(cat "$home/serve.log")"
  printf '%s\n' "$url"
}

index_lines() {  # <base-url> -> "<state> | <label>" per entry
  curl -s "$1" | python3 -c '
import re, sys, html
for m in re.finditer(r"<li class=\"(ok|ko)\"><span class=\"state\">([^<]*)</span> <a href=\"([^\"]*)\">([^<]*)</a>", sys.stdin.read()):
    print(html.unescape(m.group(2)) + " | " + html.unescape(m.group(4)) + " | " + html.unescape(m.group(3)))
'
}

test_index_measures_every_entry_with_a_real_request() {
  local home dport base out
  home=$(make_home index)
  dport=$(start_dummy "$home" "$home/share")
  cat > "$home/config/projets-serve.json" <<EOF
{"schema": "fm-projets-serve.v1", "port": 4390, "host": "base.test",
 "entries": [{"label": "Démo qui répond", "url": "http://127.0.0.1:$dport/"}, {"label": "Démo éteinte", "url": "http://127.0.0.1:9/"}],
 "folders": [{"label": "Docs partagés", "path": "$home/share/docs"}, {"label": "Dossier disparu", "path": "$home/share/absent"}]}
EOF
  base=$(start_front_door "$home")
  out=$(index_lines "$base")
  assert_contains "$out" "ne répond pas | La page projets | http://127.0.0.1:" "the page line is not measured before the page exists: $out"
  assert_contains "$out" "ne répond pas | Revue Lavish : revue-alex | http://127.0.0.1:9/session/aaaa" "an open Lavish review with a dead address is not reported as such: $out"
  assert_not_contains "$out" "finie" "an ended Lavish review was listed: $out"
  assert_contains "$out" "répond | Démo qui répond | http://127.0.0.1:$dport/" "a live declared service is not measured as answering: $out"
  assert_contains "$out" "ne répond pas | Démo éteinte | http://127.0.0.1:9/" "a dead declared service is not measured as silent: $out"
  assert_contains "$out" "répond | Dossier : Docs partagés | ${base}fichiers/docs-partag-s/" "an existing shared folder is not listed as answering: $out"
  assert_contains "$out" "ne répond pas | Dossier : Dossier disparu" "a missing shared folder is not reported: $out"
  curl -s "$base" | grep -q "réseau privé de Yan (tailnet)" || fail "the index does not state the tailnet limit"
  pass "the index measures the page, the open Lavish reviews, the declared services and the folders with real requests"
}

test_the_page_is_read_fresh_at_a_stable_address() {
  local home base code
  home=$(make_home page)
  printf '{"schema": "fm-projets-serve.v1", "port": 4390, "host": "base.test"}\n' > "$home/config/projets-serve.json"
  base=$(start_front_door "$home")
  code=$(curl -s -o /dev/null -w '%{http_code}' "${base}projets")
  [ "$code" = 404 ] || fail "a missing page did not answer 404: $code"
  printf '<!doctype html><title>v1</title>première version\n' > "$home/.lavish/projets.html"
  curl -s "${base}projets" | grep -q "première version" || fail "the page is not served"
  printf '<!doctype html><title>v2</title>seconde version\n' > "$home/.lavish/projets.html"
  curl -s "${base}projets" | grep -q "seconde version" || fail "a rebuild in place did not change the served content"
  curl -s -D - -o /dev/null "${base}projets" | grep -qi 'cache-control: no-store' || fail "the page is served with caching"
  index_lines "$base" | grep -q "^répond | La page projets" || fail "the index does not report the page as answering once it exists"
  pass "the page is read fresh at every request behind one stable address"
}

test_folders_are_served_read_only_and_confined() {
  local home base code
  home=$(make_home folders)
  cat > "$home/config/projets-serve.json" <<EOF
{"schema": "fm-projets-serve.v1", "port": 4390, "host": "base.test", "folders": [{"id": "docs", "label": "Docs", "path": "$home/share/docs"}]}
EOF
  base=$(start_front_door "$home")
  curl -s "${base}fichiers/docs/" | grep -q 'lisez-moi.txt' || fail "the folder listing does not show its file"
  [ "$(curl -s "${base}fichiers/docs/lisez-moi.txt")" = "bonjour" ] || fail "the file content is not served"
  code=$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "${base}fichiers/docs/../secret.txt")
  [ "$code" = 403 ] || [ "$code" = 404 ] || fail "a path outside the folder was served: $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' "${base}fichiers/docs/%2e%2e/secret.txt")
  [ "$code" = 403 ] || [ "$code" = 404 ] || fail "an encoded path outside the folder was served: $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' "${base}fichiers/inconnu/")
  [ "$code" = 404 ] || fail "an undeclared folder answered $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${base}fichiers/docs/lisez-moi.txt")
  [ "$code" = 501 ] || fail "a write method was accepted: $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' "${base}nulle-part")
  [ "$code" = 404 ] || fail "an unknown path answered $code"
  pass "declared folders are served read-only and confined to their directory"
}

test_lavish_redirect_and_fallback() {
  local home base port out
  home=$(make_home bridge)
  port=$(start_dummy "$home" "$home/share")
  printf '<!doctype html><html><body><button data-choice="oui">oui</button><ul class="you"><li><span class="ok"></span></li></ul></body></html>' > "$home/.lavish/projets.html"
  cat > "$home/fakebin/lavish-axi" <<EOF
#!/bin/sh
printf '%s\\n' 'sessions[3]{file,status,url,pending_prompts}:
  $home/.lavish/projets.html,ended,"http://127.0.0.1:9/ended",0
  $home/other/projets.html,open,"http://127.0.0.1:9/wrong",0
  $home/.lavish/projets.html,feedback,"http://127.0.0.1:$port/",1'
EOF
  base=$(start_front_door "$home")
  python3 - "$base" "$port" <<'PYHTTP'
import http.client, sys, urllib.parse
base = urllib.parse.urlsplit(sys.argv[1])
conn = http.client.HTTPConnection(base.hostname, base.port, timeout=3)
conn.request("GET", "/projets")
response = conn.getresponse()
assert response.status == 302, response.status
assert response.getheader("Location") == "http://127.0.0.1:%s/" % sys.argv[2]
assert response.getheader("Cache-Control") == "no-store"
assert response.read() == b""
conn.close()
PYHTTP
  curl -fsS "$base" | grep -q 'réponses transmises par Lavish' || fail "the index lost the session state"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/lavish-axi"
  out=$(curl -fsS "${base}projets") || fail "the absent session did not fall back to the page"
  assert_contains "$out" 'Ici les boutons ne transmettent rien' "the fallback warning is missing"
  curl -fsS "$base" | grep -q 'boutons non transmis' || fail "the index did not disclose fallback"
  pass "the stable page redirects only to its active Lavish session and discloses unavailable delivery"
}

test_unreadable_content_does_not_answer() {
  local home base out code
  home=$(make_home unreadable)
  printf '<html><body>page</body></html>' > "$home/.lavish/projets.html"
  printf '{"schema":"fm-projets-serve.v1","folders":[{"id":"docs","label":"Docs","path":"%s/share/docs"}]}' "$home" > "$home/config/projets-serve.json"
  base=$(start_front_door "$home")
  chmod 000 "$home/.lavish/projets.html" "$home/share/docs"
  out=$(index_lines "$base")
  code=$(curl -s -o /dev/null -w '%{http_code}' "${base}projets")
  chmod 644 "$home/.lavish/projets.html"
  chmod 755 "$home/share/docs"
  [ "$code" = 500 ] || fail "the unreadable page did not answer 500: $code"
  assert_contains "$out" 'ne répond pas | La page projets' "an unreadable page was reported as answering"
  assert_contains "$out" 'ne répond pas | Dossier : Docs' "an unreadable folder was reported as answering"
  pass "unreadable content produces HTTP errors and measured unavailable states"
}

test_index_probes_share_a_budget() {
  local home port base count
  home=$(make_home budget)
  port=$(start_dummy "$home" "$home/share")
  python3 - "$home" "$port" <<'PYCONFIG'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
entries = [{"label": "Démo lente %d" % i, "url": "http://127.0.0.1:%s/slow%d" % (sys.argv[2], i)} for i in range(12)]
(home / "config/projets-serve.json").write_text(json.dumps({"schema": "fm-projets-serve.v1", "entries": entries}))
PYCONFIG
  base=$(FM_PROJETS_SERVE_LAVISH="$home/unavailable-lavish" FM_PROJETS_SERVE_INDEX_BUDGET=0.5 FM_PROJETS_SERVE_PROBE_TIMEOUT=2 start_front_door "$home")
  python3 - "$base" <<'PYBUDGET'
from html.parser import HTMLParser
import sys, time, urllib.request
class States(HTMLParser):
    active = False
    states = []
    def handle_starttag(self, tag, attrs):
        self.active = tag == "span" and dict(attrs).get("class") == "state"
    def handle_data(self, data):
        if self.active:
            self.states.append(data)
start = time.monotonic()
with urllib.request.urlopen(sys.argv[1], timeout=2) as response:
    page = response.read().decode()
elapsed = time.monotonic() - start
assert elapsed < 1, elapsed
result = States()
result.feed(page)
assert "mesure inachevée" in result.states, result.states
assert "répond" not in result.states, result.states
PYBUDGET
  count=$(grep -c '^probe-start$' "$home/dummy.log")
  [ "$count" -gt 1 ] && [ "$count" -le 8 ] || fail "probe concurrency outside 2..8: $count"
  pass "index probes run concurrently within one response budget and disclose unfinished measurements"
}

test_shared_file_head_and_stream() {
  local home base
  home=$(make_home stream)
  printf '{"schema":"fm-projets-serve.v1","folders":[{"id":"docs","label":"Docs","path":"%s/share/docs"}]}' "$home" > "$home/config/projets-serve.json"
  base=$(start_front_door "$home")
  python3 - "$home" "$base" <<'PYSTREAM'
import hashlib, http.client, pathlib, sys, urllib.parse
path = pathlib.Path(sys.argv[1]) / "share/docs/film.bin"
with path.open("wb") as stream:
    stream.truncate(1024 ** 3)
base = urllib.parse.urlsplit(sys.argv[2])
conn = http.client.HTTPConnection(base.hostname, base.port, timeout=3)
conn.request("HEAD", "/fichiers/docs/film.bin")
response = conn.getresponse()
assert response.status == 200, response.status
assert int(response.getheader("Content-Length")) == path.stat().st_size
assert response.getheader("Content-Type") == "application/octet-stream"
assert response.read() == b""
conn.close()
content = bytes(range(256)) * 4096
path.write_bytes(content)
conn = http.client.HTTPConnection(base.hostname, base.port, timeout=3)
conn.request("GET", "/fichiers/docs/film.bin")
response = conn.getresponse()
assert response.status == 200
assert int(response.getheader("Content-Length")) == len(content)
assert hashlib.sha256(response.read()).digest() == hashlib.sha256(content).digest()
conn.close()
PYSTREAM
  pass "HEAD reports sparse-file metadata with an empty body and GET delivers full file bytes"
}

test_launchd_agent_is_installed_started_stopped_and_removed() {
  local home fakebin out plist link label
  home=$(make_home launchd)
  fakebin="$home/fakebin"
  printf '{"schema": "fm-projets-serve.v1", "port": 4391, "host": "base.test"}\n' > "$home/config/projets-serve.json"
  # a launchctl stand-in that records calls and remembers whether the agent is loaded
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
state="${FAKE_LAUNCHCTL_STATE:?}"
printf '%s\n' "$*" >> "$state.calls"
case "$1" in
  print) [ -e "$state.loaded" ] ;;
  bootstrap) touch "$state.loaded" ;;
  bootout) rm -f "$state.loaded" ;;
  kickstart) [ -e "$state.loaded" ] ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/launchctl"
  run() {
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
      FM_PROJETS_SERVE_LAUNCH_AGENTS="$home/LaunchAgents" FAKE_LAUNCHCTL_STATE="$home/launchctl" "$SERVE" "$@"
  }
  out=$(run url) || fail "url failed"
  assert_contains "$out" "base: http://base.test:4391/" "url does not print the configured base address: $out"
  assert_contains "$out" "page: http://base.test:4391/projets" "url does not print the page address: $out"

  out=$(run install) || fail "install failed: $out"
  label=co.firstmate.projets-serve
  assert_contains "$out" "installed: $label." "install did not report the agent label: $out"
  plist=$(printf '%s\n' "$out" | sed -n 's/^plist: //p')
  link=$(printf '%s\n' "$out" | sed -n 's/^link: //p')
  [ -f "$plist" ] || fail "the plist was not written under the home's private config: $plist"
  case "$plist" in "$home/config/"*) : ;; *) fail "the plist lives outside the home's private material: $plist" ;; esac
  [ -L "$link" ] && [ "$(readlink "$link")" = "$plist" ] || fail "the LaunchAgents link does not point at the home plist"
  python3 - "$plist" "$home" "$SERVER" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["KeepAlive"] is True and p["RunAtLoad"] is True, p
assert p["ProgramArguments"][1] == sys.argv[3], p["ProgramArguments"]
assert p["EnvironmentVariables"]["FM_HOME"] == sys.argv[2], p["EnvironmentVariables"]
assert p["Label"].startswith("co.firstmate.projets-serve."), p["Label"]
PY
  grep -q '^bootstrap gui/' "$home/launchctl.calls" || fail "install did not load the agent through launchctl bootstrap"
  [ -e "$home/launchctl.loaded" ] || fail "the agent is not loaded after install"

  out=$(run install) || fail "second install failed: $out"
  assert_contains "$out" "restarted: " "a second install did not restart the loaded agent: $out"
  grep -q '^kickstart -k gui/' "$home/launchctl.calls" || fail "the restart did not go through kickstart"

  out=$(run status) || fail "status failed"
  assert_contains "$out" "agent: loaded" "status does not report the loaded agent: $out"
  assert_contains "$out" "index: ne repond pas (http://base.test:4391/)" "status did not measure the index with a real request: $out"

  out=$(run stop) || fail "stop failed"
  assert_contains "$out" "stopped: " "stop did not report: $out"
  [ ! -e "$home/launchctl.loaded" ] || fail "the agent is still loaded after stop"
  out=$(run start) || fail "start failed"
  assert_contains "$out" "started: " "start did not report: $out"
  [ -e "$home/launchctl.loaded" ] || fail "the agent is not loaded after start"

  out=$(run uninstall) || fail "uninstall failed"
  assert_contains "$out" "uninstalled: " "uninstall did not report: $out"
  [ ! -e "$home/launchctl.loaded" ] || fail "the agent is still loaded after uninstall"
  assert_absent "$link" "the LaunchAgents link survived uninstall"
  assert_absent "$plist" "the plist survived uninstall"
  git -C "$ROOT" status --porcelain -- bin/ .agents/ 2>/dev/null | grep -q 'projets-serve.*plist' && fail "a plist landed in the shared repository"
  pass "the launchd user agent is installed in the home's private material, restarted, stopped, started and removed"
}

test_index_measures_every_entry_with_a_real_request
test_the_page_is_read_fresh_at_a_stable_address
test_folders_are_served_read_only_and_confined
test_launchd_agent_is_installed_started_stopped_and_removed
test_lavish_redirect_and_fallback
test_unreadable_content_does_not_answer
test_index_probes_share_a_budget
test_shared_file_head_and_stream
stop_servers
while IFS= read -r server_pid; do
  if kill -0 "$server_pid" 2>/dev/null; then fail "test server survived cleanup: $server_pid"; fi
done < "$TMP_ROOT/pids"
: > "$TMP_ROOT/pids"
pass "all test servers stop before the suite exits"
