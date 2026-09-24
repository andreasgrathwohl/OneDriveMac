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
    /// `ms-word:ofe|u|<URL>` über Launch Services (`/usr/bin/open`).
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

    static var didShowOnboarding: Bool {
        get { defaults.bool(forKey: "DidShowOnboarding") }
        set { defaults.set(newValue, forKey: "DidShowOnboarding") }
    }
}
