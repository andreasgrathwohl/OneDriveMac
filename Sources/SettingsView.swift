import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            guard enabled != Settings.enabled else { return }
            Settings.enabled = enabled
            Log.info(enabled ? "Fortgesetzt" : "Pausiert")
            AppState.changed()
        }
    }
    @Published var keepDefault: Bool {
        didSet {
            guard keepDefault != Settings.keepDefault else { return }
            Settings.keepDefault = keepDefault
            Log.info("Überwachung der Standard-App \(keepDefault ? "ein" : "aus")")
            Task { await HandlerGuard.shared.check(reason: "Einstellung geändert", force: true) }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            LoginItem.set(launchAtLogin)
        }
    }
    @Published var useGuessed: Bool {
        didSet {
            guard useGuessed != Settings.useGuessedMappings else { return }
            Settings.useGuessedMappings = useGuessed
            Log.info("Geschätzte Zuordnungen online öffnen: \(useGuessed ? "ja" : "nein")")
        }
    }
    @Published var waitSeconds: Int { didSet { Settings.syncWaitSeconds = waitSeconds } }
    @Published var mappings: [ManualMapping] {
        didSet {
            Settings.manualMappings = mappings
            OneDriveConfig.invalidateCache()
        }
    }

    @Published var status: UserStatus.Kind = .openWithOnly
    @Published var guardStatus = ""
    @Published var detected: [SyncRoot] = []
    @Published var notes: [String] = []
    @Published var handlers: [HandlerRow] = []
    @Published var message = ""
    @Published var busy = false

    @Published var newLocal = ""
    @Published var newURL = ""
    @Published var sheetError = ""

    let openLog: () -> Void
    private var observer: AnyCancellable?

    var isDefault: Bool { !handlers.isEmpty && handlers.allSatisfy(\.isOurs) }

    init(openLog: @escaping () -> Void) {
        self.openLog = openLog
        enabled = Settings.enabled
        keepDefault = Settings.keepDefault
        launchAtLogin = LoginItem.isEnabled
        useGuessed = Settings.useGuessedMappings
        waitSeconds = Settings.syncWaitSeconds
        mappings = Settings.manualMappings
        observer = NotificationCenter.default.publisher(for: .appStateChanged)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshState() } }
    }

    /// Schnelle Aktualisierung (Schalter, Status) – ohne OneDrive-Ordner neu einzulesen.
    func refreshState() {
        enabled = Settings.enabled
        keepDefault = Settings.keepDefault
        launchAtLogin = LoginItem.isEnabled
        useGuessed = Settings.useGuessedMappings
        handlers = DefaultHandler.statusRows()
        guardStatus = HandlerGuard.shared.statusText
        status = UserStatus.kind
    }

    func refresh() {
        refreshState()
        OneDriveConfig.invalidateCache()
        let det = OneDriveConfig.detect()
        detected = det.roots
        notes = det.notes
    }

    func performStatusAction() {
        let kind = status
        busy = true
        Task {
            await UserStatus.performAction(kind)
            busy = false
            refreshState()
        }
    }

    func makeDefault() {
        busy = true
        Task {
            await UserStatus.performAction(.openWithOnly)
            busy = false
            refreshState()
            message = isDefault ? "" : "Nicht alle Dateitypen konnten umgestellt werden – Details unter „Fehlerbehebung“."
        }
    }

    func restoreOffice() {
        keepDefault = false
        busy = true
        Task {
            let errors = await DefaultHandler.restoreOffice()
            busy = false
            refreshState()
            message = errors.isEmpty ? "" : "Nicht alle Dateitypen konnten zurückgestellt werden – Details unter „Fehlerbehebung“."
        }
    }

    func checkNow() {
        Task {
            await HandlerGuard.shared.check(reason: "manuell", force: true)
            refreshState()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = "Wähle den lokalen OneDrive- oder SharePoint-Ordner."
        panel.directoryURL = OneDriveConfig.home.appendingPathComponent("Library/CloudStorage")
        if panel.runModal() == .OK, let url = panel.url {
            newLocal = url.path
        }
    }

    @discardableResult
    func addMapping() -> Bool {
        let local = newLocal.trimmingCharacters(in: .whitespaces)
        let web = newURL.trimmingCharacters(in: .whitespaces)
        guard OneDriveConfig.isDirectory(local) else {
            sheetError = "Der Ordner wurde nicht gefunden."
            return false
        }
        guard web.lowercased().hasPrefix("https://") else {
            sheetError = "Die Web-Adresse muss mit https:// beginnen."
            return false
        }
        mappings.append(ManualMapping(localPath: local, webURL: web))
        Log.info("Eigene Zuordnung hinzugefügt: \(local) → \(web)")
        newLocal = ""
        newURL = ""
        sheetError = ""
        refresh()
        return true
    }

    func remove(_ mapping: ManualMapping) {
        mappings.removeAll { $0.id == mapping.id }
        Log.info("Eigene Zuordnung entfernt: \(mapping.localPath)")
        refresh()
    }

    func copyDiagnostics() {
        let report = OneDriveConfig.diagnosticReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        Log.info("Diagnose erstellt:\n\(report)")
        message = "Der Diagnosebericht wurde in die Zwischenablage kopiert."
    }
}

