import AppKit

/// Aktualisiert die App selbst aus den GitHub-Releases (öffentliches Repo, keine Anmeldung nötig).
///
/// Ablauf: Release abfragen → ZIP laden → entpacken und prüfen (gleiche Bundle-ID, gültige Signatur) →
/// ein kleines Hilfsskript wartet, bis die App beendet ist, tauscht das Bundle aus, übernimmt die
/// lokal kopierten Office-Symbole und startet die neue Version.
@MainActor
final class Updater {
    static let shared = Updater()

    struct Release {
        let version: String
        let zipURL: URL
    }

    private(set) var available: Release?
    private(set) var status = "noch nicht geprüft"
    private var timer: Timer?
    private var installing = false

    private init() {}

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        guard userInitiated || Settings.autoUpdate,
              let url = URL(string: "https://api.github.com/repos/\(Settings.updateRepository)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OneDriveOpener/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                status = "Prüfung fehlgeschlagen"
                return
            }
            let version = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let assets = json["assets"] as? [[String: Any]] ?? []
            guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let link = asset["browser_download_url"] as? String,
                  let zipURL = URL(string: link) else {
                status = "Aktuell (Version \(currentVersion))"
                return
            }
            if Self.isNewer(version, than: currentVersion) {
                available = Release(version: version, zipURL: zipURL)
                status = "Version \(version) verfügbar"
                Log.info("Update verfügbar: \(currentVersion) → \(version)")
                AppState.changed()
                // Ist dieselbe Version schon einmal gescheitert, nicht bei jedem Start erneut neu starten.
                let failedBefore = UserDefaults.standard.string(forKey: Self.attemptedKey) == version
                // Nicht mitten in einer Aktion neu starten (Dokument wird neu geöffnet, Dialog offen).
                let idle = !WordIntegration.shared.isBusy && NSApp.modalWindow == nil
                if userInitiated || (Settings.autoUpdate && !failedBefore && idle) { await install() }
            } else {
                available = nil
                status = "Aktuell (Version \(currentVersion))"
            }
        } catch {
            status = "Prüfung fehlgeschlagen"
            Log.error("Update-Prüfung fehlgeschlagen: \(error.localizedDescription)")
        }
        AppState.changed()
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static let attemptedKey = "UpdateAttemptedVersion"

    func install() async {
        guard let release = available, !installing else { return }
        let target = Bundle.main.bundleURL
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path), fm.isWritableFile(atPath: target.path) else {
            status = "Version \(release.version) verfügbar – keine Schreibrechte, bitte manuell installieren"
            Log.error("Update: \(target.path) ist nicht beschreibbar")
            return
        }
        installing = true
        defer { installing = false }
        status = "Version \(release.version) wird installiert …"
        AppState.changed()

        do {
            let work = fm.temporaryDirectory.appendingPathComponent("OneDriveOpener-Update-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let (download, _) = try await URLSession.shared.download(from: release.zipURL)
            let zip = work.appendingPathComponent("update.zip")
            try fm.moveItem(at: download, to: zip)

            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]),
                  let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
                  NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) else {
                status = "Update fehlgeschlagen (ungültiges Paket)"
                Log.error("Update \(release.version): Paket ungültig")
                return
            }

            guard Self.spawnDetached(["/bin/sh", "-c", Self.swapScript, "sh",
                                      String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path]) else {
                status = "Update fehlgeschlagen"
                Log.error("Update \(release.version): Hilfsprozess konnte nicht gestartet werden")
                return
            }
            UserDefaults.standard.set(release.version, forKey: Self.attemptedKey)
            Log.info("Update auf \(release.version) wird installiert – OneDrive Opener startet neu")
            NSApp.terminate(nil)
        } catch {
            status = "Update fehlgeschlagen"
            Log.error("Update \(release.version) fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// $1 = PID der laufenden App, $2 = neue App, $3 = installierte App.
    private static let swapScript = """
    while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
    found=0
    for f in "$3"/Contents/Resources/Doc-*.icns; do
      [ -f "$f" ] && cp "$f" "$2/Contents/Resources/" && found=1
    done
    if [ "$found" = 1 ] && ! /usr/bin/codesign --force --sign - --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$2"; then
      rm -f "$2"/Contents/Resources/Doc-*.icns
    fi
    rm -rf "$3.old"
    if mv "$3" "$3.old"; then
      if mv "$2" "$3"; then rm -rf "$3.old"; else mv "$3.old" "$3"; fi
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$3" 2>/dev/null
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$3"
    /usr/bin/open "$3"
    """

    /// Startet den Hilfsprozess in einer eigenen Sitzung – launchd beendet sonst beim Beenden der App
    /// (z. B. als Startobjekt) deren ganze Prozessgruppe mit.
    private static func spawnDetached(_ arguments: [String]) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, arguments[0], &actions, &attr, argv, envp) == 0
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
