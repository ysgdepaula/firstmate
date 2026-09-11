#!/usr/bin/env python3
"""Claude JSONL usage measurement; configuration schemas live in docs/configuration.md."""
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import tempfile

PRICE_DATE = "2026-09-11"
PRICE_SOURCE = "https://platform.claude.com/docs/en/about-claude/pricing"
PRICES = {
    "claude-opus-4-1": (15, 75), "claude-opus-4": (15, 75),
    "claude-opus-4-5": (5, 25), "claude-opus-4-6": (5, 25),
    "claude-opus-4-7": (5, 25), "claude-opus-4-8": (5, 25), "claude-opus-5": (5, 25),
    "claude-sonnet-4": (3, 15), "claude-sonnet-4-5": (3, 15),
    "claude-sonnet-4-6": (3, 15), "claude-sonnet-5": (2, 10),
    "claude-haiku-4-5": (1, 5), "claude-3-5-haiku": (0.8, 4),
    "claude-fable-5": (10, 50), "claude-fable-5-1": (10, 50),
    "claude-mythos-5": (10, 50), "claude-mythos-5-1": (10, 50),
}


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".projets-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def user_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(x.get("text", "") for x in content if isinstance(x, dict) and x.get("type") == "text")
    return ""


def parse_file(path, period):
    task, requests, missing = None, [], set()
    with path.open() as stream:
        for line in stream:
            try:
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError()
                message = row.get("message") or {}
                if not isinstance(message, dict):
                    continue
                if task is None and row.get("type") == "user":
                    match = re.search(r"state/([A-Za-z0-9._-]+)\.status", user_text(message.get("content")))
                    if match:
                        task = match[1]
                if row.get("type") != "assistant":
                    continue
                stamp = dt.datetime.fromisoformat(row.get("timestamp", "").replace("Z", "+00:00"))
                if stamp.tzinfo is None:
                    raise ValueError()
                if stamp.astimezone(dt.timezone.utc).strftime("%Y-%m") != period:
                    continue
                usage = message.get("usage")
                if not isinstance(usage, dict) or not any(k in usage for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")):
                    raise ValueError()
                rid = row.get("requestId") or message.get("id") or row.get("uuid")
                quantities(usage)
                if not isinstance(rid, str) or not rid:
                    missing.add("Claude : requête sans identifiant")
                    continue
                if not isinstance(message.get("model", ""), str):
                    raise ValueError()
                requests.append({"id": rid, "model": message.get("model", ""), "usage": usage})
            except (ValueError, TypeError, AttributeError):
                missing.add("Claude : lignes illisibles ou usage incomplet")
    return {"task": task, "requests": requests, "missing": sorted(missing)}


def project_of(task, folder, projects):
    candidates = [(len(prefix), p["id"]) for p in projects for prefix in p.get("prefixes", []) if task and task.startswith(prefix)]
    if candidates:
        return sorted(candidates, reverse=True)[0][1]
    candidates = [(len(repo), p["id"]) for p in projects for repo in p.get("repos", []) if folder.endswith("-" + repo)]
    if not candidates:
        return None
    longest = max(n for n, _ in candidates)
    matches = {pid for n, pid in candidates if n == longest}
    return next(iter(matches)) if len(matches) == 1 else None


def quantities(usage):
    def count(key, source=usage):
        value = source.get(key, 0)
        if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0:
            raise ValueError("invalid token count")
        return value
    creation = count("cache_creation_input_tokens")
    tiers = usage.get("cache_creation") or {}
    hour = count("ephemeral_1h_input_tokens", tiers)
    short = count("ephemeral_5m_input_tokens", tiers)
    creation = max(creation, hour + short)
    return [count("input_tokens"), count("output_tokens"), max(creation - hour, 0), hour, count("cache_read_input_tokens")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--period", default=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m"))
    parser.add_argument("--eur-rate", type=float)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]{4}-(0[1-9]|1[0-2])", args.period):
        parser.error("--period must be YYYY-MM")
    if args.eur_rate is not None and (not math.isfinite(args.eur_rate) or args.eur_rate <= 0):
        parser.error("--eur-rate must be a positive finite number")
    home = Path(os.environ.get("FM_HOME", Path(__file__).resolve().parent.parent))
    data = Path(os.environ.get("FM_DATA_OVERRIDE", home / "data"))
    config = Path(os.environ.get("FM_CONFIG_OVERRIDE", home / "config"))
    root = Path(os.environ.get("FM_PROJETS_CLAUDE_ROOT", Path.home() / ".claude/projects"))
    table = read_json(config / "projets.json", None)
    if not isinstance(table, dict) or table.get("schema") != "fm-projets-config.v1" or not isinstance(table.get("projects"), list):
        parser.error("project table unavailable; run fm-projets-board.sh init")
    projects = table["projects"]
    cache_path = data / "projets-couts-cache.json"
    cache = read_json(cache_path, {})
    previous = cache.get("files", {}) if cache.get("period") == args.period and cache.get("schema") == "fm-projets-couts-cache.v1" and cache.get("parser_version") == 2 else {}
    files, requests, missing = {}, {}, {"Codex : journaux non lus"}
    if args.eur_rate is None:
        missing.add("EUR : taux de conversion non fourni")
    readable = 0
    parents = {}
    paths = sorted(root.glob("*/*.jsonl")) + sorted(root.glob("*/*/subagents/agent-*.jsonl"))
    for path in paths:
        try:
            stat = path.stat()
            signature = [stat.st_mtime_ns, stat.st_size]
            old = previous.get(str(path), {})
            parsed = old.get("parsed") if old.get("signature") == signature else None
            if not isinstance(parsed, dict):
                parsed = parse_file(path, args.period)
            files[str(path)] = {"signature": signature, "parsed": parsed}
            readable += 1
            missing.update(parsed["missing"])
            if path.parent.name == "subagents":
                parent = path.parent.parent.parent / (path.parent.parent.name + ".jsonl")
                pid = parents.get(str(parent))
            else:
                pid = project_of(parsed["task"], path.parent.name, projects)
                parents[str(path)] = pid
            for request in parsed["requests"]:
                key = request["id"]
                if key not in requests:
                    requests[key] = {**request, "project": pid}
                else:
                    current = requests[key]
                    if current["project"] is None:
                        current["project"] = pid
                    try:
                        if sum(quantities(request["usage"])) > sum(quantities(current["usage"])):
                            current.update(model=request["model"], usage=request["usage"])
                    except ValueError:
                        missing.add("Claude : usage incomplet")
        except (OSError, ValueError, TypeError):
            missing.add("Claude : journal illisible")
    if not readable:
        missing.add("Claude : aucun journal disponible")
    totals = {p["id"]: {"usd": 0, "tokens": 0, "priced": 0, "unknown": False, "valid": 0} for p in projects}
    all_tokens = 0
    for request in requests.values():
        try:
            q = quantities(request["usage"])
        except (ValueError, TypeError, AttributeError):
            missing.add("Claude : usage incomplet")
            continue
        tokens = sum(q)
        all_tokens += tokens
        total = totals.get(request["project"])
        if total is not None:
            total["tokens"] += tokens
            total["valid"] += 1
        else:
            missing.add("Claude : usage sans projet inclus dans le total")
        model = re.sub(r"-[0-9]{8}$", "", request["model"])
        price = PRICES.get(model)
        if price is None:
            missing.add("modèle inconnu : prix absent")
            if total is not None:
                total["unknown"] = True
            continue
        base, output = price
        read = base * (0.025 if model in ("claude-fable-5-1", "claude-mythos-5-1") else 0.1)
        usd = sum(n * rate for n, rate in zip(q, (base, output, base * 1.25, base * 2, read))) / 1_000_000
        if total is not None:
            total["usd"] += usd
            total["priced"] += 1
    output = {}
    for pid, total in totals.items():
        usd = round(total["usd"], 6) if total["valid"] and (total["priced"] or not total["unknown"]) else None
        output[pid] = {
            "tokens_api_usd": usd,
            "tokens_api_eur": round(usd * args.eur_rate, 6) if usd is not None and args.eur_rate is not None else None,
            "subscription_share_pct": round(total["tokens"] / all_tokens * 100, 2) if all_tokens and total["valid"] else None,
            "sources": {"measured": ["Claude : jetons du mois, valeur API publique et part des jetons"] if total["valid"] else [], "missing": sorted(missing | (set() if total["valid"] else {"Claude : aucune requête exploitable pour ce projet"}))},
        }
    write_json(cache_path, {"schema": "fm-projets-couts-cache.v1", "parser_version": 2, "period": args.period, "files": files})
    write_json(data / "projets-couts.json", {"schema": "fm-projets-couts.v1", "period": args.period, "price_date": PRICE_DATE, "price_source": PRICE_SOURCE, "eur_per_usd": args.eur_rate, "projects": output})
    print("costs: " + str(data / "projets-couts.json"))


if __name__ == "__main__":
    main()