// MARK: - Gemeinsame Bausteine

private extension View {
    /// Systemeinstellungen-Optik ab macOS 13, sonst schlichtes Formular.
    @ViewBuilder func settingsFormStyle() -> some View {
        if #available(macOS 13.0, *) {
            self.formStyle(.grouped)
        } else {
            self.padding(20)
        }
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

private struct FileIcon: View {
    let path: String
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: 24, height: 24)
    }
}

// MARK: - Allgemein

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    private let waitOptions = [0, 5, 15, 30, 60]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: UserStatus.symbol(model.status))
                        .font(.system(size: 34))
                        .foregroundColor(Color(UserStatus.color(model.status)))
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UserStatus.title(model.status)).font(.headline)
                        Caption(UserStatus.subtitle(model.status))
                    }
                    Spacer()
                    if let action = UserStatus.actionTitle(model.status) {
                        Button(action) { model.performStatusAction() }
                            .disabled(model.busy)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Office-Dateien mit AutoSpeichern öffnen", isOn: $model.enabled)
                Toggle("Beim Anmelden automatisch starten", isOn: $model.launchAtLogin)
            } footer: {
                Caption("Tipp: Halte beim Doppelklick die ⌥-Taste gedrückt, um eine Datei ohne AutoSpeichern zu öffnen.")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Doppelklick im Finder")
                        Caption(model.isDefault
                            ? "Word-, Excel- und PowerPoint-Dateien werden über OneDrive Opener geöffnet."
                            : "Office öffnet Dateien direkt – ohne AutoSpeichern.")
                    }
                    Spacer()
                    if model.isDefault {
                        Button("Zurück zu Office") { model.restoreOffice() }.disabled(model.busy)
                    } else {
                        Button("Aktivieren") { model.makeDefault() }.disabled(model.busy)
                    }
                }
                Toggle("Nach Office-Updates automatisch wiederherstellen", isOn: $model.keepDefault)
                    .disabled(!model.isDefault && !model.keepDefault)
            } header: {
                Text("Standard-App")
            }

            Section {
                Picker("Auf ausstehenden Upload warten", selection: $model.waitSeconds) {
                    ForEach(Array(Set(waitOptions + [model.waitSeconds])).sorted(), id: \.self) { seconds in
                        Text(label(for: seconds)).tag(seconds)
                    }
                }
            } header: {
                Text("Synchronisierung")
            } footer: {
                Caption("Hat OneDrive eine Datei noch nicht hochgeladen, wird so lange gewartet, bevor nachgefragt wird.")
            }

            if !model.message.isEmpty {
                Section { Caption(model.message) }
            }
        }
        .settingsFormStyle()
    }

    private func label(for seconds: Int) -> String {
        switch seconds {
        case 0: return "Nicht warten"
        case 60: return "1 Minute"
        default: return "\(seconds) Sekunden"
        }
    }
}

// MARK: - Ordner

struct FoldersTab: View {
    @ObservedObject var model: SettingsModel
    @State private var showAdd = false

