import AppKit

/// Kleines Fenster oben rechts: „Word speichert noch …“. Nimmt Office nicht den Fokus, bleibt über allen
/// Fenstern (auch im Vollbild) und lässt sich schließen – dann erscheint es erst beim nächsten langen
/// Speichervorgang wieder (siehe `SaveMonitor.updateNotice`).
@MainActor
final class SaveNotice: NSObject, NSWindowDelegate {
    var onClose: (@MainActor () -> Void)?

    private var panel: NSPanel?
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?
    private var closingByApp = false

    func show(_ text: String, symbol: String, color: NSColor, hideAfter: TimeInterval?) {
        let panel = self.panel ?? makePanel()
        label.stringValue = text
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        // Höhe an den Text anpassen, oben rechts verankert bleiben.
        if let content = panel.contentView {
            let height = max(56, content.fittingSize.height)
            if abs(panel.contentLayoutRect.height - height) > 1 {
                panel.setContentSize(NSSize(width: 360, height: height))
                if panel.isVisible { position(panel) }
            }
        }
        if !panel.isVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
        hideWork?.cancel()
        hideWork = nil
        if let hideAfter {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        closingByApp = true
        panel?.orderOut(nil)
        closingByApp = false
    }

    func windowWillClose(_ notification: Notification) {
        hideWork?.cancel()
        hideWork = nil
        if !closingByApp { onClose?() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "OneDrive Opener"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // Die App ist nie aktiv – sonst wäre das Fenster sofort wieder verschwunden.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.preferredMaxLayoutWidth = 290
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        let stack = NSStackView(views: [icon, label])
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        panel.contentView = stack
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.layoutIfNeeded()
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16))
    }
}
