import Foundation

struct ManualMapping: Identifiable, Hashable {
    let id = UUID()
    var localPath: String
    var webURL: String

    init(localPath: String, webURL: String) {
        self.localPath = localPath
        self.webURL = webURL
    }

    init?(_ dict: [String: Any]) {
        guard let local = dict["localPath"] as? String, let web = dict["webURL"] as? String,
              !local.isEmpty, !web.isEmpty else { return nil }
        self.init(localPath: local, webURL: web)
    }

    var dictionary: [String: String] { ["localPath": localPath, "webURL": webURL] }
}

enum OpenMethod: String, CaseIterable {
    /// Office-Adresse (siehe `FileOpener.officeURI`) über Launch Services (`/usr/bin/open`).
    case officeURI
    /// Dieselbe Office-Adresse unverändert als Apple Event („GetURL“) direkt an die Office-App.
    case appleEvent
    /// Nur die https-Adresse, ausdrücklich an die Office-App übergeben.
    case webURL

    var title: String {
        switch self {
        case .officeURI: return "Office-Adresse (Standard)"
        case .appleEvent: return "Office-Adresse als Apple Event"
        case .webURL: return "Web-Adresse direkt an Office"
        }
    }
}

/// Einstellungen liegen in UserDefaults und können daher auch per MDM-Profil
/// (Domain = Bundle-ID) vorgegeben werden.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static var enabled: Bool {
        get { defaults.object(forKey: "Enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "Enabled") }
    }

    static var syncWaitSeconds: Int {
        get { defaults.object(forKey: "SyncWaitSeconds") as? Int ?? 15 }
        set { defaults.set(newValue, forKey: "SyncWaitSeconds") }
    }

    /// Wie die Online-Adresse an Office übergeben wird (siehe `OpenMethod`).
    static var openMethod: OpenMethod {
        get { OpenMethod(rawValue: defaults.string(forKey: "OpenMethod") ?? "") ?? .officeURI }
        set { defaults.set(newValue.rawValue, forKey: "OpenMethod") }
    }

    /// Lokal geöffnete OneDrive-Dokumente in Word automatisch mit AutoSpeichern neu öffnen.
    static var wordIntegration: Bool {
        get { defaults.object(forKey: "WordIntegration") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "WordIntegration") }
    }

    /// Neue Versionen aus den GitHub-Releases automatisch installieren.
    static var autoUpdate: Bool {
        get { defaults.object(forKey: "AutoUpdate") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "AutoUpdate") }
    }

    /// GitHub-Repository („besitzer/name“), aus dessen Releases aktualisiert wird.
    static var updateRepository: String {
        defaults.string(forKey: "UpdateRepository") ?? "andreasgrathwohl/OneDriveMac"
    }

    /// Fehler automatisch melden und Diagnose-Anfragen von außen beantworten (siehe `Reporter`).
    /// Erst nach Zustimmung (Abfrage beim Start) oder per MDM-Vorgabe.
    static var sendReports: Bool {
        get { defaults.object(forKey: "SendReports") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "SendReports") }
    }

    /// Wurde schon nach der Zustimmung gefragt bzw. ist sie (z. B. per MDM) festgelegt?
    static var reportConsentDecided: Bool { defaults.object(forKey: "SendReports") != nil }

    static var reportEndpoint: String { defaults.string(forKey: "ReportEndpoint") ?? ReportBackend.endpoint }

    /// Zufällige Geräte-ID für Fehlerberichte (enthält keine persönlichen Daten).
    static var installID: String {
        if let id = defaults.string(forKey: "InstallID") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "InstallID")
        return id
    }

    /// Zeitstempel (PocketBase-Format) der zuletzt bearbeiteten Anfrage von außen.
    static var lastRequestCreated: String? {
        get { defaults.string(forKey: "LastRequestCreated") }
        set { defaults.set(newValue, forKey: "LastRequestCreated") }
    }

    /// Gelernte Online-Schreibweisen: lokaler Name → Name in OneDrive online (siehe `PathLearner`).
    static var learnedOnlineNames: [String: String] {
        // V2: Einträge vor 1.4.4 enthielten entschlüsselte Namen und sind falsch.
        get { defaults.dictionary(forKey: "LearnedOnlineNamesV2") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "LearnedOnlineNamesV2") }
    }

    /// Auch geschätzte Zuordnungen online öffnen (Risiko: falsche Web-Adresse). Standard: aus.
    static var useGuessedMappings: Bool {
        get { defaults.bool(forKey: "UseGuessedMappings") }
        set { defaults.set(newValue, forKey: "UseGuessedMappings") }
    }

    static var manualMappings: [ManualMapping] {
        get {
            let raw = defaults.array(forKey: "ManualMappings") as? [[String: Any]] ?? []
            return raw.compactMap(ManualMapping.init)
        }
        set { defaults.set(newValue.map(\.dictionary), forKey: "ManualMappings") }
    }

    /// Standard-App-Zuordnung überwachen und nach Office-Updates wiederherstellen.
    /// Wird mit „Als Standard festlegen“ eingeschaltet und mit „Zurück auf Office“ ausgeschaltet.
    static var keepDefault: Bool {
        get { defaults.bool(forKey: "KeepDefaultHandler") }
        set { defaults.set(newValue, forKey: "KeepDefaultHandler") }
    }

    static var officeVersions: [String: String] {
        get { defaults.dictionary(forKey: "OfficeVersions") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "OfficeVersions") }
    }

    static var loginItemInitialized: Bool {
        get { defaults.bool(forKey: "LoginItemInitialized") }
        set { defaults.set(newValue, forKey: "LoginItemInitialized") }
    }

    /// Speicherdauer in Word/Excel/PowerPoint über die Bedienungshilfen messen (siehe `SaveMonitor`).
    static var measureSaving: Bool {
        get { defaults.object(forKey: "MeasureSaving") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "MeasureSaving") }
    }

    /// Wurde schon nach der Freigabe „Bedienungshilfen“ gefragt?
    static var accessibilityAsked: Bool {
        get { defaults.bool(forKey: "AccessibilityAsked") }
        set { defaults.set(newValue, forKey: "AccessibilityAsked") }
    }

    /// War die Freigabe schon einmal erteilt? Fehlt sie dann, hat ein Update sie ungültig gemacht.
    static var accessibilityGranted: Bool {
        get { defaults.bool(forKey: "AccessibilityGranted") }
        set { defaults.set(newValue, forKey: "AccessibilityGranted") }
    }

    /// Bereits gemeldete Titelleisten-Proben („app|Version|Zustand“).
    static var saveProbes: [String] {
        get { defaults.stringArray(forKey: "SaveProbes") ?? [] }
        set { defaults.set(newValue, forKey: "SaveProbes") }
    }

    /// Gemessene Speichervorgänge seit der letzten Übersicht.
    static var saveStats: [[String: Any]] {
        get { defaults.array(forKey: "SaveStats") as? [[String: Any]] ?? [] }
        set { defaults.set(newValue, forKey: "SaveStats") }
    }

    /// Hinweisfenster zeigen, solange Office länger als 45 s speichert, und Warnungen des `SaveGuard`.
    static var saveWarning: Bool {
        get { defaults.object(forKey: "SaveWarning") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "SaveWarning") }
    }

    static var saveStatsSent: Date? {
        get { defaults.object(forKey: "SaveStatsSent") as? Date }
        set { defaults.set(newValue, forKey: "SaveStatsSent") }
    }

    static var didShowOnboarding: Bool {
        get { defaults.bool(forKey: "DidShowOnboarding") }
        set { defaults.set(newValue, forKey: "DidShowOnboarding") }
    }
}
