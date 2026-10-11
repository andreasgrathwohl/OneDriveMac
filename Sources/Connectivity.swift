import Foundation
import Network

/// Beobachtet, ob der Mac eine Netzwerkverbindung hat. Ohne Verbindung kann Office keine
/// Cloud-Dokumente laden – Dateien werden dann lokal (ohne AutoSpeichern) geöffnet.
final class Connectivity {
    static let shared = Connectivity()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    private var network = "unbekannt"

    private init() {}

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    /// Art der Verbindung für Berichte, z. B. „WLAN“ oder „Ethernet, getethert“.
    var networkDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return network
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let now = path.status == .satisfied
            var kind = path.usesInterfaceType(.wifi) ? "WLAN"
                : path.usesInterfaceType(.wiredEthernet) ? "Ethernet"
                : path.usesInterfaceType(.cellular) ? "Mobilfunk"
                : now ? "andere" : "offline"
            if path.isExpensive { kind += ", getethert" }
            if path.isConstrained { kind += ", Datensparmodus" }
            self.lock.lock()
            let changed = now != self.online
            self.online = now
            self.network = kind
            self.lock.unlock()
            guard changed else { return }
            Log.info(now ? "Netzwerk wieder verfügbar" : "Keine Netzwerkverbindung – Dateien werden lokal geöffnet")
            Task { @MainActor in
                AppState.changed()
                if now { Updater.shared.checkSoon() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "OneDriveOpener.connectivity"))
    }
}
