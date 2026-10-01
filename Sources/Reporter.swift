import Foundation

/// Zugang zur Berichts-Datenbank (Supabase). Der Schlüssel ist der öffentliche „publishable key“:
/// Er erlaubt nur das Einfügen in `reports` und das Lesen von `requests` – Berichte lesen kann damit niemand.
/// Leer = Berichte aus. Per MDM/`defaults` überschreibbar (`ReportEndpoint`, `ReportKey`).
enum ReportBackend {
    static let endpoint = ""
    static let key = ""
}

/// Meldet Fehler automatisch und liefert auf Anfrage von außen (Tabelle `requests`) Diagnoseberichte.
/// Gesendet werden Version, macOS-Version, Fehlermeldung, Pfade/Adressen und Protokollzeilen –
/// keine Dokumentinhalte.
@MainActor
final class Reporter {
    static let shared = Reporter()

    private var recentErrors: [String: Date] = [:]
    private var sentToday = 0
    private var day = Calendar.current.startOfDay(for: Date())
    private var timer: Timer?

    private init() {}

    var isConfigured: Bool { !Settings.reportEndpoint.isEmpty && !Settings.reportKey.isEmpty }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in
            Task { @MainActor in await Reporter.shared.pollRequests() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            Task { @MainActor in
                Reporter.shared.send(kind: "start", message: "Gestartet", details: [:])
                await Reporter.shared.pollRequests()
            }
        }
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
            "message": message,
            "payload": details,
        ]
        Task { _ = await request("reports", method: "POST", body: body) }
    }

    /// Anfragen von außen abholen: `diagnostics` (voller Diagnosebericht + Protokoll), `update` (Update suchen).
    func pollRequests() async {
        guard Settings.sendReports, isConfigured, Connectivity.shared.isOnline else { return }
        let last = Settings.lastHandledRequest
        let query = "requests?select=id,kind&id=gt.\(last)&or=(install_id.is.null,install_id.eq.\(Settings.installID))&order=id.asc"
        guard let data = await request(query, method: "GET", body: nil),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let newest = rows.compactMap({ ($0["id"] as? NSNumber)?.intValue }).max() else { return }
        // Vorher als erledigt merken – ein Update startet die App neu. Jede Art nur einmal ausführen,
        // auch wenn sich mehrere Anfragen angesammelt haben (z. B. seit der Installation).
        Settings.lastHandledRequest = max(last, newest)
        let kinds = Set(rows.compactMap { $0["kind"] as? String })
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

    private func request(_ path: String, method: String, body: [String: Any]?) async -> Data? {
        guard let url = URL(string: Settings.reportEndpoint + "/rest/v1/" + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Settings.reportKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Settings.reportKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        if let body {
            // data(withJSONObject:) wirft bei ungültigen Werten eine ObjC-Ausnahme, die `try?` nicht abfängt.
            guard JSONSerialization.isValidJSONObject(body) else { return nil }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                // Kein Log.error – das würde wieder einen Bericht auslösen.
                Log.info("Fehlerbericht: Server antwortet mit Status \(status)")
                return nil
            }
            return data
        } catch {
            Log.info("Fehlerbericht konnte nicht gesendet werden: \(error.localizedDescription)")
            return nil
        }
    }
}
