import AppKit
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var enabled: Bool { didSet { Settings.enabled = enabled } }
    @Published var waitSeconds: Int { didSet { Settings.syncWaitSeconds = waitSeconds } }
    @Published var mappings: [ManualMapping] {
        didSet {
            Settings.manualMappings = mappings
            OneDriveConfig.invalidateCache()
        }
    }
    @Published var detected: [SyncRoot] = []
    @Published var notes: [String] = []
    @Published var handlers: [HandlerRow] = []
    @Published var message = ""
    @Published var newLocal = ""
    @Published var newURL = ""

    init() {
        enabled = Settings.enabled
        waitSeconds = Settings.syncWaitSeconds
        mappings = Settings.manualMappings
    }

    func refresh() {
        OneDriveConfig.invalidateCache()
        let det = OneDriveConfig.detect()
        detected = det.roots
        notes = det.notes.filter { !$0.hasPrefix("Einstellungsordner") }
        handlers = DefaultHandler.statusRows()
    }

    func makeDefault() {
        Task {
            let errors = await DefaultHandler.setAsDefault()
            handlers = DefaultHandler.statusRows()
            message = errors.isEmpty
                ? "OneDrive Opener ist jetzt Standard für Word-, Excel- und PowerPoint-Dateien."
                : "Teilweise fehlgeschlagen:\n" + errors.joined(separator: "\n")
        }
    }

    func restoreOffice() {
        Task {
            let errors = await DefaultHandler.restoreOffice()
            handlers = DefaultHandler.statusRows()
            message = errors.isEmpty
                ? "Word, Excel und PowerPoint sind wieder Standard."
                : "Teilweise fehlgeschlagen:\n" + errors.joined(separator: "\n")
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = OneDriveConfig.home.appendingPathComponent("Library/CloudStorage")
        if panel.runModal() == .OK, let url = panel.url {
            newLocal = url.path
        }
    }

    func addMapping() {
        let local = newLocal.trimmingCharacters(in: .whitespaces)
        let web = newURL.trimmingCharacters(in: .whitespaces)
        guard OneDriveConfig.isDirectory(local) else { message = "Der lokale Ordner existiert nicht."; return }
        guard web.lowercased().hasPrefix("https://") else { message = "Die Web-URL muss mit https:// beginnen."; return }
        mappings.append(ManualMapping(localPath: local, webURL: web))
        newLocal = ""
        newURL = ""
        message = "Zuordnung hinzugefügt."
    }

    func remove(_ mapping: ManualMapping) {
        mappings.removeAll { $0.id == mapping.id }
    }

    func copyDiagnostics() {
        let report = OneDriveConfig.diagnosticReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        Log.info("Diagnose erstellt:\n\(report)")
        message = "Diagnose wurde in die Zwischenablage kopiert."
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Text("Allgemein").bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Office-Dateien aus OneDrive online öffnen (AutoSpeichern)", isOn: $model.enabled)
                        Stepper("Auf ausstehenden Upload warten: \(model.waitSeconds) s",
                                value: $model.waitSeconds, in: 0...120, step: 5)
                        Text("Tipp: ⌥ (Wahltaste) beim Doppelklick gedrückt halten, um eine Datei lokal ohne Umleitung zu öffnen.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Standard-App für Doppelklick").bold()) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.handlers, id: \.self) { row in
                            HStack {
                                Text(".\(row.ext)").frame(width: 60, alignment: .leading)
                                Text(row.handler).foregroundColor(row.isOurs ? .green : .secondary)
                            }
                        }
                        HStack {
                            Button("OneDrive Opener als Standard festlegen") { model.makeDefault() }
                            Button("Zurück auf Office") { model.restoreOffice() }
                        }
                        Text("Unabhängig davon steht die App im Finder immer unter „Öffnen mit“ zur Verfügung.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Automatisch erkannte OneDrive-Ordner").bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.detected.isEmpty {
                            Text("Keine Ordner erkannt. Bitte unten manuell zuordnen und die Diagnose prüfen.")
                                .foregroundColor(.secondary)
                        }
                        ForEach(model.detected, id: \.self) { root in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(root.localPath).font(.system(.body, design: .monospaced))
                                Text("→ \(root.webURL)").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        ForEach(model.notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundColor(.orange)
                        }
                        HStack {
                            Button("Neu einlesen") { model.refresh() }
                            Button("Diagnose kopieren") { model.copyDiagnostics() }
                        }
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Manuelle Zuordnungen (haben Vorrang)").bold()) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.mappings) { mapping in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mapping.localPath).font(.system(.body, design: .monospaced))
                                    Text("→ \(mapping.webURL)").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Entfernen") { model.remove(mapping) }
                            }
                        }
                        HStack {
                            TextField("Lokaler Ordner", text: $model.newLocal)
                            Button("Wählen …") { model.chooseFolder() }
                        }
                        TextField("Web-URL, z. B. https://firma.sharepoint.com/sites/Team/Freigegebene Dokumente",
                                  text: $model.newURL)
                        Button("Hinzufügen") { model.addMapping() }
                            .disabled(model.newLocal.isEmpty || model.newURL.isEmpty)
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                if !model.message.isEmpty {
                    Text(model.message).foregroundColor(.accentColor)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 520)
    }
}
