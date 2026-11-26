import AppKit
import UserNotifications

/// Hinweise zum Speichern als macOS-Mitteilung: Sie verschwinden von selbst und bleiben in der
/// Mitteilungszentrale nachlesbar. Das frühere Fenster oben rechts blieb stehen, solange ein Dokument
/// speicherte – bei Dokumenten, die tagelang auf „Upload ausstehend“ stehen, also dauerhaft.
///
/// Erlaubt macOS der App keine Mitteilungen, erscheint ersatzweise das kleine Fenster (`SaveNotice`),
/// das sich nach wenigen Sekunden selbst schließt. macOS fragt beim ersten Hinweis einmal um Erlaubnis.
@MainActor
final class SaveNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind {
        case saving, saved, closedWhileSaving
        /// Nach dem Aufwachen: Dokumente, die beim Zuklappen noch nicht hochgeladen waren.
        case unsyncedAtSleep

        var symbol: String {
            switch self {
            case .saving: return "icloud.and.arrow.up"
            case .saved: return "checkmark.circle.fill"
            case .closedWhileSaving, .unsyncedAtSleep: return "exclamationmark.triangle.fill"
            }
        }

        var color: NSColor {
            switch self {
            case .saving: return .systemBlue
            case .saved: return .systemGreen
            case .closedWhileSaving, .unsyncedAtSleep: return .systemOrange
            }
        }

        /// So lange bleibt das Ersatzfenster stehen. Der Hinweis nach dem Aufwachen länger: Er soll gelesen
        /// werden, bevor das iPad in die Hand genommen wird.
        var windowSeconds: TimeInterval {
            switch self {
            case .saving, .closedWhileSaving: return 15
            case .unsyncedAtSleep: return 30
            case .saved: return 3
            }
        }

        /// „Speichert …“ und „Alles gespeichert“ teilen sich eine Kennung: Die zweite Mitteilung ersetzt
        /// die erste. Die Warnungen bleiben daneben stehen.
        var identifier: String {
            switch self {
            case .saving, .saved: return "OneDriveOpener.save"
            case .closedWhileSaving: return "OneDriveOpener.closedWhileSaving"
            case .unsyncedAtSleep: return "OneDriveOpener.unsyncedAtSleep"
            }
        }
    }

    /// Ersatzfenster vom Anwender geschlossen (Mitteilungen kennen kein Schließen).
    var onClose: (@MainActor () -> Void)? {
        get { window.onClose }
        set { window.onClose = newValue }
    }

    private let window = SaveNotice()
    private static let stateKey = "NotificationPermissionState"

    private var delegateSet = false

    func post(_ kind: Kind, _ text: String) {
        // Erst beim ersten Hinweis anfassen, nicht beim Start: Die Mitteilungszentrale setzt ein App-Bundle
        // voraus, und die Kommandozeilen-Modi (`--diagnose`, `--selftest`) sollen sie nie berühren.
        if !delegateSet {
            delegateSet = true
            UNUserNotificationCenter.current().delegate = self
        }
        Task {
            if await Self.isAllowed() {
                deliver(kind, text)
            } else {
                window.show(text, symbol: kind.symbol, color: kind.color, hideAfter: kind.windowSeconds)
            }
        }
    }

    private func deliver(_ kind: Kind, _ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "OneDrive Opener"
        content.body = text
        let request = UNNotificationRequest(identifier: kind.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.info("Mitteilung nicht zugestellt: \(error.localizedDescription)") }
        }
    }

    /// Fragt beim ersten Mal um Erlaubnis; danach gilt, was in den Systemeinstellungen steht (bei jedem
    /// Hinweis neu gelesen – die Erlaubnis kann dort jederzeit geändert werden).
    private static func isAllowed() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional:
            note("erlaubt")
            return true
        case .denied:
            note("abgelehnt")
            return false
        default:
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                note(granted ? "erlaubt" : "abgelehnt")
                return granted
            } catch {
                note("nicht möglich: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Protokolliert und meldet den Stand der Erlaubnis, wenn er sich ändert – so lässt sich aus der Ferne
    /// sehen, ob Mitteilungen ankommen und ob die Erlaubnis ein Update übersteht.
    private static func note(_ state: String) {
        guard UserDefaults.standard.string(forKey: stateKey) != state else { return }
        UserDefaults.standard.set(state, forKey: stateKey)
        Log.info("Mitteilungen: \(state)")
        Reporter.shared.send(kind: "notifications", message: "Mitteilungen \(state)", details: [:])
    }

    /// Banner auch zeigen, wenn die App selbst gerade vorn ist (z. B. Einstellungen geöffnet).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
