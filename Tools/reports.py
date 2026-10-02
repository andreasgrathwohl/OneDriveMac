#!/usr/bin/env python3
"""Fehlerberichte von OneDrive Opener abfragen (Berichts-Server, siehe server/docker-compose.yml).

Liest nur im Heimnetz (über den Tunnel ist das Lesen gesperrt). Zugangsdaten des Lesekontos:
~/.cloudflared/reader.txt – Zeile 1 E-Mail, Zeile 2 Passwort (oder ODO_READER_FILE).
Ausgaben werden zusätzlich in reports-output/ gespeichert (nicht versioniert).

  python tools/reports.py list [N]            letzte N Berichte (Standard 20)
  python tools/reports.py errors [N]          letzte N Fehler
  python tools/reports.py devices             Geräte mit Version und letzter Meldung
  python tools/reports.py show ID             einen Bericht vollständig (Protokoll, Pfade)
  python tools/reports.py request diagnostics|update [INSTALL_ID]
                                              Anfrage an ein Gerät oder (ohne ID) an alle
  python tools/reports.py sync                alle Berichte nach reports-output/reports.json
  python tools/reports.py delete-tests        Probeberichte (kind = "test") löschen
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

BASE = os.environ.get("ODO_SERVER", "http://grathwohl-server.local:8095")
READER_FILE = Path(os.environ.get("ODO_READER_FILE", Path.home() / ".cloudflared" / "reader.txt"))
OUT_DIR = Path(__file__).resolve().parent.parent / "reports-output"


def call(method, path, token=None, body=None, query=None):
    url = BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json", "User-Agent": "OneDriveOpener-Reports/1"}
    if token:
        headers["Authorization"] = token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"Server antwortet mit {e.code}: {e.read().decode('utf-8', 'replace')[:300]}")
    except urllib.error.URLError as e:
        sys.exit(f"Server nicht erreichbar ({BASE}): {e.reason} – nur im Heimnetz möglich.")


def login():
    if not READER_FILE.exists():
        sys.exit(f"Zugangsdaten fehlen: {READER_FILE} (Zeile 1 E-Mail, Zeile 2 Passwort)")
    lines = [l.strip() for l in READER_FILE.read_text(encoding="utf-8-sig").splitlines() if l.strip()]
    if len(lines) < 2:
        sys.exit(f"{READER_FILE}: Zeile 1 E-Mail, Zeile 2 Passwort erwartet")
    result = call("POST", "/api/collections/readers/auth-with-password",
                  body={"identity": lines[0], "password": lines[1]})
    return result["token"]


def records(token, filter_=None, sort="-created", limit=20):
    items, page = [], 1
    while True:
        query = {"sort": sort, "perPage": min(limit, 200), "page": page}
        if filter_:
            query["filter"] = filter_
        result = call("GET", "/api/collections/reports/records", token, query=query)
        items += result.get("items", [])
        if len(items) >= limit or page >= result.get("totalPages", 1):
            return items[:limit]
        page += 1


def short(text, n=110):
    text = " ".join(str(text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def table(items):
    lines = []
    for r in items:
        lines.append(f"{r['created'][:19]}  {r['kind']:<11} v{r.get('app_version', '?'):<7} "
                     f"{r['install_id'][:8]}  {r['id']}  {short(r.get('message'))}")
    return "\n".join(lines) or "(keine Einträge)"


def save(name, text, data=None):
    OUT_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    (OUT_DIR / f"{stamp}-{name}.txt").write_text(text + "\n", encoding="utf-8")
    if data is not None:
        (OUT_DIR / f"{stamp}-{name}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n→ gespeichert in {OUT_DIR / (stamp + '-' + name)}.txt")


def show(record):
    out = [f"Bericht {record['id']}  ({record['created']})",
           f"Gerät:   {record['install_id']}",
           f"Version: {record.get('app_version')} · {record.get('os_version')}",
           f"Art:     {record['kind']}",
           f"Meldung: {record.get('message')}", ""]
    for key, value in (record.get("payload") or {}).items():
        out += [f"── {key} ──", str(value), ""]
    return "\n".join(out)


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return
    cmd, args = argv[0], argv[1:]
    token = login()

    if cmd in ("list", "errors"):
        limit = int(args[0]) if args else 20
        items = records(token, 'kind = "error"' if cmd == "errors" else None, limit=limit)
        text = table(items)
        print(text)
        save(cmd, text, items)

    elif cmd == "devices":
        items = records(token, limit=2000)
        devices = {}
        for r in items:  # neueste zuerst
            d = devices.setdefault(r["install_id"], {"last": r["created"], "version": r.get("app_version"),
                                                     "os": r.get("os_version"), "errors": 0, "reports": 0})
            d["reports"] += 1
            d["errors"] += r["kind"] == "error"
        text = "\n".join(f"{i}  v{d['version']:<7} zuletzt {d['last'][:19]}  {d['reports']} Berichte, "
                         f"{d['errors']} Fehler  · {d['os']}" for i, d in devices.items()) or "(keine Geräte)"
        print(text)
        save("devices", text, devices)

    elif cmd == "show" and args:
        record = call("GET", f"/api/collections/reports/records/{args[0]}", token)
        text = show(record)
        print(text)
        save(f"show-{args[0]}", text, record)

    elif cmd == "request" and args and args[0] in ("diagnostics", "update"):
        install_id = args[1] if len(args) > 1 else ""
        created = call("POST", "/api/collections/requests/records", token,
                       body={"kind": args[0], "install_id": install_id})
        print(f"Anfrage „{args[0]}“ für {install_id or 'alle Geräte'} angelegt ({created['id']}). "
              "Die App holt sie innerhalb von 15 Minuten ab.")

    elif cmd == "sync":
        items = records(token, sort="created", limit=100000)
        OUT_DIR.mkdir(exist_ok=True)
        (OUT_DIR / "reports.json").write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"{len(items)} Berichte → {OUT_DIR / 'reports.json'}")

    elif cmd == "delete-tests":
        items = records(token, 'kind = "test"', limit=1000)
        for r in items:
            call("DELETE", f"/api/collections/reports/records/{r['id']}", token)
        print(f"{len(items)} Probeberichte gelöscht")

    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    main(sys.argv[1:])
