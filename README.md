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
Word/Excel/PowerPoint über eine Office-URI (`ms-word:ofe|u|<URL>` bzw. `ms-excel:…`,
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
     (bis zu der in den Einstellungen konfigurierten Wartezeit).
   - Bei einem ungelösten Sync-Konflikt oder wenn der Upload nach der Wartezeit immer
     noch aussteht, fragt ein Dialog nach: lokal öffnen, weiter warten, trotzdem online
     öffnen oder abbrechen.
   - Ist die Datei synchronisiert (oder lässt sich der Status nicht ermitteln), öffnet
     die App sie online über die Office-URI.
5. Schlägt das Öffnen über die Office-URI fehl, öffnet die App die Datei ersatzweise lokal.

Alte Binärformate (`.doc`, `.xls`, `.ppt`) werden bewusst nicht beansprucht – sie
unterstützen ohnehin kein AutoSpeichern.

## Voraussetzungen

- macOS 12 (Monterey) oder neuer
- Microsoft Office für Mac (Word, Excel, PowerPoint)
- Microsoft OneDrive-Client, mit dem persönlichen und/oder geschäftlichen Konten
  synchronisiert wird
- Zum Bauen: Xcode oder die Xcode Command Line Tools
  (`xcode-select --install`)

## Bauen & Installieren

Im Projektordner:

```sh
./build.sh            # baut build/"OneDrive Opener.app" (Universal: Apple Silicon + Intel)
./build.sh install     # baut zusätzlich und kopiert nach /Applications, registriert bei macOS, startet die App
```

Der Build erzeugt ein Universal-Binary (arm64 + x86_64) mit `swiftc` und signiert es
anschließend. Zwei Umgebungsvariablen steuern das:

| Variable         | Bedeutung                                                                 | Standard |
|-------------------|---------------------------------------------------------------------------|----------|
| `BUNDLE_ID`       | Bundle-Identifier der App (auch relevant für MDM-Einstellungen, s. u.)   | `de.onedriveopener.app` |
| `SIGN_IDENTITY`   | Signatur-Identität, z. B. `"Developer ID Application: Firma GmbH (TEAMID)"` | Ad-hoc-Signatur (`-`) |

Beispiel für eine signierte Version zur Verteilung im Unternehmen:

```sh
BUNDLE_ID=de.firma.onedriveopener \
SIGN_IDENTITY="Developer ID Application: Firma GmbH (TEAMID)" \
./build.sh install
```

Wichtig: Die App muss unter `/Applications` liegen, damit macOS (Launch Services)
sie zuverlässig als Standard-App bzw. unter „Öffnen mit“ anbietet. `./build.sh install`
erledigt das automatisch (inkl. Registrierung über `lsregister`); bei manueller
Installation die App entsprechend nach `/Applications` kopieren.

## Einrichtung

Bei jedem ersten Start ohne übergebene Datei öffnet sich automatisch das
Einstellungsfenster (danach nicht mehr). Es lässt sich jederzeit über das Menüleisten-
Symbol → „Einstellungen …“ erneut öffnen.

- **„Office-Dateien aus OneDrive online öffnen (AutoSpeichern)“**: Hauptschalter.
  Ausgeschaltet öffnet OneDrive Opener alle Dateien lokal (entspricht `Enabled = false`).
- **„Auf ausstehenden Upload warten“**: Wartezeit in Sekunden (0–120, Standard 15),
  bevor bei einem ausstehenden Upload nachgefragt wird.
- **⌥ (Wahltaste)**: Beim Doppelklick gedrückt halten, um eine Datei unabhängig von
  den Einstellungen sofort lokal zu öffnen.
- **„OneDrive Opener als Standard festlegen“**: Macht die App zur Standard-App für
  Doppelklick bei docx/docm/xlsx/xlsm/xlsb/pptx/pptm. Unabhängig davon steht die App
  im Finder immer als Eintrag unter „Öffnen mit“ zur Verfügung – dafür ist dieser
  Schritt nicht nötig.
- **„Zurück auf Office“**: Setzt Word/Excel/PowerPoint wieder als Standard-App
  zurück (siehe auch Deinstallation).

Im unteren Teil des Fensters zeigt „Automatisch erkannte OneDrive-Ordner“ die
gefundenen Zuordnungen sowie Hinweise, falls etwas nicht eindeutig erkannt wurde;
„Neu einlesen“ aktualisiert die Anzeige, „Diagnose kopieren“ erstellt den
Diagnosebericht (siehe Fehlersuche).

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

Da das Ganze heuristisch ist, kann die Erkennung im Einzelfall danebenliegen oder
einen Ordner offenlassen – dafür gibt es die manuelle Zuordnung.

### Manuelle Zuordnung

Im Einstellungsfenster unter „Manuelle Zuordnungen (haben Vorrang)“ lässt sich pro
Ordner ein Paar aus lokalem Pfad und Web-Adresse hinterlegen. Manuelle Zuordnungen
haben immer Vorrang vor automatisch erkannten – bei gleich langem passendem Pfad
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
| `ManualMappings`     | Array von Dictionaries, je `{"localPath": "...", "webURL": "..."}` | manuelle Ordner-Zuordnungen | `[]` (leer) |

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

- Menüleisten-Symbol → **„Diagnose in Zwischenablage kopieren“** kopiert einen
  Diagnosebericht (erkannte OneDrive-Ordner, ausgelesene Konfigurationsdateien,
  automatisch erkannte und manuelle Zuordnungen, Status der Standard-App-Zuordnung)
  in die Zwischenablage – hilfreich zum Einfügen in eine Support-Anfrage.
- Menüleisten-Symbol → **„Protokoll anzeigen“** öffnet die Log-Datei unter
  `~/Library/Logs/OneDriveOpener/OneDriveOpener.log`.
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
- Synchronisierte Unterordner einer Bibliothek (`libraryFolder`) und Verknüpfungen,
  die zu „Meine Dateien” hinzugefügt wurden (`AddedScope`), sowie gemeinsame Ordner
  von persönlichen Konten werden nur dann korrekt erkannt, wenn sie auf der obersten
  Ebene liegen. Andernfalls ist eine manuelle Zuordnung nötig (die binäre Ordnerstruktur
  in `<cid>.dat` wird nicht ausgewertet).
- Alte Binärformate (`.doc`, `.xls`, `.ppt`) werden nicht behandelt – sie
  unterstützen ohnehin kein AutoSpeichern, es besteht also kein Nachteil.
- Die Prüfung des Synchronisierungsstatus stützt sich auf die vom File-Provider-
  System gelieferten Werte. Lassen sich diese nicht ermitteln, gilt der Status als
  „unbekannt” und die Datei wird trotzdem online geöffnet (wie bei „synchronisiert”).
- Beim Auslesen der Konfiguration der App-Store-Version von OneDrive (Zugriff auf
  deren sandboxten Container) kann macOS eine Berechtigungsabfrage einblenden, die
  bestätigt werden muss.

## Deinstallation

1. Im Einstellungsfenster **„Zurück auf Office“** klicken, damit Word, Excel und
   PowerPoint wieder als Standard-App für Doppelklick eingetragen sind.
2. OneDrive Opener über das Menü **„OneDrive Opener beenden“** beenden.
3. Die App aus `/Applications` löschen (`/Applications/OneDrive Opener.app`).
