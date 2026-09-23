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

    static var manualMappings: [ManualMapping] {
        get {
            let raw = defaults.array(forKey: "ManualMappings") as? [[String: Any]] ?? []
            return raw.compactMap(ManualMapping.init)
        }
        set { defaults.set(newValue.map(\.dictionary), forKey: "ManualMappings") }
    }

    static var didShowOnboarding: Bool {
        get { defaults.bool(forKey: "DidShowOnboarding") }
        set { defaults.set(newValue, forKey: "DidShowOnboarding") }
    }
}
