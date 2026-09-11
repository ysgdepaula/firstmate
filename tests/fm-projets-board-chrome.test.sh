#!/usr/bin/env bash
# Opt-in browser checks of the generated page under a real Chrome: the visible
# delivery failure without Lavish, and the phone layout at a narrow width where
# no text may be covered by another element, nothing may overflow the viewport,
# and every button must be reachable on the selected card at exactly 390 px,
# with the folded and unfolded block states asserted before geometry checks.
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
document.addEventListener('DOMContentLoaded', function(){ setTimeout(function(){
  document.querySelector('[data-choice]').click();
  var deliveryStatus = document.querySelector('.you .ok');
  document.body.dataset.deliveryVisible = String(deliveryStatus.textContent.includes('non transmis') && getComputedStyle(deliveryStatus).display !== 'none' && deliveryStatus.getBoundingClientRect().height > 0);
  document.body.dataset.fallbackMarked = String(document.querySelector('[data-choice]').dataset.transmitted === 'false' && document.querySelector('[role="alert"]').textContent.includes('Ici les boutons ne transmettent rien'));
}, 50); });
</script></body>''')
p.write_text(s)
PY
python3 - "$CHROME" "$TMP_ROOT" "$ROOT/bin/fm-projets-serve.py" <<'PYBROWSER'
from pathlib import Path
import os, signal, subprocess, sys, time
chrome, root, server_path = sys.argv[1:]
root = Path(root)
env = dict(os.environ, FM_PROJETS_SERVE_BIND="127.0.0.1", FM_PROJETS_SERVE_PORT="0", FM_PROJETS_SERVE_LAVISH="/usr/bin/false")
with (root / "server.log").open("w") as log:
    server = subprocess.Popen([sys.executable, server_path], env=env, stdout=log, stderr=log)
    try:
        for _ in range(100):
            lines = (root / "server.log").read_text().splitlines()
            if lines and lines[0].startswith("listening: "):
                url = lines[0].removeprefix("listening: ") + "projets"
                break
            time.sleep(0.05)
        else:
            raise AssertionError("front door did not start")
        with (root / "dom.html").open("w") as out, (root / "chrome.log").open("w") as err:
            proc = subprocess.Popen([chrome, "--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--disable-component-update", "--disable-features=GoogleUpdater", "--user-data-dir=" + str(root / "profile"), "--virtual-time-budget=1000", "--dump-dom", url], stdout=out, stderr=err, start_new_session=True)
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    finally:
        server.terminate()
        server.wait(timeout=5)
PYBROWSER
python3 - "$TMP_ROOT/dom.html" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
class Result(HTMLParser):
    visible=False
    marked=False
    def handle_starttag(self, tag, attrs):
        if tag == 'body':
            self.visible=dict(attrs).get('data-delivery-visible') == 'true'
            self.marked=dict(attrs).get('data-fallback-marked') == 'true'
r=Result()
r.feed(Path(sys.argv[1]).read_text())
assert r.marked, 'the fallback banner and unsent button marker were not rendered'
assert r.visible, 'delivery refusal is not visible in Chrome: ' + Path(sys.argv[1]).read_text().split('<body', 1)[-1].split('<script', 1)[0]
PY
pass "Chrome displays the stable-address fallback and marks buttons as unsent without Lavish"

# --- phone layout: nothing covered, nothing overflowing, every button reachable ---
cat > "$TMP_ROOT/filled.json" <<'DATA'
{"schema":"fm-projets-board.v1","home":"test","generated":"2026-09-11T12:00:00Z","updated_label":"11/09 12h00","badges":{"workers":3,"decisions":6,"subscriptions":"Claude 41 % · Codex 66 %"},
 "projects":[
  {"id":"torre","name":"Torre","team":"Eli, Bechir","deadline":{"label":"pilote achats et stock","date":"2026-09-14"},
   "doing":[{"id":"t1","result":"Torre e-commerce : benchmark des references et squelette du site a presenter, nuit du 10 au 11/09","status":"livré","next":"fusion à confirmer","url":"https://example.test/pr/1"},
            {"id":"t2","result":"interfaces v0 (tableaux de bord achats/stock pour la direction et les boutiques)","status":"en cours","next":null,"url":null},
            {"id":"t3","result":"agent client WhatsApp v0","status":"en pause, attente extérieure · numéro Meta","next":null,"url":null},
            {"id":"t4","result":"quatrième résultat replié","status":"en cours","next":null,"url":null}],
   "scouts":[{"id":"s1","result":"audit Shopify vs Stripe custom (vs Square Online) pour le site click and collect","status":"état inconnu","next":null,"url":null}],
   "missing_from_you":[{"key":"torre-hebergement","question":"trancher hebergement et montage de facturation, les deux sont lies","options":[{"value":"a","label":"hébergé chez toi"},{"value":"b","label":"hébergé chez Torre"},{"value":"c","label":"plus tard"}],"url":null},
                       {"key":"reco__meta","question":"Brancher Meta dès l accès de Bechir : le pilote du 14/09 en dépend","kind":"recommandation","options":[{"value":"on-y-va","label":"on y va"},{"value":"pas-maintenant","label":"pas maintenant"},{"value":"on-en-parle","label":"on en parle"}],"url":null}],
   "missing_from_others":[{"who":"Eli","what":"les factures d un circuit fournisseur","tag":"avant le 11/09"}],
   "pages":[{"label":"Espace client","url":"http://machine.ts.net:4387/session/1","state":"à jour 10/09"}],
   "creations":[{"label":"Démo de l interface de suivi","url":"http://machine.ts.net:4387/session/2","kind":"page"}],
   "costs":{"period":"septembre","tokens_api":"123 EUR au prix API","subscription_share":null,"source":"Claude : journaux mesurés · Codex : journaux non lus"},
   "journal":[{"when":"11/09 01:04","what":"livraison : Torre e-commerce : benchmark des references et squelette du site","url":"https://example.test/pr/2"}],
   "meeting":{"title":"Pilote sur place","date":"2026-09-14","time":"10:00","source":"agenda et chat","with":"Eli et la boutique pilote","bring":["la démo"],"decide":["l enveloppe"]},
   "meetings":[{"title":"Pilote sur place","date":"2026-09-14","time":"10:00","source":"agenda et chat","with":"Eli et la boutique pilote","bring":["la démo"],"decide":["l enveloppe"]}],
   "agenda_available":true,"gaps":["coûts à mesurer","1 décision sans choix fermés, boutons génériques"]},
  {"id":"cerveau","name":"Cerveau","brain":true,"doing":[],"scouts":[],
   "missing_from_you":[{"key":"article__x","question":"Article à valider : Doctrine de dépense des modèles","kind":"article","options":[{"value":"valide","label":"validé"},{"value":"a-revoir","label":"à revoir"}],"url":null}],
   "missing_from_others":[],"pages":[],"creations":[],"unlinked":[{"id":"u1","what":"SACEM : relancer Sabine Jacob si pas de reponse"}],"quick_wins":["Indexer les rapports de scouts"],
   "costs":{"period":"septembre","tokens_api":null,"subscription_share":null,"source":"à mesurer"},"journal":[],"meeting":null,"gaps":[]}],
 "unassigned":[],"table_missing":false}
DATA
"$ROOT/bin/fm-projets-board.sh" render "$TMP_ROOT/filled.json" >/dev/null
for target in torre cerveau 'torre&open' 'cerveau&open'; do
  python3 - "$FM_HOME/.lavish/projets.html" "$TMP_ROOT/host.html" "$target" <<'PYHOST'
from pathlib import Path
import html, json, sys
source, host, target = sys.argv[1:]
project, _, mode = target.partition("&")
inspector = r'''<script>
setTimeout(function(){
  var wanted = __PROJECT__, unfold = __UNFOLD__;
  var rail = document.querySelector('button[data-project="' + wanted + '"]');
  if (rail) rail.click();
  var card = document.querySelector('.card:not([hidden])');
  var toggles = card ? Array.from(card.querySelectorAll('.bloc .toggle')) : [];
  if (unfold) toggles.forEach(function(button){ if (button.getAttribute('aria-expanded') === 'false') button.click(); });
  setTimeout(function(){
    var w = document.documentElement.clientWidth, issues = [];
    Array.prototype.forEach.call(document.querySelectorAll("body *"), function(e){
      var r = e.getBoundingClientRect();
      if (!(r.width > 0 && r.height > 0)) return;
      var tag = e.tagName + "." + (e.className || "");
      if (r.right > w + 1 || r.left < -1) issues.push("overflow " + tag);
      var rects = [];
      Array.from(e.childNodes).forEach(function(node){
        if (node.nodeType !== 3 || !node.textContent.trim()) return;
        var range = document.createRange();
        range.selectNodeContents(node);
        rects = rects.concat(Array.from(range.getClientRects()));
      });
      if (e.tagName === "BUTTON" || e.tagName === "A") rects = rects.concat(Array.from(e.getClientRects()));
      rects.forEach(function(rect){
        var y = rect.top + Math.min(10, rect.height / 2), inset = Math.min(3, rect.width / 2);
        [[rect.left + rect.width / 2, y], [rect.left + inset, y], [rect.right - inset, y]].forEach(function(p){
          if (p[1] < 0 || p[1] > window.innerHeight || p[0] < 0 || p[0] > w) return;
          var hit = document.elementFromPoint(p[0], p[1]);
          if (hit && hit !== e && !e.contains(hit) && !hit.contains(e)) issues.push("covered " + tag + " (" + e.textContent.slice(0,60) + ") by " + hit.tagName + "." + (hit.className || ""));
        });
      });
    });
    parent.postMessage({issues:issues.length, detail:issues.slice(0,12).join(" | "), width:w,
      viewport:window.innerWidth, card:card && card.dataset.project, blocks:toggles.length,
      open:toggles.filter(function(button){return button.getAttribute('aria-expanded') === 'true';}).length}, '*');
  }, 50);
}, 100);
</script></body>'''
inspector = inspector.replace('__PROJECT__', json.dumps(project)).replace('__UNFOLD__', json.dumps(mode == 'open'))
page = Path(source).read_text().replace('</body>', inspector)
wrapper = '''<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0">
<script>
window.addEventListener('message', function(event){
  if (event.source !== document.getElementById('phone').contentWindow) return;
  Object.keys(event.data).forEach(function(key){ document.body.dataset[key] = String(event.data[key]); });
});
</script>
<iframe id="phone" style="width:390px;height:10000px;border:0;display:block" srcdoc="__PAGE__"></iframe>
</body></html>'''
Path(host).write_text(wrapper.replace('__PAGE__', html.escape(page, quote=True)))
PYHOST
  python3 - "$CHROME" "$TMP_ROOT" "$TMP_ROOT/host.html" <<'PYBROWSER'
from pathlib import Path
import os, signal, subprocess, sys
chrome, root, page = sys.argv[1:]
root = Path(root)
with (root / "layout.html").open("w") as out, (root / "chrome-layout.log").open("w") as err:
    proc = subprocess.Popen([chrome, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--disable-component-update", "--disable-features=GoogleUpdater", "--user-data-dir=" + str(root / "profile-layout"), "--window-size=500,1000", "--virtual-time-budget=3000", "--dump-dom", Path(page).as_uri()], stdout=out, stderr=err, start_new_session=True)
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
PYBROWSER
  python3 - "$TMP_ROOT/layout.html" "$target" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
class Result(HTMLParser):
    data = {}
    def handle_starttag(self, tag, attrs):
        if tag == "body":
            self.data = dict(attrs)
r = Result(); r.feed(Path(sys.argv[1]).read_text())
a = r.data
project, _, mode = sys.argv[2].partition('&')
assert a.get('data-width') == '390' and a.get('data-viewport') == '390', a
assert a.get('data-card') == project, a
assert a.get('data-blocks') == '7', a
assert a.get('data-open') == ('7' if mode == 'open' else '1'), a
assert a.get('data-issues') == '0', "phone layout issues for %s: %s" % (sys.argv[2], a)
PY
done
pass "Chrome checks both selected cards at 390 px, folded and unfolded, without coverage or overflow"
