import AppKit
import SwiftUI

/// Hält die letzten Protokollzeilen für das Protokollfenster (live aktualisiert).
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()
    private static let maxLines = 3000

    @Published private(set) var lines: [String]

    private init() {
        lines = Log.readTail(Self.maxLines)
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    func clear() {
        lines.removeAll()
        Log.clearFile()
    }
}

struct LogView: View {
    @ObservedObject var store: LogStore
    @State private var filter = ""
    @State private var onlyErrors = false

    private var shown: [String] {
        store.lines.filter { line in
            (!onlyErrors || line.contains("[FEHLER]"))
                && (filter.isEmpty || line.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filtern …", text: $filter).frame(maxWidth: 260)
                Toggle("Nur Fehler", isOn: $onlyErrors)
                Spacer()
                Button("Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.joined(separator: "\n"), forType: .string)
                }
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                }
                Button("Leeren") { store.clear() }
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(line.contains("[FEHLER]") ? .red : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: store.lines) { _ in scrollToEnd(proxy) }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = shown.indices.last else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }
}
