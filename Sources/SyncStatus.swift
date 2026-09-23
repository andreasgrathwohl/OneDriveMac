import Foundation

enum SyncState: String {
    case synced = "synchronisiert"
    case pending = "Upload ausstehend"
    case conflict = "Konflikt"
    case unknown = "unbekannt"
}

/// Fragt über die File-Provider-Schnittstelle ab, ob OneDrive die lokale Datei bereits hochgeladen hat.
enum SyncStatus {
    static func current(_ file: URL) -> SyncState {
        var url = file
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true else { return .unknown }
        if v.ubiquitousItemHasUnresolvedConflicts == true { return .conflict }
        if v.ubiquitousItemIsUploading == true { return .pending }
        if let uploaded = v.ubiquitousItemIsUploaded { return uploaded ? .synced : .pending }
        return .unknown
    }

    /// Wartet bis zu `timeout` Sekunden, solange der Upload aussteht.
    static func waitForUpload(_ file: URL, timeout: Int) async -> SyncState {
        var state = current(file)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while state == .pending && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            state = current(file)
        }
        return state
    }
}
