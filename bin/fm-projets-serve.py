#!/usr/bin/env python3
"""fm-projets-serve.py - the base's stable HTTP front door on the tailnet.

Serves, on one fixed port bound to every interface so the MagicDNS name answers:

  /                 the index the captain bookmarks: one line per thing reachable
                    on the base (the projets page, the Lavish reviews in
                    progress, the demos and folders declared in the table), each
                    with its address and a state measured by a real request at
                    render time, never assumed
  /projets          a no-store redirect to the open Lavish session for the page;
                    without a session, reads $FM_HOME/.lavish/projets.html fresh
                    with a visible warning that answers cannot be queued
  /a-valider        the same for $FM_HOME/.lavish/a-valider.html, everything
                    waiting on the captain across every project
  /fichiers/<id>/   the shared folders declared in the table, read-only, with a
                    plain listing; paths are confined to the declared folder

Everything else is 404. bin/fm-projets-serve.sh owns the launchd service and the
operator commands; docs/configuration.md "Stable page address" owns the table
schema (config/projets-serve.json). The tailnet only covers the captain's own
machines: this server is never a client-facing surface, and the index says so.

Environment (all optional): FM_HOME (home root, default: the parent of bin/),
FM_CONFIG_OVERRIDE, FM_PROJETS_SERVE_BIND (default 0.0.0.0), FM_PROJETS_SERVE_PORT
(overrides the table; 0 picks a free port and is meant for tests),
FM_PROJETS_SERVE_PROBE_TIMEOUT (seconds per reachability probe, default 2),
FM_PROJETS_SERVE_INDEX_BUDGET (seconds for listing and concurrent index probes,
default 3; at most 8 probes run together, unfinished measurements are disclosed),
FM_PROJETS_SERVE_LAVISH (the lavish-axi binary, default from PATH).
Shared GET bodies are streamed; HEAD uses file metadata without reading the body.

Usage: fm-projets-serve.py            (prints `listening: <url>` then serves)
"""
from __future__ import annotations

import concurrent.futures
import html
import json
import os
import posixpath
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_PORT = 4390
SCHEMA = "fm-projets-serve.v1"


def fm_home() -> Path:
    env = os.environ.get("FM_HOME")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent


def config_path() -> Path:
    override = os.environ.get("FM_CONFIG_OVERRIDE")
    base = Path(override) if override else fm_home() / "config"
    return base / "projets-serve.json"


def load_config() -> dict:
    """Read the private table; a missing or unreadable table yields defaults and a note."""
    path = config_path()
    cfg = {"schema": SCHEMA, "port": DEFAULT_PORT, "host": None, "entries": [], "folders": [], "note": None}
    if not path.exists():
        cfg["note"] = "table config/projets-serve.json absente : port %d, aucune démo ni dossier déclaré" % DEFAULT_PORT
        return cfg
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        cfg["note"] = "table config/projets-serve.json illisible (%s) : valeurs par défaut" % exc.__class__.__name__
        return cfg
    if not isinstance(raw, dict) or raw.get("schema") != SCHEMA:
        cfg["note"] = "table config/projets-serve.json sans schéma %s : valeurs par défaut" % SCHEMA
        return cfg
    port = raw.get("port", DEFAULT_PORT)
    if isinstance(port, int) and 1 <= port <= 65535:
        cfg["port"] = port
    host = raw.get("host")
    if isinstance(host, str) and host.strip():
        cfg["host"] = host.strip()
    for entry in raw.get("entries") or []:
        if isinstance(entry, dict) and isinstance(entry.get("label"), str) and isinstance(entry.get("url"), str):
            cfg["entries"].append({"label": entry["label"].strip(), "url": entry["url"].strip()})
    for folder in raw.get("folders") or []:
        if isinstance(folder, dict) and isinstance(folder.get("label"), str) and isinstance(folder.get("path"), str):
            slug = slugify(folder.get("id") or folder["label"])
            cfg["folders"].append({"id": slug, "label": folder["label"].strip(), "path": os.path.expanduser(folder["path"])})
    return cfg


def slugify(text: str) -> str:
    out = []
    for ch in text.lower():
        out.append(ch if ch.isalnum() and ch.isascii() else "-")
    slug = "-".join(part for part in "".join(out).split("-") if part)
    return slug[:60] or "dossier"


