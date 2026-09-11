#!/usr/bin/env bash
# Opt-in browser check of the visible delivery failure on the generated page.
set -eu
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CHROME=${FM_PROJETS_CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
[ "${FM_PROJETS_CHROME_TEST:-0}" = 1 ] && [ -x "$CHROME" ] || { echo 'skip: opt in with FM_PROJETS_CHROME_TEST=1 and an installed Chrome'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-projets-chrome)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state" FM_DATA_OVERRIDE="$TMP_ROOT/home/data" FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config"
mkdir -p "$FM_HOME/data"
cat > "$TMP_ROOT/payload.json" <<'DATA'
{"schema":"fm-projets-board.v1","home":"test","generated":"2026-09-11T12:00:00Z","updated_label":"11/09","badges":{"workers":0,"decisions":1,"subscriptions":null},"projects":[{"id":"torre","name":"Torre","doing":[],"missing_from_you":[{"key":"choix","question":"On continue ?","options":[{"value":"oui","label":"oui"}],"url":null}],"missing_from_others":[],"pages":[],"costs":{"period":"septembre","source":"à mesurer"},"journal":[],"meeting":null,"gaps":[]}],"unassigned":[],"table_missing":false}
DATA
"$ROOT/bin/fm-projets-board.sh" render "$TMP_ROOT/payload.json" >/dev/null
python3 - "$FM_HOME/.lavish/projets.html" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
s=s.replace('</body>', '''<script>
document.querySelector('[data-choice]').click();
var deliveryStatus = document.querySelector('.you .ok');
document.body.dataset.deliveryVisible = String(deliveryStatus.textContent.includes('non transmis') && getComputedStyle(deliveryStatus).display !== 'none' && deliveryStatus.getBoundingClientRect().height > 0);
</script></body>''')
p.write_text(s)
PY
python3 - "$CHROME" "$TMP_ROOT" "$FM_HOME/.lavish/projets.html" <<'PYBROWSER'
from pathlib import Path
import os, signal, subprocess, sys
chrome, root, page = sys.argv[1:]
root = Path(root)
with (root / "dom.html").open("w") as out, (root / "chrome.log").open("w") as err:
    proc = subprocess.Popen([chrome, "--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--disable-component-update", "--disable-features=GoogleUpdater", "--user-data-dir=" + str(root / "profile"), "--dump-dom", Path(page).as_uri()], stdout=out, stderr=err, start_new_session=True)
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
PYBROWSER
python3 - "$TMP_ROOT/dom.html" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
class Result(HTMLParser):
    visible=False
    def handle_starttag(self, tag, attrs):
        if tag == 'body':
            self.visible=dict(attrs).get('data-delivery-visible') == 'true'
r=Result()
r.feed(Path(sys.argv[1]).read_text())
assert r.visible, 'delivery refusal is not visible in Chrome: ' + Path(sys.argv[1]).read_text().split('<body', 1)[-1].split('<script', 1)[0]
PY
pass "Chrome displays delivery refusal without Lavish"
