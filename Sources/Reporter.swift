import AppKit

/// Berichts-Server (PocketBase, siehe `server/docker-compose.yml`). Die App darf dort nur Berichte
/// einliefern und Anfragen lesen – Berichte lesen kann nur das Lesekonto. Leer = Berichte aus.
/// Per MDM/`defaults` überschreibbar (`ReportEndpoint`).
enum ReportBackend {
    static let endpoint = "https://onedrivemac.grathwohl.dev"
}

/// Meldet Fehler automatisch und liefert auf Anfrage von außen (Sammlung `requests`) Diagnoseberichte.
/// Gesendet werden Version, macOS-Version, Fehlermeldung, Pfade/Adressen und Protokollzeilen –
/// keine Dokumentinhalte. Ist der Server nicht erreichbar (z. B. Mac nicht im Heimnetz), werden
/// Berichte zwischengespeichert und später nachgeliefert.
@MainActor
final class Reporter {
    static let shared = Reporter()

    private var recentErrors: [String: Date] = [:]
    private var sentToday = 0
    private var day = Calendar.current.startOfDay(for: Date())
    private var timer: Timer?
    private var flushing = false

    private init() {}

    var isConfigured: Bool { !Settings.reportEndpoint.isEmpty }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in
            Task { @MainActor in await Reporter.shared.poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            Task { @MainActor in
                Reporter.shared.askConsentIfNeeded()
                Reporter.shared.send(kind: "start", message: "Gestartet", details: [:])
                await Reporter.shared.poll()
            }
        }
    }

    /// Einmalig um Zustimmung bitten – vorher wird nichts gesendet.
    func askConsentIfNeeded() {
        guard isConfigured, !Settings.reportConsentDecided, NSApp.modalWindow == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Fehlerberichte an den Entwickler senden?"
        alert.informativeText = """
        Geht beim Öffnen einer Datei etwas schief, kann OneDrive Opener automatisch einen Bericht senden, damit der Fehler behoben werden kann.

        Gesendet werden Fehlermeldungen, App- und macOS-Version, betroffene Datei- und Ordnernamen sowie Protokollzeilen – keine Dokumentinhalte.

        Ändern lässt sich das jederzeit unter Einstellungen → Fehlerbehebung.
        """
        alert.addButton(withTitle: "Erlauben")
        alert.addButton(withTitle: "Nicht erlauben")
        NSApp.activate(ignoringOtherApps: true)
        Settings.sendReports = alert.runModal() == .alertFirstButtonReturn
        Log.info("Fehlerberichte: \(Settings.sendReports ? "erlaubt" : "abgelehnt")")
    }

    /// Von `Log.error` aufgerufen. Gleiche Meldungen höchstens einmal pro Stunde, maximal 30 pro Tag.
    func captureError(_ message: String) {
        guard Settings.sendReports, isConfigured else { return }
        let now = Date()
        if Calendar.current.startOfDay(for: now) != day {
            day = Calendar.current.startOfDay(for: now)
            sentToday = 0
        }
        if let last = recentErrors[message], now.timeIntervalSince(last) < 3600 { return }
        guard sentToday < 30 else { return }
        recentErrors[message] = now
        sentToday += 1
        send(kind: "error", message: message, details: ["log": Log.readTail(40).joined(separator: "\n")])
    }

    func send(kind: String, message: String, details: [String: Any]) {
        guard Settings.sendReports, isConfigured else { return }
        let body: [String: Any] = [
            "install_id": Settings.installID,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "kind": kind,
            // PocketBase zählt Unicode-Zeichen (Dateinamen sind zerlegt: „Ö“ = 2), Grenze 10 000.
            "message": String(String.UnicodeScalarView(message.unicodeScalars.prefix(9000))),
            "payload": details,
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        Task {
            if await post(data) == nil { ReportQueue.add(data) }
        }
    }

    /// Zwischengespeicherte Berichte nachliefern und Anfragen von außen abholen.
    func poll() async {
        guard Settings.sendReports, isConfigured, Connectivity.shared.isOnline else { return }
        await flushQueue()
        await pollRequests()
    }

    private func flushQueue() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        for (file, data) in ReportQueue.pending() {
            guard await post(data) != nil else { return }
            ReportQueue.remove(file)
        }
    }

    /// Anfragen: `diagnostics` (voller Diagnosebericht + Protokoll), `update` (Update suchen).
    private func pollRequests() async {
        guard let since = Settings.lastRequestCreated else {
            // Erste Abfrage: ältere Anfragen (vor der Installation) nicht nachholen.
            Settings.lastRequestCreated = Self.pocketBaseDate(Date())
            return
        }
        let filter = "created > \"\(since)\" && (install_id = \"\" || install_id = \"\(Settings.installID)\")"
        var components = URLComponents(string: Settings.reportEndpoint + "/api/collections/requests/records")
        components?.queryItems = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "sort", value: "created"),
            URLQueryItem(name: "perPage", value: "50"),
        ]
        guard let url = components?.url,
              let response = await fetch(URLRequest(url: url)), (200..<300).contains(response.status),
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let newest = items.compactMap({ $0["created"] as? String }).max() else { return }
        // Vorher als erledigt merken – ein Update startet die App neu. Jede Art nur einmal ausführen.
        Settings.lastRequestCreated = newest
        let kinds = Set(items.compactMap { $0["kind"] as? String })
        if kinds.contains("diagnostics") {
            Log.info("Diagnosebericht wurde angefordert – wird gesendet")
            send(kind: "diagnostics", message: "Diagnose auf Anfrage", details: [
                "report": OneDriveConfig.diagnosticReport(),
                "log": Log.readTail(500).joined(separator: "\n"),
            ])
        }
        if kinds.contains("update") {
            // Wie die stündliche Prüfung: beachtet „Automatische Updates“ und startet nicht mitten in einer Aktion neu.
            await Updater.shared.check(userInitiated: false)
        }
    }

    /// `true` gesendet, `false` vom Server abgelehnt (nicht wiederholen), `nil` nicht erreichbar.
    private func post(_ body: Data) async -> Bool? {
        guard let url = URL(string: Settings.reportEndpoint + "/api/collections/reports/records") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let status = await fetch(request)?.status else { return nil }
        if (200..<300).contains(status) { return true }
        // 4xx: Bericht ungültig (z. B. zu groß) – verwerfen, sonst blockiert er die Warteschlange.
        return (400..<500).contains(status) && status != 429 ? false : nil
    }

    /// `nil` = Server nicht erreichbar.
    private func fetch(_ request: URLRequest) async -> (data: Data, status: Int)? {
        var request = request
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                // Kein Log.error – das würde wieder einen Bericht auslösen.
                Log.info("Berichts-Server antwortet mit Status \(status)")
            }
            return (data: data, status: status)
        } catch {
            return nil
        }
    }

    /// Datumsformat von PocketBase-Filtern („2026-10-01 19:21:37.000Z“).
    static func pocketBaseDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        return f.string(from: date)
    }
}

/// Berichte, die nicht gesendet werden konnten (max. 100, ältere werden verworfen).
enum ReportQueue {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OneDriveOpener/Berichte", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func add(_ data: Data) {
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
        try? data.write(to: directory.appendingPathComponent(name))
        let files = sortedFiles()
        if files.count > 100 {
            files.prefix(files.count - 100).forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    static func pending() -> [(URL, Data)] {
        sortedFiles().compactMap { url in (try? Data(contentsOf: url)).map { (url, $0) } }
    }

    static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    private static func sortedFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
