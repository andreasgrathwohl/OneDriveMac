GOAL:    Mac-Nutzer mit OneDrive sehen in 15 s: Doppelklick im Finder öffnet Office ohne
         AutoSpeichern – mit OneDrive Opener ist es an. Am Ende kennen sie Icon, Namen und Adresse.
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps, stumm (kein Musikquelle; Nutzer kann Ton nachlegen)
TIME:    15 s x 30 = 450 Frames
LOOK:    Medium: macOS-Oberfläche, nachgebaut mit den echten Texten aus Sources/*.swift.
         Grund #EAF0F7 (UI-Szenen, Endkarte), Markenblau #0A64D8 als Vollfläche nur in Szene 2.
         Tinte #0B1B2E, Zweittext #5B6676. Problem-Akzent #C62828 (nur „aus“ in S1),
         Lösungs-Akzent #1C8C36 (nur „an“ in S3). Icon-Farben exakt aus Tools/MakeIcon.swift
         (#3AA0FF→#0A64D8, Wolke weiß, Falz #BFE0FF, Badge #30C24A).
         Schrift Inter (Ersatz für SF Pro, gebündelt): Titel 900 / 72–150 px / -2 % Laufweite,
         UI 400/700 / 26–34 px. Fensterschatten 0 30 px 60 px rgba(11,27,46,.18), kein Grain.
OBJECTS: Dokument-Datei „Angebot.docx“ (Seite mit Falz, DOCX-Label), Office-Fenster-Titelleiste
         (Ampel, „AutoSpeichern“-Schalter Aus/Ein, Titel „Angebot – Auf meinem Mac gespeichert“
         laut README), macOS-Menüleiste mit Statussymbol checkmark.icloud, das echte Menü
         (Aktiv / Office-Dateien aus OneDrive öffnen mit AutoSpeichern. / Pausieren /
         Einstellungen … / Fehlerbehebung / OneDrive Opener beenden), App-Icon, Mauszeiger 64 px.
MOTION:  Ankunft expo.out 0.5 s, Kamera power2.inOut 0.6 s, Abgang power3.in 0.2 s mit 8 px Blur.
         Klick = Zeiger 1→0.88→1 in 4 Frames, keine Klick-Ringe. Badge-Feder back.out(1.6).
SHOTS:   S1 0–4.0   Datei, Zeiger kommt (0.3–1.0), Doppelklick 1.05/1.25 → Match-Cut auf Fenster
                    (setzt sich 1.05→1), Push 1.12 auf Titelleiste, Zeile „Doppelklick im Finder:
                    AutoSpeichern aus.“ ab 2.35, Blur-Abgang 3.7.
         S2 4.0–7.6 Farbflut zu Blau, Menüleiste fährt ein, Klick aufs Symbol 1.1, Menü klappt
                    aus dem Symbol auf, links „Neu in der Menüleiste:“ + „OneDrive Opener“ je
                    Buchstabe, Abgang 3.25.
         S3 7.6–11.4 Farbflut zurück, gleiche Datei, gleicher Doppelklick → Fenster mit Schalter
                    „Ein“, Zeile „Gleicher Doppelklick: AutoSpeichern an.“, Schalterblau flutet
                    ab 3.4 aus dem Schalter über das Bild.
         S4 11.4–15 Blaue Fläche schrumpft zur Icon-Kachel, Wolke + Dokument, Badge springt,
                    Häkchen zeichnet sich, Wortmarke wischt ein (1.1), Adresse (1.5), hält bis 15.
BANNED:  dunkle Leere, Glow, Partikel, Lila/Blau-Verläufe als Grund, Glas-Karten, Logo in der
         Ecke, Titel über abgedunkeltem Screenshot, Klick-Ringe, Atmen/Pulsieren, alles fadet+
         gleitet hoch, erfundene Office-Texte, Word-/Microsoft-Logos.
QA:      0.9 (Zeiger auf Datei), 2.9 (Fenster + Zeile S1 lesbar), 5.9 (Menü komplett lesbar),
         9.8 (Schalter „Ein“ + Zeile S3), 11.3 (Blau deckt Bild), 13.5 (Endkarte fertig).
