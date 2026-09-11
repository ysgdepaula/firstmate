#!/usr/bin/env python3
"""fm-projets-serve.py - the base's stable HTTP front door on the tailnet.

Serves, on one fixed port bound to every interface so the MagicDNS name answers:

  /                 the index the captain bookmarks: one line per thing reachable
                    on the base (the projets page, the Lavish reviews in
                    progress, the demos and folders declared in the table), each
                    with its address and a state measured by a real request at
                    render time, never assumed
  /projets          the projets page, read from $FM_HOME/.lavish/projets.html at
                    every request, so a rebuild in place changes the content
                    while the address never moves
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
FM_PROJETS_SERVE_LAVISH (the lavish-axi binary, default from PATH).

Usage: fm-projets-serve.py            (prints `listening: <url>` then serves)
"""
from __future__ import annotations

import html
import json
import os
import posixpath
import shutil
import socket
import subprocess
import sys
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
    """A real request decides: any HTTP answer below 500 counts as reachable."""
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "fm-projets-serve"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - operator-declared addresses
            return resp.status < 500
    except urllib.error.HTTPError as exc:
        return exc.code < 500
    except Exception:  # noqa: BLE001 - every transport failure is "does not answer"
        return False


def lavish_sessions(timeout: float) -> tuple[list, str | None]:
    """Reviews still open in Lavish, from `lavish-axi`'s own listing; never guessed."""
    binary = os.environ.get("FM_PROJETS_SERVE_LAVISH") or shutil.which("lavish-axi")
    if not binary:
        return [], "lavish-axi introuvable : revues Lavish non listées"
    try:
        out = subprocess.run([binary], capture_output=True, text=True, timeout=timeout, check=False).stdout
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
            rows.append({"label": Path(file).stem, "url": url, "status": status})
    return rows, None


def page_path() -> Path:
    return fm_home() / ".lavish" / "projets.html"


def h(text) -> str:
    return html.escape(str(text), quote=True)


def render_index(cfg: dict, public_base: str) -> bytes:
    timeout = float(os.environ.get("FM_PROJETS_SERVE_PROBE_TIMEOUT", "2"))
    lines = []
    page = page_path()
    lines.append(("La page projets", public_base + "/projets", page.exists(), "régénérée à chaque événement, l'adresse ne bouge pas"))
    sessions, note = lavish_sessions(timeout)
    for s in sessions:
        lines.append(("Revue Lavish : " + s["label"], s["url"], probe(s["url"], timeout), "en cours, à annoter"))
    for e in cfg["entries"]:
        lines.append((e["label"], e["url"], probe(e["url"], timeout), "démo ou service déclaré"))
    for f in cfg["folders"]:
        lines.append(("Dossier : " + f["label"], public_base + "/fichiers/" + f["id"] + "/", Path(f["path"]).is_dir(), "fichiers partagés, lecture seule"))
    items = []
    for label, url, ok, hint in lines:
        state = "répond" if ok else "ne répond pas"
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
            return self._send(HTTPStatus.OK, render_index(self.cfg, self.public_base))
        if path in ("/projets", "/projets.html", "/projets/"):
            page = page_path()
            if not page.is_file():
                return self._send(HTTPStatus.NOT_FOUND, "<p>La page projets n'a pas encore été générée.</p>".encode())
            return self._send(HTTPStatus.OK, page.read_bytes())
        if path.startswith("/fichiers/"):
            return self._files(path)
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
            return self._send(HTTPStatus.OK, target.read_bytes(), ctype)
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
