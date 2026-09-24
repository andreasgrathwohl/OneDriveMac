import AppKit

/// Office-Apps, deren Dateien über die Cloud-URL (mit AutoSpeichern) geöffnet werden können.
/// Alte Binärformate (.doc/.xls/.ppt) unterstützen kein AutoSpeichern und werden bewusst nicht beansprucht.
enum OfficeApp: String, CaseIterable {
    case word, excel, powerpoint

    var displayName: String {
        switch self {
        case .word: return "Word"
        case .excel: return "Excel"
        case .powerpoint: return "PowerPoint"
        }
    }

    var bundleID: String {
        switch self {
        case .word: return "com.microsoft.Word"
        case .excel: return "com.microsoft.Excel"
        case .powerpoint: return "com.microsoft.Powerpoint"
        }
    }

    /// Office-URI-Scheme (Adresse siehe `FileOpener.officeURI`)
    var scheme: String {
        switch self {
        case .word: return "ms-word"
        case .excel: return "ms-excel"
        case .powerpoint: return "ms-powerpoint"
        }
    }

    var extensions: [String] {
        switch self {
        case .word: return ["docx", "docm"]
        case .excel: return ["xlsx", "xlsm", "xlsb"]
        case .powerpoint: return ["pptx", "pptm"]
        }
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func forExtension(_ ext: String) -> OfficeApp? {
        let e = ext.lowercased()
        return allCases.first { $0.extensions.contains(e) }
    }
}
