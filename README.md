# OneDrive Opener

Menüleisten-App für macOS, die Office-Dokumente aus OneDrive-/SharePoint-Sync-Ordnern
so öffnet, dass AutoSpeichern funktioniert – egal ob sie per Doppelklick im Finder oder
über „Öffnen mit“ gestartet werden.

## Problem

Wird eine Office-Datei (Word, Excel, PowerPoint) aus dem lokalen OneDrive-Ordner im
Finder per Doppelklick geöffnet, erkennt Office die Cloud-Herkunft der Datei nicht.
Die Titelleiste zeigt „Auf meinem Mac gespeichert“, AutoSpeichern ist ausgeschaltet.
Öffnet man dieselbe Datei dagegen aus Office heraus über den Online-Speicherort (z. B.
über „Zuletzt verwendet“ oder „Öffnen“ → OneDrive), funktioniert AutoSpeichern
einwandfrei. Der Unterschied: Office braucht dafür die Web-Adresse der Datei, nicht
nur den lokalen Pfad.

**OneDrive Opener** schließt diese Lücke. Die App registriert sich für die gängigen
Office-Dateitypen (docx/docm, xlsx/xlsm/xlsb, pptx/pptm), sowohl als Eintrag in
„Öffnen mit“ als auch – optional – als Standard-App für Doppelklick. Wird eine Datei
über sie geöffnet, ermittelt sie die passende Web-Adresse und übergibt die Datei an
Word/Excel/PowerPoint über eine Office-URI (`ms-word:ofe%7Cor%7C…%7Cct%7C…%7Ccid%7C…%7Cu%7C<URL>` – dasselbe Format wie „In Desktop-App öffnen“ in OneDrive im Web; die dokumentierte Kurzform `ms-word:ofe|u|<URL>` ignoriert Word für Mac – bzw. `ms-excel:…`,
`ms-powerpoint:…`) statt über den lokalen Pfad. Office öffnet die Datei dann online,
AutoSpeichern ist aktiv.

### Ablauf beim Öffnen einer Datei

1. Datei kommt bei OneDrive Opener an (Doppelklick oder „Öffnen mit“).
2. Ist die Weiterleitung deaktiviert, wird ⌥ (Wahltaste) beim Doppelklick gedrückt
   gehalten, oder handelt es sich um eine Office-Sperrdatei (Name beginnt mit `~$`),
   wird die Datei direkt lokal in Word/Excel/PowerPoint geöffnet – ohne Umweg.
3. Andernfalls versucht die App, den lokalen Pfad einer OneDrive-/SharePoint-Web-Adresse
   zuzuordnen (siehe unten). Gelingt das nicht, wird die Datei ebenfalls lokal geöffnet.
4. Ist eine Zuordnung gefunden, wird der Synchronisierungsstatus geprüft:
   - Steht noch ein Upload aus, zeigt die App ein Wartefenster und prüft erneut
     (bis zu der in den Einstellungen unter **Allgemein → Synchronisierung → Auf ausstehenden Upload warten** konfigurierten Wartezeit).
   - Bei einem ungelösten Sync-Konflikt oder wenn der Upload nach der Wartezeit immer
     noch aussteht, fragt ein Dialog mit den Buttons **„Ohne AutoSpeichern öffnen"**, **„Weiter warten"**, **„Trotzdem mit AutoSpeichern öffnen"** und **„Abbrechen"** nach.
   - Ist die Datei synchronisiert (oder lässt sich der Status nicht ermitteln), öffnet
     die App sie online über die Office-URI.
5. Schlägt das Öffnen über die Office-URI fehl, öffnet die App die Datei ersatzweise lokal.

Alte Binärformate (`.doc`, `.xls`, `.ppt`) werden bewusst nicht beansprucht – sie
unterstützen ohnehin kein AutoSpeichern.

## Installation

Repository: https://github.com/andreasgrathwohl/OneDriveMac (öffentlich, keine Anmeldung nötig)

### Variante A: Fertige App herunterladen (ohne Entwicklerwerkzeuge)