def probe(url: str, timeout: float) -> bool:
    """A successful HTTP request decides whether the published content answers."""
    try:
        req = urllib.request.Request(url, method="GET", headers={"User-Agent": "fm-projets-serve"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - operator-declared addresses
            return 200 <= resp.status < 400
    except urllib.error.HTTPError:
        return False
    except Exception:  # noqa: BLE001 - every transport failure is "does not answer"
        return False


def lavish_sessions(timeout: float) -> tuple[list, str | None]:
    """Reviews still open in Lavish, from `lavish-axi`'s own listing; never guessed."""
    binary = os.environ.get("FM_PROJETS_SERVE_LAVISH") or shutil.which("lavish-axi")
    if not binary:
        return [], "lavish-axi introuvable : revues Lavish non listées"
    try:
        result = subprocess.run([binary], capture_output=True, text=True, timeout=timeout, check=False)
        if result.returncode:
            return [], "lavish-axi ne répond pas : revues Lavish non listées"
        out = result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return [], "lavish-axi ne répond pas : revues Lavish non listées"
    rows = []
    in_table = False
    for line in out.splitlines():
        if line.startswith("sessions["):
            in_table = True
            continue
        if in_table:
            if not line.startswith("  "):
                break
            import csv
            import io
            fields = next(csv.reader(io.StringIO(line.strip())))
            if len(fields) < 3:
                continue
            file, status, url = fields[0], fields[1], fields[2]
            if status in ("ended", "closed"):
                continue
            rows.append({"file": file, "label": Path(file).stem, "url": url, "status": status})
    return rows, None


# The two pages bin/fm-projets-board.sh writes, each at its own stable route.
PAGES = (
    ("/projets", "projets.html", "La page projets"),
    ("/a-valider", "a-valider.html", "Ce qui attend ta réponse"),
)


def page_path(name: str = "projets.html") -> Path:
    return fm_home() / ".lavish" / name


def page_route(path: str):
    """Match a request path against the served pages; returns (file, label) or None."""
    for route, name, label in PAGES:
        if path in (route, route + "/", route + ".html"):
            return name, label
    return None


def h(text) -> str:
    return html.escape(str(text), quote=True)


def page_session(sessions: list, name: str = "projets.html") -> str | None:
    for session in sessions:
        url = session["url"]
        parsed = urllib.parse.urlsplit(url)
        if (Path(session["file"]).resolve() == page_path(name).resolve()
                and parsed.scheme in ("http", "https") and parsed.netloc
                and "\r" not in url and "\n" not in url):
            return url
    return None


def render_index(cfg: dict, public_base: str, probe_base: str) -> bytes:
    timeout = float(os.environ.get("FM_PROJETS_SERVE_PROBE_TIMEOUT", "2"))
    budget = float(os.environ.get("FM_PROJETS_SERVE_INDEX_BUDGET", "3"))
    deadline = time.monotonic() + budget
    sessions, note = lavish_sessions(max(0.001, min(timeout, budget)))
    lines = []
    for route, name, label in PAGES:
        hint = ("réponses mises en file par Lavish" if page_session(sessions, name)
                else "boutons sans file : session Lavish absente ou indisponible")
        lines.append((label, public_base + route, probe_base + route, hint))
    for session in sessions:
        lines.append(("Revue Lavish : " + session["label"], session["url"], session["url"], "en cours, à annoter"))
    for entry in cfg["entries"]:
        lines.append((entry["label"], entry["url"], entry["url"], "démo ou service déclaré"))
    for folder in cfg["folders"]:
        route = "/fichiers/" + folder["id"] + "/"
        lines.append(("Dossier : " + folder["label"], public_base + route, probe_base + route, "fichiers partagés, lecture seule"))
    results = {}
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=8)
    pending = {}
    try:
        for i, (_, _, url, _) in enumerate(lines):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            pending[executor.submit(probe, url, timeout)] = i
        if pending:
            done, _ = concurrent.futures.wait(pending, timeout=max(0, deadline - time.monotonic()))
            for future in done:
                results[pending[future]] = future.result()
    finally:
        for future in pending:
            future.cancel()
        executor.shutdown(wait=False, cancel_futures=True)
    items = []
    for i, (label, url, _, hint) in enumerate(lines):
        ok = results.get(i)
        state = "mesure inachevée" if ok is None else "répond" if ok else "ne répond pas"
        items.append(
            '<li class="%s"><span class="state">%s</span> <a href="%s">%s</a> <span class="addr">%s</span> <span class="hint">%s</span></li>'
            % ("ok" if ok else "ko", h(state), h(url), h(label), h(url), h(hint))
        )
    notes = [n for n in (cfg.get("note"), note) if n]
    body = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>La base</title>
<style>
:root{--paper:#FAFAF8;--surround:#EFEEE9;--ink:#111;--muted:#8A8A87;--line:#DBDAD4}
*{box-sizing:border-box;margin:0;padding:0}html,body{max-width:100%%;overflow-x:hidden}
body{background:var(--surround);color:var(--ink);font:15px/1.5 "Helvetica Neue",Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
.wrap{max-width:820px;margin:0 auto;padding:32px 20px 80px;min-width:0}
h1{font-size:24px;font-weight:700;letter-spacing:-.02em}.meta{color:var(--muted);font-size:13px;margin:4px 0 20px}
ul{list-style:none;background:var(--paper);border:1.6px solid var(--ink);border-radius:18px;padding:6px 18px}
li{display:flex;flex-wrap:wrap;gap:4px 12px;align-items:baseline;padding:12px 0;border-bottom:1px solid var(--line);min-width:0}
li:last-child{border-bottom:0}
.state{font:11px/1.6 "SF Mono",ui-monospace,Menlo,monospace;letter-spacing:.1em;text-transform:uppercase;border:1px solid var(--ink);border-radius:999px;padding:0 8px;flex:none}
li.ko .state{border-style:dashed;border-color:var(--muted);color:var(--muted)}
a{color:inherit;font-weight:700;overflow-wrap:anywhere}.addr,.hint{color:var(--muted);font-size:13px;overflow-wrap:anywhere}
.addr{font-family:"SF Mono",ui-monospace,Menlo,monospace;font-size:12px}
.limit{margin-top:18px;color:var(--muted);font-size:13px;max-width:70ch}
.note{margin-top:10px;color:var(--muted);font-size:13px}
</style></head><body><div class="wrap">
<h1>La base</h1>
<div class="meta">ce qui est joignable sur la base, état mesuré à l'ouverture de cette page</div>
<ul>%s</ul>
%s
<p class="limit">Cette adresse vit sur le réseau privé de Yan (tailnet) : seules ses machines la voient, un client extérieur n'y a pas accès. Les pages client passent par un sous-domaine dédié, chantier séparé.</p>
</div></body></html>
""" % ("\n".join(items), "".join('<p class="note">%s</p>' % h(n) for n in notes))
    return body.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "fm-projets-serve/1"
    cfg: dict = {}
    public_base: str = ""

    def log_message(self, fmt, *args):  # quiet by default; launchd captures stderr
        if os.environ.get("FM_PROJETS_SERVE_LOG"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, status, body: bytes, ctype="text/html; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):  # noqa: N802
        self.do_GET()

    def do_GET(self):  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        if path in ("/", "/index.html"):
            return self._send(HTTPStatus.OK, render_index(self.cfg, self.public_base, "http://127.0.0.1:%d" % self.server.server_address[1]))
        route = page_route(path)
        if route is not None:
            name, _label = route
            page = page_path(name)
            try:
                body = page.read_bytes()
            except FileNotFoundError:
                return self._send(HTTPStatus.NOT_FOUND, "<p>Cette page n'a pas encore été générée.</p>".encode())
            except OSError:
                return self._send(HTTPStatus.INTERNAL_SERVER_ERROR, "<p>Cette page est illisible.</p>".encode())
            sessions, _ = lavish_sessions(float(os.environ.get("FM_PROJETS_SERVE_PROBE_TIMEOUT", "2")))
            url = page_session(sessions, name)
            if url:
                self.send_response(HTTPStatus.FOUND)
                self.send_header("Location", url)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None
            banner = ("<aside role=\"alert\" style=\"padding:16px;background:#fff3cd;color:#111\">"
                      "Ici les boutons ne mettent rien en file : ouvre la page dans Lavish pour répondre "
                      "(session absente ou indisponible).</aside>").encode()
            body_tag = re.search(rb"<body\b[^>]*>", body, re.IGNORECASE)
            offset = body_tag.end() if body_tag else 0
            body = body[:offset] + banner + body[offset:]
            marker = b"""<script>
function markUnsent() {
  document.querySelectorAll('[data-choice], [data-create-lavish]').forEach(function(button) {
    button.dataset.transmitted = 'false';
    button.title = 'non mis en file : ouvre cette page dans Lavish';
  });
  document.querySelectorAll('.you .ok').forEach(function(status) {
    status.textContent = 'non mis en file : ouvre cette page dans Lavish';
    status.style.display = 'block';
  });
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', markUnsent);
else markUnsent();
</script>"""
            body = re.sub(rb"</body\s*>", lambda match: marker + match.group(), body, count=1, flags=re.IGNORECASE) if body_tag else body + marker
            return self._send(HTTPStatus.OK, body)
        if path.startswith("/fichiers/"):
            try:
                return self._files(path)
            except OSError:
                return self._send(HTTPStatus.INTERNAL_SERVER_ERROR, "<p>Le dossier ou le fichier est illisible.</p>".encode())
        return self._send(HTTPStatus.NOT_FOUND, b"<p>Rien ici.</p>")

    def _files(self, path: str):
        parts = path[len("/fichiers/"):].split("/", 1)
        folder = next((f for f in self.cfg["folders"] if f["id"] == parts[0]), None)
        if folder is None:
            return self._send(HTTPStatus.NOT_FOUND, b"<p>Dossier inconnu.</p>")
        root = Path(folder["path"]).resolve()
        rel = urllib.parse.unquote(parts[1]) if len(parts) > 1 else ""
        # confine every request to the declared folder: normalise, then require the prefix
        target = (root / posixpath.normpath("/" + rel).lstrip("/")).resolve()
        if target != root and root not in target.parents:
            return self._send(HTTPStatus.FORBIDDEN, b"<p>Hors du dossier.</p>")
        if target.is_dir():
            if not path.endswith("/"):
                self.send_response(HTTPStatus.MOVED_PERMANENTLY)
                self.send_header("Location", path + "/")
                self.end_headers()
                return None
            rows = []
            for child in sorted(target.iterdir(), key=lambda c: (not c.is_dir(), c.name.lower())):
                if child.name.startswith("."):
                    continue
                name = child.name + ("/" if child.is_dir() else "")
                rows.append('<li><a href="%s">%s</a></li>' % (h(urllib.parse.quote(name)), h(name)))
            body = ('<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>%s</title>'
                    '<style>body{font:15px/1.6 "Helvetica Neue",Helvetica,Arial,sans-serif;padding:24px;max-width:820px}ul{list-style:none;padding:0}li{padding:4px 0}</style>'
                    '</head><body><h1>%s</h1><p><a href="/">La base</a></p><ul>%s</ul></body></html>'
                    % (h(folder["label"]), h(folder["label"]), "\n".join(rows)))
            return self._send(HTTPStatus.OK, body.encode("utf-8"))
        if target.is_file():
            import mimetypes
            ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
            with target.open("rb") as stream:
                size = os.fstat(stream.fileno()).st_size
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(size))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                if self.command != "HEAD":
                    shutil.copyfileobj(stream, self.wfile, length=64 * 1024)
            return None
        return self._send(HTTPStatus.NOT_FOUND, b"<p>Fichier absent.</p>")


def main() -> int:
    cfg = load_config()
    bind = os.environ.get("FM_PROJETS_SERVE_BIND", "0.0.0.0")
    port_env = os.environ.get("FM_PROJETS_SERVE_PORT")
    port = int(port_env) if port_env not in (None, "") else cfg["port"]
    host = cfg["host"] or socket.gethostname()
    server = ThreadingHTTPServer((bind, port), Handler)
    actual_port = server.server_address[1]
    Handler.cfg = cfg
    Handler.public_base = "http://%s:%d" % (host if bind == "0.0.0.0" else bind, actual_port)
    print("listening: http://%s:%d/" % (bind if bind != "0.0.0.0" else host, actual_port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