    var body: some View {
        Form {
            Section {
                if model.detected.isEmpty {
                    Caption("Keine OneDrive-Ordner gefunden. Ist OneDrive gestartet und angemeldet?")
                }
                ForEach(model.detected, id: \.self) { root in
                    HStack(spacing: 10) {
                        FileIcon(path: root.localPath)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FolderInfo.name(root))
                            Caption(FolderInfo.detail(root))
                        }
                        Spacer()
                        if root.isGuess && !model.useGuessed {
                            Badge(text: "Ohne AutoSpeichern", color: .orange)
                        } else {
                            Badge(text: "AutoSpeichern", color: .green)
                        }
                    }
                    .help("\(root.localPath)\n→ \(root.webURL)")
                }
            } header: {
                Text("Erkannte OneDrive-Ordner")
            } footer: {
                if model.detected.contains(where: \.isGuess) {
                    Caption("Bei Ordnern „Ohne AutoSpeichern“ lässt sich die Online-Adresse nicht sicher bestimmen. Lege dafür unten eine eigene Zuordnung an.")
                }
            }

            Section {
                if model.mappings.isEmpty {
                    Caption("Keine eigenen Zuordnungen.")
                }
                ForEach(model.mappings) { mapping in
                    HStack(spacing: 10) {
                        FileIcon(path: mapping.localPath)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: mapping.localPath).lastPathComponent)
                            Caption(mapping.webURL)
                        }
                        Spacer()
                        Button {
                            model.remove(mapping)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Zuordnung entfernen")
                    }
                }
                HStack {
                    Spacer()
                    Button("Zuordnung hinzufügen …") { showAdd = true }
                }
            } header: {
                Text("Eigene Zuordnungen")
            } footer: {
                Caption("Eigene Zuordnungen haben Vorrang vor der automatischen Erkennung.")
            }

            if model.detected.contains(where: \.isGuess) {
                Section {
                    Toggle("Unsichere Ordner trotzdem mit AutoSpeichern öffnen", isOn: $model.useGuessed)
                } footer: {
                    Caption("Stimmt die vermutete Adresse nicht, meldet Office „Datei nicht gefunden“.")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Ordner neu einlesen") { model.refresh() }
                }
            }
        }
        .settingsFormStyle()
        .sheet(isPresented: $showAdd) {
            AddMappingSheet(model: model, isPresented: $showAdd)
        }
    }
}

private struct AddMappingSheet: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Eigene Zuordnung hinzufügen").font(.headline)
            Caption("Verbindet einen lokalen Ordner mit seiner Adresse in OneDrive oder SharePoint im Web, damit Dateien darin mit AutoSpeichern geöffnet werden.")

            VStack(alignment: .leading, spacing: 4) {
                Text("Lokaler Ordner")
                HStack {
                    TextField("", text: $model.newLocal)
                    Button("Auswählen …") { model.chooseFolder() }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Web-Adresse")
                TextField("https://firma.sharepoint.com/sites/Team/Freigegebene Dokumente", text: $model.newURL)
                Caption("Bibliothek oder Ordner im Browser öffnen und die Adresse bis zum Ordnernamen kopieren.")
            }
            if !model.sheetError.isEmpty {
                Text(model.sheetError).font(.callout).foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("Abbrechen") {
                    model.sheetError = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Hinzufügen") {
                    if model.addMapping() { isPresented = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.newLocal.isEmpty || model.newURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// MARK: - Fehlerbehebung

struct TroubleshootingTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Protokoll")
                    Spacer()
                    Button("Anzeigen …") { model.openLog() }
                }
                HStack {
                    Text("Diagnosebericht")
                    Spacer()
                    Button("In Zwischenablage kopieren") { model.copyDiagnostics() }
                }
            } header: {
                Text("Protokoll und Diagnose")
            } footer: {
                Caption(model.message.isEmpty
                    ? "Bitte beim Melden eines Problems den Diagnosebericht mitschicken."
                    : model.message)
            }

            Section {
                ForEach(model.handlers, id: \.self) { row in
                    HStack {
                        Text(".\(row.ext)").font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(row.handler).foregroundColor(row.isOurs ? .secondary : .orange)
                    }
                }
                HStack {
                    Caption(model.guardStatus)
                    Spacer()
                    Button("Jetzt prüfen") { model.checkNow() }
                }
            } header: {
                Text("Standard-App je Dateityp")
            }

            Section {
                ForEach(model.detected, id: \.self) { root in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(root.localPath).font(.system(.caption, design: .monospaced))
                        Text("→ \(root.webURL)").font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                        Caption(root.source + (root.isGuess ? " · geschätzt" : ""))
                    }
                    .textSelection(.enabled)
                }
                ForEach(model.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundColor(.orange)
                }
            } header: {
                Text("Technische Details")
            }
        }
        .settingsFormStyle()
    }
}
