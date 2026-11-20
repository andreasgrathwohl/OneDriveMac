#!/usr/bin/env python3
"""Fehlerberichte von OneDrive Opener abfragen (Berichts-Server, siehe server/docker-compose.yml).

Liest nur im Heimnetz (über den Tunnel ist das Lesen gesperrt). Zugangsdaten des Lesekontos:
.secrets/reader.txt im Repo (nicht versioniert) – Zeile 1 E-Mail, Zeile 2 Passwort (oder ODO_READER_FILE).
Ausgaben werden zusätzlich in reports-output/ gespeichert (nicht versioniert).

  python Tools/reports.py list [N]            letzte N Berichte (Standard 20)
  python Tools/reports.py errors [N]          letzte N Fehler
  python Tools/reports.py saves [N]           letzte N Speicher-Messungen (slow_save, save_stats,
                                              save_probe, save_monitor, save_guard) und OneDrive-Zustand
                                              (onedrive_health) mit den wichtigsten Werten
  python Tools/reports.py devices             Geräte mit Version und letzter Meldung
  python Tools/reports.py show ID             einen Bericht vollständig (Protokoll, Pfade)
  python Tools/reports.py request diagnostics|update [INSTALL_ID]
                                              Anfrage an ein Gerät oder (ohne ID) an alle
  python Tools/reports.py request inspect <pfad> INSTALL_ID      Sync-Rohwerte einer Datei
  python Tools/reports.py request list <ordner> INSTALL_ID       Ordner mit Sync-Flags je Datei
  python Tools/reports.py request recent|office-docs|synctest INSTALL_ID
                                              Ferndiagnose (nur mit Zielgerät; synctest legt kurz
                                              eine Testdatei an und löscht sie); Pfade nur im
                                              OneDrive-Ordner. Ergebnis: „diag“ oder „show ID“.
  python Tools/reports.py diag [N]            letzte N Diagnose-Ergebnisse (kind = "diag_result")
  python Tools/reports.py sync                alle Berichte nach reports-output/reports.json
  python Tools/reports.py delete-tests        Probeberichte (kind = "test") löschen
"""
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

BASE = os.environ.get("ODO_SERVER", "http://grathwohl-server.local:8095")