1. Unter [Releases](https://github.com/andreasgrathwohl/OneDriveMac/releases/latest) die
   Datei `OneDriveOpener-<Version>.zip` herunterladen und per Doppelklick entpacken.
2. `OneDrive Opener.app` in den Ordner **Programme** (`/Applications`) ziehen.
3. Die App ist nicht von Apple notarisiert, deshalb blockiert macOS den ersten Start.
   Einmalig im Terminal freigeben:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/OneDrive Opener.app" && open "/Applications/OneDrive Opener.app"
   ```

   Alternativ: App doppelklicken, Meldung schließen, dann **Systemeinstellungen →
   Datenschutz & Sicherheit → „Trotzdem öffnen”**.
4. Die App richtet sich beim ersten Start automatisch ein (Standard-App, Autostart) – es sind keine
   weiteren Schritte nötig. macOS kann dabei einmalig Bestätigungen verlangen – erlauben.

Die ZIP-Dateien werden automatisch von GitHub Actions auf macOS gebaut
(`.github/workflows/build.yml`).

### Variante B: Selbst bauen

### Schritt 1: Terminal öffnen

Programme → Dienstprogramme → Terminal.

### Schritt 2: Xcode Command Line Tools (nur beim ersten Mal nötig)

Im Terminal:

```sh
xcode-select --install
```

Das Installationsfenster öffnet sich – warten, bis die Installation abgeschlossen ist
(je nach Internetverbindung einige Minuten). Fehlen die Command Line Tools noch, stößt
auch `install-mac.sh` (Schritt 3) diesen Dialog automatisch an, bricht danach aber ab;
das Skript muss dann nach Abschluss der Installation erneut gestartet werden.

### Schritt 3: Installieren

```bash
curl -fsSL https://raw.githubusercontent.com/andreasgrathwohl/OneDriveMac/main/install-mac.sh | bash -s -- https://github.com/andreasgrathwohl/OneDriveMac.git
```

Alternativ, gleichwertig:

```bash
git clone https://github.com/andreasgrathwohl/OneDriveMac.git ~/Developer/OneDriveMac && bash ~/Developer/OneDriveMac/install-mac.sh
```

Das lädt den Code nach `~/Developer/OneDriveMac`, baut daraus ein Universal-App-Bundle
(Apple Silicon + Intel) und kopiert es nach `/Applications`. Ist `/Applications` für
den angemeldeten Benutzer nicht beschreibbar, fragt macOS zwischendurch nach dem
**Administrator-Passwort** (sudo). Am Ende startet die App automatisch, und das Symbol
erscheint oben rechts in der Menüleiste.

### Schritt 4: Einrichtung

Beim ersten Start aus `/Applications` richtet OneDrive Opener sich automatisch als Standard-App
für Word-/Excel-/PowerPoint-Dateien ein – es sind keine Schritte nötig. macOS kann dabei einmalig
eine Bestätigung verlangen („OneDrive Opener möchte Microsoft Word steuern” – erlauben).

Zusätzlich prüfen, dass **„Beim Anmelden automatisch starten”** in den
**Einstellungen → Allgemein** aktiviert ist. Bei einer frischen Installation aus `/Applications`
wird das beim ersten Start automatisch eingeschaltet; auf macOS 13 und neuer erscheint der
Eintrag zusätzlich unter **Systemeinstellungen → Allgemein → Anmeldeobjekte**.

### Schritt 5: Test

Eine `.docx`-Datei aus dem OneDrive-Ordner im Finder doppelklicken. Word sollte die
Datei öffnen und in der Titelleiste den Dateinamen anzeigen (nicht „Auf meinem Mac
gespeichert“), AutoSpeichern ist eingeschaltet. Im Zweifel über das Menüleisten-Symbol
→ „Protokoll anzeigen …“ nachsehen, ob die Datei online geöffnet wurde.

### Aktualisieren

```sh
bash ~/Developer/OneDriveMac/install-mac.sh
```

Aktualisiert das lokale Repository (`git pull`) und baut/installiert die App neu.
Läuft die App gerade, wird sie dafür kurz beendet und danach neu gestartet.

### Manueller Build mit eigener Signatur (fortgeschritten)

`install-mac.sh` baut mit einer Ad-hoc-Signatur. Für eine Verteilung an mehrere
MacBooks ohne Gatekeeper-Warnung empfiehlt sich ein signierter Build direkt mit
`build.sh` (Details zu Signierung/Notarisierung siehe „Signierung & Notarisierung“
weiter unten):

```sh
cd ~/Developer/OneDriveMac
BUNDLE_ID=de.firma.onedriveopener \
SIGN_IDENTITY="Developer ID Application: Firma GmbH (TEAMID)" \
./build.sh install
```

| Variable | Bedeutung | Standard |
|---|---|---|
| `BUNDLE_ID` | Bundle-Identifier der App (auch relevant für MDM-Einstellungen, s. u.) | `de.onedriveopener.app` |
| `SIGN_IDENTITY` | Signatur-Identität, z. B. `"Developer ID Application: Firma GmbH (TEAMID)"` | Ad-hoc-Signatur (`-`) |

Wichtig: Die App muss unter `/Applications` liegen, damit macOS (Launch Services) sie
zuverlässig als Standard-App bzw. unter „Öffnen mit“ anbietet. `./build.sh install`
erledigt das automatisch (inkl. Registrierung über `lsregister`); bei manueller
Installation die App entsprechend nach `/Applications` kopieren.

### Deinstallation

1. In den **Einstellungen → Allgemein → Standard-App → Zurück zu Office** klicken – das trägt Word, Excel und
   PowerPoint wieder als Standard-App für Doppelklick ein und schaltet die Überwachung
   der Standard-App-Zuordnung aus.
2. OneDrive Opener über das Menüleisten-Symbol → **„OneDrive Opener beenden”** beenden.
3. Die App aus `/Applications` löschen (`/Applications/OneDrive Opener.app`).
4. Optional aufräumen:

   ```sh
   rm -rf ~/Developer/OneDriveMac ~/Library/Logs/OneDriveOpener
   defaults delete de.onedriveopener.app
   ```

   (`de.onedriveopener.app` ist die Standard-Bundle-ID aus `build.sh`; wurde mit einer
   eigenen `BUNDLE_ID` gebaut, stattdessen diesen Wert verwenden.)

## Voraussetzungen

- macOS 12 (Monterey) oder neuer
- Microsoft Office für Mac (Word, Excel, PowerPoint)
- Microsoft OneDrive-Client, mit dem persönlichen und/oder geschäftlichen Konten
  synchronisiert wird
- Zum Bauen: Xcode oder die Xcode Command Line Tools
  (`xcode-select --install`)

## Einrichtung

Bei jedem ersten Start ohne übergebene Datei öffnet sich automatisch das
Einstellungsfenster (danach nicht mehr). Es lässt sich jederzeit über das Menüleisten-
Symbol → „Einstellungen …” erneut öffnen. Die Einstellungen sind in drei Reiter aufgeteilt:

### Allgemein

- **Statusanzeige** mit farbigem Symbol und Erklärung, sowie Button zur raschen Behebung (z. B. „Für Doppelklick aktivieren”, „Reparieren” oder „Fortsetzen”).
- **„Office-Dateien mit AutoSpeichern öffnen”**: Hauptschalter. Ausgeschaltet öffnet OneDrive Opener alle Dateien lokal (entspricht `Enabled = false`).
- **„Beim Anmelden automatisch starten”**: Autostart-Einstellung.
- **Standard-App** – Bereich „Doppelklick im Finder”:
  - Button **„Aktivieren”** (wenn noch nicht eingerichtet) oder **„Zurück zu Office”** (wenn OneDrive Opener aktuell Standard-App ist)
  - Toggle **„Nach Office-Updates automatisch wiederherstellen”**: Schaltet die Überwachung ein (siehe „Schutz vor Office-Updates” weiter unten)
- **Synchronisierung** – Bereich „Auf ausstehenden Upload warten”: Wartezeit in Sekunden (0–120, Standard 15), bevor bei einem ausstehenden Upload nachgefragt wird.

### Ordner

- **„Erkannte OneDrive-Ordner”**: Zeigt automatisch erkannte Zuordnungen mit Badges „AutoSpeichern” bzw. „Ohne AutoSpeichern” (geschätzte Zuordnungen); Hover zeigt den lokalen Pfad und die Web-Adresse; Button **„Neu einlesen”** aktualisiert die Anzeige.
- **„Eigene Zuordnungen”**: Manuell hinzugefügte Zuordnungen (haben Vorrang vor automatischer Erkennung). Button **„Zuordnung hinzufügen …”** öffnet ein Fenster zum Hinzufügen; ein Minus-Button entfernt Zuordnungen.
- **„Unsichere Ordner trotzdem mit AutoSpeichern öffnen”**: Toggle für geschätzte Zuordnungen (wird nur angezeigt, wenn solche vorhanden sind).

### Fehlerbehebung

- **„Protokoll anzeigen …”**: Öffnet die Log-Datei.
- **„In Zwischenablage kopieren”**: Erstellt den Diagnosebericht (hilfreiche für Support).
- **„Standard-App je Dateityp”**: Zeigt aktuellen Status der Zuordnungen mit Button **„Jetzt prüfen”** für manuelle Überprüfung.
- **„Technische Details”**: OneDrive-Ordner und deren Zuordnungen (zur Fehlersuche).

### Sonstiges

- **⌥ (Wahltaste)**: Beim Doppelklick gedrückt halten, um eine Datei unabhängig von
  den Einstellungen sofort lokal zu öffnen.

## Menüleisten-Symbol & Protokoll

### Symbol

Das Symbol oben rechts in der Menüleiste zeigt den aktuellen Zustand an (Tooltip beim
Darüberfahren mit der Maus zeigt denselben Status als Text):

| Symbol (SF-Symbol-Name) | Bedeutung |
|---|---|
| Wolke mit Häkchen (`checkmark.icloud`) | Aktiv – Online-Öffnen eingeschaltet, Standard-App-Zuordnung in Ordnung |
| Wolke (`icloud`) | Bereit – nur über „Öffnen mit” aktiv; Doppelklick noch ohne AutoSpeichern |
| Wolke mit Ausrufezeichen (`exclamationmark.icloud`) | Office hat den Doppelklick übernommen – Standard-App-Zuordnung wurde verloren |
| Durchgestrichene Wolke (`icloud.slash`) | Pausiert – Online-Öffnen ist deaktiviert |

### Menü

Ein Klick auf das Symbol zeigt:

- Statuszeile mit Titel und Erklärung (Klick öffnet Einstellungen)
- Ein-Klick-Aktion zum Beheben des Status: „Für Doppelklick aktivieren” (Bereit), „Reparieren” (Problem), oder „Fortsetzen” (Pausiert)
- „Zuletzt geöffnet”-Liste (bis zu 5 Dateien, mit Kennzeichnung „mit AutoSpeichern” oder „ohne AutoSpeichern”; Klick öffnet Datei erneut; ⌥ gedrückt halten zum Öffnen ohne AutoSpeichern)
- „Pausieren” oder „Fortsetzen” (zum Umschalten der Online-Öffnung)
- „Einstellungen …” (⌘,)
- Submenu „Fehlerbehebung”:
  - „Protokoll anzeigen …” (⌘L)
  - „Diagnosebericht kopieren”
  - „Standard-App jetzt prüfen”
  - Info-Zeilen: Version, Doppelklick-Status (z. B. „Doppelklick: 6 von 6 Dateitypen”), Überwachungsstatus, Anzahl erkannter OneDrive-Ordner
- „OneDrive Opener beenden”

### Protokollfenster

Menü → **„Protokoll anzeigen …“** öffnet ein Fenster mit den Protokollzeilen, das sich
laufend aktualisiert (live). Funktionen:

- **Filtern …**: Textfilter über die angezeigten Zeilen
- **Nur Fehler**: zeigt nur Zeilen mit `[FEHLER]`
- **Kopieren**: kopiert die aktuell angezeigten (gefilterten) Zeilen in die Zwischenablage
- **Im Finder zeigen**: öffnet den Ordner mit der Log-Datei im Finder
- **Leeren**: löscht das Protokoll (Fenster und Datei)

Die Protokolldatei liegt unter `~/Library/Logs/OneDriveOpener/OneDriveOpener.log`.
Ab 2 MB wird sie automatisch nach `OneDriveOpener.1.log` im selben Ordner rotiert,
damit sie nicht unbegrenzt wächst.

## Word-Integration

Während Word in den Vordergrund kommt, fragt OneDrive Opener per AppleScript (kein Makro-Add-in
nötig) alle paar Sekunden nach, welche Dokumente gerade offen sind. Ein Dokument aus einem
OneDrive-Ordner, das lokal geöffnet ist („Auf meinem Mac gespeichert") und keine ungespeicherten
Änderungen hat, wird automatisch geschlossen und sofort mit AutoSpeichern aus der Cloud neu geöffnet.
Das gilt auch für Dokumente, die über „Zuletzt verwendet", das Dock, Spotlight oder „Speichern unter"
in den OneDrive-Ordner geladen werden.

Dokumente mit ungespeicherten Änderungen werden nicht angefasst. Dateien, die bewusst lokal geöffnet
wurden (⌥ beim Doppelklick oder Dialog „Ohne AutoSpeichern öffnen"), bleiben lokal. Ist OneDrive
noch dabei, die Datei hochzuladen (max. 2 Minuten Wartezeit), wartet die App ab.

**Einstellung**: **Einstellungen → Allgemein → Word → „Lokal geöffnete Dokumente automatisch mit
AutoSpeichern öffnen"** (standardmäßig an). Aktuell nur Word; Excel und PowerPoint folgen evtl. später.

**macOS-Berechtigung**: Beim ersten Öffnen fragt macOS „OneDrive Opener möchte Microsoft Word steuern"
– erlauben. Falls abgelehnt: **Systemeinstellungen → Datenschutz & Sicherheit → Automation → OneDrive Opener
→ Microsoft Word** hakchen.

## Automatische Updates

OneDrive Opener prüft 1 Minute nach dem Start und danach alle 6 Stunden die GitHub-Releases des Repositorys
(öffentlich, keine Anmeldung nötig). Ist eine neuere Version verfügbar, wird sie heruntergeladen, verifiziert
(Bundle-ID und Signatur müssen stimmen), schließt die laufende App, ersetzt sich selbst und startet neu – ohne
Benutzereingriff. Die lokal kopierten Office-Symbole werden beibehalten.

**Einstellungen**:
- **„Updates automatisch installieren"** (standardmäßig an): neue Versionen sofort installieren
- **„Jetzt suchen"** Button: Prüfung on-demand erzwingen
- Menü **Fehlerbehebung → „Nach Updates suchen"**
- Menü zeigt **„Update auf Version X installieren"** wenn Auto-Install aus ist

**Voraussetzung**: Schreibrechte für die App in `/Applications`. Sind diese nicht vorhanden, zeigt der
Status „bitte manuell installieren".

**Hinweis**: Da die App ad-hoc signiert ist, kann macOS nach dem Update erneut Berechtigungen abfragen
(Word-Steuerung, Anmeldeobjekt) – einfach erlauben.

## Schutz vor Office-Updates

Microsoft-Office-Updates (und teils schon ein einfacher Neustart von Word, Excel oder
PowerPoint) können die Standard-App-Zuordnung für Doppelklick auf Office zurücksetzen.
Ist die Überwachung eingeschaltet (Einstellungen → Allgemein → Standard-App → 
„Nach Office-Updates automatisch wiederherstellen”, bzw. `KeepDefaultHandler`), erkennt
OneDrive Opener das automatisch und stellt sich selbst wieder als Standard-App her –
ohne manuellen Eingriff. Die Überwachung wird zusammen mit „Für Doppelklick aktivieren”
eingeschaltet und mit „Zurück zu Office” wieder ausgeschaltet.

Geprüft wird:

- alle 2 Minuten im Hintergrund,
- beim Start oder Beenden von Word, Excel, PowerPoint, Microsoft AutoUpdate oder dem
  macOS-Installer,
- nach dem Aufwachen aus dem Ruhezustand.

Bei jeder Prüfung vergleicht die App außerdem die Versionsnummern von Word, Excel und
PowerPoint mit den zuletzt gespeicherten Werten. Bei einer Änderung wird
„Office-Update erkannt: …“ ins Protokoll geschrieben und OneDrive Opener meldet sich
sicherheitshalber erneut bei Launch Services an.

Ist die Standard-App-Zuordnung verlorengegangen, versucht die App sofort, sie
wiederherzustellen. Gelingt das nicht (z. B. weil macOS die Änderung ablehnt), wechselt
das Menüleisten-Symbol auf die Warnung (`exclamationmark.icloud`). Bei den oben
genannten Ereignissen wird die Wiederherstellung dann bei jedem Ereignis erneut
versucht; die reguläre Zwei-Minuten-Prüfung wartet nach einem Fehlschlag dagegen erst
30 Minuten, bevor sie es selbst erneut versucht, damit macOS nicht ständig mit
Rückfragen aufwartet.

**Hinweis**: Solange die Überwachung eingeschaltet ist, macht sie eine manuelle
Änderung der Standard-App im Finder (Datei markieren → „Informationen“ → „Öffnen mit“
→ „Alle ändern …“) automatisch wieder rückgängig. Um Word/Excel/PowerPoint dauerhaft
wieder als Standard-App zu setzen, in den Einstellungen zuerst die Überwachung
ausschalten oder „Zurück auf Office“ verwenden.

## Zuordnung lokaler Ordner → Web-Adresse

Damit die App eine Datei online öffnen kann, muss sie wissen, zu welcher Web-Adresse
(OneDrive- bzw. SharePoint-Bibliothek) ein lokaler OneDrive-Ordner gehört.

### Automatische Erkennung

Die App liest dazu die Konfigurationsdateien des OneDrive-Clients unter
`~/Library/Application Support/OneDrive/settings` (bzw. bei der App-Store-Version
im sandboxten Container `~/Library/Containers/com.microsoft.OneDrive-mac/Data/…`).
Dieses Dateiformat ist von Microsoft nicht dokumentiert; die App wertet es daher
nach der bewährten, quelloffenen VBA-Implementierung „GetLocalPath” von Guido
Witt-Dörring (MIT, https://gist.github.com/guwidoe/038398b6be1b16c458365716a921814d)
aus:

- Pro Konto (`settings/Personal`, `settings/Business1`…`Business9`) werden gelesen:
  - `global.ini` → `cid`
  - `<cid>.ini` → Zeilen `library`/`libraryScope` (Personal) oder `libraryScope`,
    `libraryFolder`, `AddedScope` (Business) mit lokalem Pfad und Sync-ID
  - `ClientPolicy.ini` / `ClientPolicy_<libID><siteID>[<lnkID>].ini` → `DavUrlNamespace`
    (Web-URL)
  - `GroupFolders.ini` (bei persönlichen Konten)
- Der in der `.ini` stehende lokale Pfad wird über die versteckte Datei
  `.849C9593-D756-4E56-8D6E-42412F2A707B` (Sync-ID) in `~/Library/CloudStorage`
  gefunden; Fallback: Abgleich über den Ordnernamen.

#### Geschätzte Zuordnungen

Zuordnungen, deren lokaler Ordner oder Web-Pfad nur geschätzt werden können, sind
im Reiter **Ordner** mit dem Badge **„Ohne AutoSpeichern”** (in Orange) gekennzeichnet. Dies betrifft
synchronisierte Unterordner einer Bibliothek (`libraryFolder`), Verknüpfungen in
„Meine Dateien” (`AddedScope`), gemeinsame Ordner von persönlichen Konten
(`GroupFolders.ini`), sowie den Hauptordner eines Geschäftskontos, der nur über seinen
Ordnernamen zugeordnet werden konnte (beim privaten Konto ist „OneDrive-Persönlich”
eindeutig und wird mit Badge **„AutoSpeichern”** angezeigt). Grund: Die binäre Ordnerstruktur in `<cid>.dat` wird nicht
ausgewertet.

Dateien in solchen Ordnern werden standardmäßig **lokal** geöffnet (kein AutoSpeichern),
mit einem Protokolleintrag „Zuordnung … ist nur geschätzt … → lokal”, der die
vermutete Adresse enthält. So wird sichergestellt, dass die App niemals eine möglicherweise
falsche Web-Adresse öffnet, was zu „Datei nicht gefunden”-Fehlern in Word führen würde.

Im Reiter **Ordner** erscheint bei vorhandenen geschätzten Zuordnungen zusätzlich ein
Toggle **„Unsichere Ordner trotzdem mit AutoSpeichern öffnen”**. **Empfehlung**: Statt diesen
Schalter zu nutzen, ist es sicherer, für solche Ordner eine manuelle Zuordnung
hinzuzufügen (manuelle Zuordnungen haben immer Vorrang und erscheinen unter **„Eigene Zuordnungen”**).

Verknüpfungs- und gemeinsame Ordner, die nicht auf der obersten Ebene liegen, werden
bis zu 3 Ebenen tief nach Name gesucht; nur ein eindeutiger Treffer wird verwendet.

Im Diagnosebericht (Kommandozeile `--diagnose`) sind solche Einträge mit `[GESCHÄTZT]`
gekennzeichnet; `--resolve` gibt zusätzlich eine Warnzeile aus. Im Reiter **Ordner**
erscheinen sie mit Badge **„Ohne AutoSpeichern"** (in Orange).

Da das Ganze heuristisch ist, kann die Erkennung im Einzelfall danebenliegen oder
einen Ordner offenlassen – dafür gibt es die manuelle Zuordnung (siehe **„Eigene Zuordnungen"**).

### Manuelle Zuordnung

Im Reiter **Ordner** unter **„Eigene Zuordnungen”** lässt sich pro Ordner ein Paar aus 
lokalem Pfad und Web-Adresse hinterlegen. Über den Button **„Zuordnung hinzufügen …”** öffnet sich ein Fenster 
zum Hinzufügen neuer Zuordnungen; per Minus-Button lassen sich Zuordnungen entfernen. 
Manuelle Zuordnungen haben immer Vorrang vor automatisch erkannten – bei gleich langem passendem Pfad
gewinnt die manuelle Zuordnung, ansonsten die jeweils längste (spezifischste)
passende Pfad-Zuordnung.

So findet man die richtige Web-Adresse:

- **Persönliches OneDrive**: Adresse hat die Form
  `https://firma-my.sharepoint.com/personal/vorname_nachname_firma_de/Documents`
  (im Browser bei OneDrive anmelden, Adresszeile des Wurzelordners „Dateien“ kopieren).
- **SharePoint-Bibliothek**: Im Browser zur Dokumentenbibliothek navigieren und die
  Adresse bis einschließlich des Bibliotheksnamens kopieren, z. B.
  `https://firma.sharepoint.com/sites/Team/Freigegebene Dokumente`.

## Verteilung per MDM

Die Einstellungen liegen in `UserDefaults` unter der Bundle-ID der App (Standard
`de.onedriveopener.app`, bzw. der beim Bauen gesetzte `BUNDLE_ID`) und lassen sich
daher zentral per Konfigurationsprofil vorgeben. Verwendete Schlüssel:

| Schlüssel          | Typ                | Bedeutung                                               | Standard |
|---------------------|--------------------|-----------------------------------------------------------|----------|
| `Enabled`           | Bool               | Online-Öffnen aktiviert/deaktiviert                      | `true`   |
| `SyncWaitSeconds`    | Integer            | Wartezeit auf ausstehenden Upload in Sekunden             | `15`     |
| `ManualMappings`     | Array von Dictionaries, je `{“localPath”: “...”, “webURL”: “...”}` | manuelle Ordner-Zuordnungen | `[]` (leer) |
| `KeepDefaultHandler` | Bool               | Überwachung der Standard-App-Zuordnung (siehe „Schutz vor Office-Updates”) ein-/ausschalten | `false` |
| `UseGuessedMappings` | Bool               | Geschätzte Zuordnungen trotzdem online öffnen           | `false`  |
| `WordIntegration`    | Bool               | Lokal geöffnete Word-Dokumente automatisch mit AutoSpeichern neu öffnen | `true`   |
| `AutoUpdate`         | Bool               | Neue Versionen aus GitHub-Releases automatisch installieren | `true`   |
| `UpdateRepository`   | String             | GitHub-Repository (`besitzer/name`) für Updates, z. B. für einen Fork | `”andreasgrathwohl/OneDriveMac”` |
| `OpenMethod`         | String             | Methode zum Öffnen: `officeURI` (default), `appleEvent`, oder `webURL` | `”officeURI”` |

Daneben verwendet die App noch `OfficeVersions` und `LoginItemInitialized` in
`UserDefaults` – das sind rein interne Merker (zuletzt erkannte Office-Versionen bzw.
ob der Autostart beim ersten Start schon gesetzt wurde) und sollten nicht per MDM
vorbelegt werden.

Lokal testen mit `defaults`:

```sh
defaults write de.onedriveopener.app Enabled -bool true
defaults write de.onedriveopener.app SyncWaitSeconds -int 20
```

`ManualMappings` ist ein Array von Dictionaries; dafür eignet sich `PlistBuddy`:

```sh
PLIST=~/Library/Preferences/de.onedriveopener.app.plist
/usr/libexec/PlistBuddy -c "Add :ManualMappings array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ManualMappings:0 dict" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ManualMappings:0:localPath string /Users/max.mustermann/Library/CloudStorage/OneDrive-Firma" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ManualMappings:0:webURL string https://firma.sharepoint.com/sites/Team/Freigegebene Dokumente" "$PLIST"
```

Da lokale Pfade den Benutzernamen enthalten, sind `ManualMappings` meist eher etwas
für Einzelfälle (z. B. Ordner, die per „Verknüpfung zu OneDrive hinzufügen“
eingebunden wurden, siehe unten) als für eine unternehmensweite Vorgabe an alle Macs.
`Enabled` und `SyncWaitSeconds` eignen sich dagegen gut für eine zentrale Vorgabe.

Für ein MDM-Profil (z. B. Jamf „Custom Settings“, Apple Configurator, o. ä.) als
Payload vom Typ `com.apple.ManagedClient.preferences`, Domain = Bundle-ID der App:

```xml
<key>PayloadContent</key>
<dict>
    <key>de.onedriveopener.app</key>
    <dict>
        <key>Forced</key>
        <array>
            <dict>
                <key>mcx_preference_settings</key>
                <dict>
                    <key>Enabled</key>
                    <true/>
                    <key>SyncWaitSeconds</key>
                    <integer>20</integer>
                    <key>ManualMappings</key>
                    <array>
                        <dict>
                            <key>localPath</key>
                            <string>/Users/max.mustermann/Library/CloudStorage/OneDrive-Firma</string>
                            <key>webURL</key>
                            <string>https://firma.sharepoint.com/sites/Team/Freigegebene Dokumente</string>
                        </dict>
                    </array>
                </dict>
            </dict>
        </array>
    </dict>
</dict>
```

### Signierung & Notarisierung

Ohne gültige `Developer ID Application`-Signatur (und Notarisierung durch Apple)
blockiert Gatekeeper die App auf anderen Macs mit einer Warnung, dass sie nicht
verifiziert werden konnte. Für eine Verteilung an mehrere MacBooks daher unbedingt
mit `SIGN_IDENTITY` einer eigenen „Developer ID Application“-Zertifikatskennung bauen
und die App anschließend bei Apple notarisieren (`xcrun notarytool submit …` bzw.
`xcrun stapler staple`).

Für reine Testzwecke auf einzelnen Rechnern lässt sich die Gatekeeper-Quarantäne
stattdessen manuell entfernen:

```sh
xattr -dr com.apple.quarantine "/Applications/OneDrive Opener.app"
```

Das ist kein Ersatz für eine ordentliche Signierung/Notarisierung und sollte nicht
für den produktiven Rollout verwendet werden.

## Fehlersuche

- Menüleisten-Symbol → Fehlerbehebung → **„Diagnosebericht kopieren”** kopiert einen
  Diagnosebericht (erkannte OneDrive-Ordner, ausgelesene Konfigurationsdateien,
  automatisch erkannte und manuelle Zuordnungen, Status der Standard-App-Zuordnung)
  in die Zwischenablage – hilfreich zum Einfügen in eine Support-Anfrage.
- Menüleisten-Symbol → Fehlerbehebung → **„Protokoll anzeigen …”** (⌘L) öffnet die Log-Datei unter
  `~/Library/Logs/OneDriveOpener/OneDriveOpener.log`.
- Alternativ: **Einstellungen → Fehlerbehebung → Protokoll anzeigen …** oder **In Zwischenablage kopieren**.
- Kommandozeile (z. B. per Terminal oder Remote-Management):

  ```sh
  "/Applications/OneDrive Opener.app/Contents/MacOS/OneDriveOpener" --diagnose
  "/Applications/OneDrive Opener.app/Contents/MacOS/OneDriveOpener" --resolve "/Pfad/zur/Datei.docx"
  ```

  `--diagnose` gibt denselben Bericht wie „Diagnose in Zwischenablage kopieren“ auf
  der Konsole aus. `--resolve <Datei>` zeigt für eine konkrete Datei die ermittelte
  Web-Adresse, welche Zuordnung (und Quelle) verwendet wurde, die daraus gebaute
  Office-URI sowie den aktuellen Synchronisierungsstatus.

## Bekannte Einschränkungen

- Das OneDrive-Konfigurationsformat ist von Microsoft nicht dokumentiert. Die
  automatische Zuordnung arbeitet heuristisch und kann falschliegen oder einen
  Ordner nicht erkennen – in dem Fall hilft eine manuelle Zuordnung.
- Synchronisierte Unterordner einer Bibliothek (`libraryFolder`), Verknüpfungen
  die zu „Meine Dateien” hinzugefügt wurden (`AddedScope`), sowie gemeinsame Ordner
  von persönlichen Konten werden nur dann korrekt erkannt, wenn sie auf der obersten
  Ebene liegen oder eindeutig bis zu 3 Ebenen tief nach Name gefunden werden. Andernfalls
  werden diese Zuordnungen mit Badge **„Ohne AutoSpeichern”** gekennzeichnet und Dateien darin lokal geöffnet.
  Eine manuelle Zuordnung oder Aktivierung von **„Unsichere Ordner trotzdem mit AutoSpeichern öffnen”** 
  ist dann nötig (die binäre Ordnerstruktur in `<cid>.dat` wird nicht ausgewertet).
- Kann ein Verknüpfungs- oder Freigabordner überhaupt nicht gefunden werden (z. B.
  weil er umbenannt wurde), fallen Dateien darin unter den OneDrive-Hauptordner und
  erhalten möglicherweise eine falsche Adresse. Im Einstellungsfenster wird in diesem
  Fall ein Hinweis „Ordner nicht gefunden … bitte manuell zuordnen” angezeigt.
- Alte Binärformate (`.doc`, `.xls`, `.ppt`) werden nicht behandelt – sie
  unterstützen ohnehin kein AutoSpeichern, es besteht also kein Nachteil.
- Die Prüfung des Synchronisierungsstatus stützt sich auf die vom File-Provider-
  System gelieferten Werte. Lassen sich diese nicht ermitteln, gilt der Status als
  „unbekannt” und die Datei wird trotzdem online geöffnet (wie bei „synchronisiert”).
- Beim Auslesen der Konfiguration der App-Store-Version von OneDrive (Zugriff auf
  deren sandboxten Container) kann macOS eine Berechtigungsabfrage einblenden, die
  bestätigt werden muss.

## Lizenz

OneDrive Opener steht unter der [MIT-Lizenz](LICENSE).

Die Erkennung der OneDrive-Ordner (`Sources/OneDriveConfig.swift`) ist eine Portierung
von Guido Witt-Dörrings VBA-Modul „GetLocalPath“, ebenfalls MIT-lizenziert – Hinweis
und Lizenztext siehe [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Microsoft, Office, Word, Excel, PowerPoint und OneDrive sind Marken der Microsoft
Corporation. Dieses Projekt steht in keiner Verbindung zu Microsoft.
