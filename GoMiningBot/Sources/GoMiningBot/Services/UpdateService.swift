import Foundation
import GoMiningCore

enum UpdateError: LocalizedError {
    case http(Int)
    case noRelease
    case invalidDownload(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return code == 403 ? "GitHub-Abfragelimit erreicht, später erneut versuchen" : "GitHub antwortet mit Status \(code)"
        case .noRelease: return "Noch keine veröffentlichte Version gefunden"
        case .invalidDownload(let why): return "Download ungültig: \(why)"
        }
    }
}

/// Neue Versionen werden als GitHub-Release mit `GoMining-Bot.zip` veroeffentlicht.
struct UpdateService: Sendable {
    static let repository = "sebastian10099/Agar.io-bot"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    static let bundleIdentifier = "com.sebastian.gominingbot"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = [
            "User-Agent": "GoMiningBotMac/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4")",
            "Accept": "application/vnd.github+json",
        ]
        session = URLSession(configuration: config)
    }

    func latestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError.noRelease }
        guard status == 200 else { throw UpdateError.http(status) }
        guard let info = ReleaseParser.parseLatest(data) else { throw UpdateError.noRelease }
        return info
    }

    /// Laedt und entpackt die neue Version und prueft sie. Gibt den Pfad der neuen App zurueck.
    func download(_ release: ReleaseInfo, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard let url = release.downloadURL else { throw UpdateError.invalidDownload("kein App-Archiv im Release") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("gomining-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        progress("Lade Version \(release.version) …")
        let (file, response) = try await session.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        let zip = work.appendingPathComponent("GoMining-Bot.zip")
        try FileManager.default.moveItem(at: file, to: zip)

        progress("Entpacke …")
        let unpacked = work.appendingPathComponent("neu", isDirectory: true)
        guard try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else {
            throw UpdateError.invalidDownload("Archiv lässt sich nicht entpacken")
        }
        let app = unpacked.appendingPathComponent("GoMining Bot.app", isDirectory: true)
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Self.bundleIdentifier else {
            throw UpdateError.invalidDownload("unerwarteter Inhalt")
        }
        let newVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
        guard let newVersion, newVersion == release.version else {
            throw UpdateError.invalidDownload("Versionsnummer passt nicht")
        }
        progress("Prüfe Signatur …")
        guard try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError.invalidDownload("Signatur ungültig")
        }
        return app
    }

    /// Startet das Installationsskript, das nach dem Beenden der App die neue Version einsetzt und startet.
    func scheduleInstall(newApp: URL, replacing target: URL) throws {
        let script = newApp.deletingLastPathComponent().appendingPathComponent("install.sh")
        try UpdateInstaller.script.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path, "open"]
        try process.run()
    }

    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