def _ipv4(base):
    """Port 8095 ist nur über IPv4 freigegeben – .local-Namen lösen oft zuerst zu IPv6 auf (Timeout)."""
    parts = urllib.parse.urlsplit(base)
    if not (parts.hostname or "").endswith(".local"):
        return base
    try:
        ip = socket.getaddrinfo(parts.hostname, parts.port or 80, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    except OSError:
        return base
    return parts._replace(netloc=f"{ip}:{parts.port}" if parts.port else ip).geturl()


BASE = _ipv4(BASE)
REPO = Path(__file__).resolve().parent.parent
READER_FILE = Path(os.environ.get("ODO_READER_FILE", REPO / ".secrets" / "reader.txt"))
# Administrator (nur für „migrate“): Zeile 1 E-Mail, Zeile 2 Passwort – wie PB_SUPERUSER_* auf dem Server.
ADMIN_FILE = Path(os.environ.get("ODO_ADMIN_FILE", REPO / ".secrets" / "pb-admin.txt"))
OUT_DIR = REPO / "reports-output"
# Ferndiagnose-Bausteine (lesend; synctest legt eine Testdatei an und löscht sie wieder).
DIAG_KINDS = ("inspect", "list", "recent", "office-docs", "synctest")
REQUEST_KINDS = ("diagnostics", "update") + DIAG_KINDS


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


def _credentials(path):
    if not path.exists():
        sys.exit(f"Zugangsdaten fehlen: {path} (Zeile 1 E-Mail, Zeile 2 Passwort)")
    lines = [l.strip() for l in path.read_text(encoding="utf-8-sig").splitlines() if l.strip()]
    if len(lines) < 2:
        sys.exit(f"{path}: Zeile 1 E-Mail, Zeile 2 Passwort erwartet")
    return lines[0], lines[1]


def login():
    email, password = _credentials(READER_FILE)
    result = call("POST", "/api/collections/readers/auth-with-password",
                  body={"identity": email, "password": password})
    return result["token"]


# Felder, die die laufende Datenbank haben muss. Die Erst-Migration in server/docker-compose.yml läuft nur
# beim allerersten Start – spätere Felder kommen über „migrate“ dazu (idempotent).
SCHEMA_ADDITIONS = {
    "requests": [{"type": "text", "name": "arg", "max": 1000}],
}


def migrate():
    email, password = _credentials(ADMIN_FILE)
    token = call("POST", "/api/collections/_superusers/auth-with-password",
                 body={"identity": email, "password": password})["token"]
    for name, wanted in SCHEMA_ADDITIONS.items():
        collection = call("GET", f"/api/collections/{name}", token)
        have = {f["name"] for f in collection.get("fields", [])}
        missing = [f for f in wanted if f["name"] not in have]
        if not missing:
            print(f"{name}: alle Felder vorhanden ({', '.join(f['name'] for f in wanted)})")
            continue
        call("PATCH", f"/api/collections/{collection['id']}", token,
             body={"fields": collection["fields"] + missing})
        print(f"{name}: Feld(er) ergänzt: {', '.join(f['name'] for f in missing)}")


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
        text = json.dumps(value, ensure_ascii=False, indent=2) if isinstance(value, (list, dict)) else str(value)
        out += [f"── {key} ──", text, ""]
    return "\n".join(out)


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return
    cmd, args = argv[0], argv[1:]
    if cmd == "migrate":
        migrate()
        return
    token = login()

    if cmd in ("list", "errors"):
        limit = int(args[0]) if args else 20
        items = records(token, 'kind = "error"' if cmd == "errors" else None, limit=limit)
        text = table(items)
        print(text)
        save(cmd, text, items)

    elif cmd == "saves":
        limit = int(args[0]) if args else 20
        items = records(token, 'kind ~ "save" || kind = "onedrive_health"', limit=limit)
        keys = ("duration_s", "outcome", "opened_by_app", "file_size_kb", "status_texts", "network",
                "network_usage", "offline_s", "asleep_s", "office_version", "all", "via_app", "other", "buckets",
                "state", "status_text", "texts", "detail", "before", "onedrive_folders",
                "problem", "title_state", "title_text", "saved", "unsaved_min", "open_min")
        out = []
        for r in items:
            out.append(table([r]))
            payload = r.get("payload") or {}
            for key in keys:
                if key in payload and payload[key] not in ("", None):
                    value = str(payload[key]).replace("\n", "\n" + " " * 19)
                    out.append(f"    {key:<14} {value}")
            out.append("")
        text = "\n".join(out) or "(keine Messungen)"
        print(text)
        save("saves", text, items)

    elif cmd == "devices":
        items = records(token, limit=2000)
        devices = {}
        for r in items:  # neueste zuerst
            if r["kind"] == "test":
                continue
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

    elif cmd == "request" and args and args[0] in REQUEST_KINDS:
        kind = args[0]
        rest = args[1:]
        # Ferndiagnose-Bausteine nehmen einen Pfad; sie laufen nur mit Ziel-Gerät (nie „alle“).
        diag = kind in DIAG_KINDS
        if diag and kind in ("inspect", "list"):
            arg, install_id = (rest + ["", ""])[0], (rest[1] if len(rest) > 1 else "")
        else:
            arg, install_id = "", (rest[0] if rest else "")
        if diag and not install_id:
            print(f"„{kind}“ braucht ein Zielgerät (install_id) – „devices“ zeigt sie.")
            sys.exit(1)
        created = call("POST", "/api/collections/requests/records", token,
                       body={"kind": kind, "arg": arg, "install_id": install_id})
        ziel = install_id or "alle Geräte"
        print(f"Anfrage „{kind}{(' ' + arg) if arg else ''}“ für {ziel} angelegt ({created['id']}). "
              "Die App holt sie innerhalb von 15 Minuten ab. Ergebnis später mit „diag“ bzw. „show ID“.")

    elif cmd == "diag":
        limit = int(args[0]) if args else 10
        items = records(token, 'kind = "diag_result"', limit=limit)
        text = "\n\n".join(show(r) for r in items) or "(keine Diagnose-Ergebnisse)"
        print(text)
        save("diag", text, items)
        # Erledigte Anfragen löschen: Die Tabelle „requests“ ist für die App ohne Anmeldung lesbar,
        # und „arg“ enthält Ordner- und Dateinamen – die sollen dort nicht stehen bleiben.
        done = {(r.get("payload") or {}).get("request_id") for r in items} - {None, ""}
        for request_id in done:
            try:
                call("DELETE", f"/api/collections/requests/records/{request_id}", token)
            except SystemExit:
                pass  # schon gelöscht
        if done:
            print(f"{len(done)} erledigte Anfrage(n) aus „requests“ gelöscht.")

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
