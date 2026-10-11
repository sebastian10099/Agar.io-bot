import Foundation

/// Speicherorte. Gleicher Ordner wie die bisherige App, damit `simulation.json` weiter genutzt wird:
/// `~/Library/Application Support/GoMining Bot/`
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard() -> AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return AppPaths(root: base.appendingPathComponent("GoMining Bot", isDirectory: true))
    }

    public var stateFile: URL { root.appendingPathComponent("simulation.json") }
    public var equityFile: URL { root.appendingPathComponent("equity-history.json") }
    public var candleCacheFile: URL { root.appendingPathComponent("candle-cache.json") }
    public var backupsDirectory: URL { root.appendingPathComponent("backups", isDirectory: true) }
    /// Neues, kompaktes Marktprotokoll.
    public var journalDirectory: URL { root.appendingPathComponent("market-journal-v2", isDirectory: true) }
    /// Protokoll der Vorgaengerversion (wird nur noch aufgeraeumt).
    public var legacyJournalDirectory: URL { root.appendingPathComponent("market-journal", isDirectory: true) }

    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, backupsDirectory, journalDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public enum JSONFile {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

/// Zeitstempel fuer Dateinamen (UTC, ohne Sonderzeichen).
func fileStamp(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: date)
}

// MARK: - Zustandsspeicher

/// Liest und schreibt `simulation.json` atomar. Alle Zugriffe laufen ueber eine serielle Queue;
/// `save` ist synchron (z. B. beim Beenden der App), `saveAsync` schreibt im Hintergrund.
public final class StateStore: @unchecked Sendable {
    public struct LoadOutcome: Sendable {
        public var stored: StoredBot?
        public var note: String?
    }

    private let paths: AppPaths
    private let queue = DispatchQueue(label: "gomining.state", qos: .utility)
    private var lastBackupAt = Date.distantPast          // nur auf der Queue benutzen
    private let backupInterval: TimeInterval = 30 * 60
    private let keepBackups = 12

    public init(paths: AppPaths) { self.paths = paths }

    /// Laedt `simulation.json`. Bei einer beschaedigten Datei wird sie beiseitegelegt und die
    /// juengste Sicherung verwendet.
    public func load() -> LoadOutcome {
        queue.sync { loadLocked() }
    }

    public func save(_ stored: StoredBot) throws {
        try queue.sync { try saveLocked(stored) }
    }

    public func saveAsync(_ stored: StoredBot, completion: (@Sendable (Error?) -> Void)? = nil) {
        queue.async { [self] in
            do {
                try saveLocked(stored)
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    /// Sicherung auf Wunsch (z. B. vor dem Zuruecksetzen).
    @discardableResult
    public func backupNow(_ stored: StoredBot, tag: String) -> URL? {
        queue.sync {
            try? paths.prepare()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(stored) else { return nil }
            let url = paths.backupsDirectory.appendingPathComponent("simulation-\(tag)-\(fileStamp()).json")
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            return url
        }
    }

    // MARK: Intern (nur auf der Queue)

    private func loadLocked() -> LoadOutcome {
        let fm = FileManager.default
        try? paths.prepare()
        guard fm.fileExists(atPath: paths.stateFile.path) else { return LoadOutcome(stored: nil, note: nil) }

        if let data = try? Data(contentsOf: paths.stateFile), let stored = try? JSONDecoder().decode(StoredBot.self, from: data) {
            var note: String?
            if (stored.version ?? 0) < StoredBot.currentVersion {
                // Vor dem Ueberschreiben mit dem neuen Format eine Kopie der alten Datei sichern.
                let backup = paths.backupsDirectory.appendingPathComponent("simulation-vor-update-\(fileStamp()).json")
                try? data.write(to: backup, options: .atomic)
                note = "Gespeicherter Zustand aus einer älteren Version geladen; eine Kopie liegt im Ordner „backups“."
            }
            return LoadOutcome(stored: stored, note: note)
        }

        // Beschaedigt: beiseitelegen und Sicherung versuchen.
        let corrupt = paths.root.appendingPathComponent("simulation.beschaedigt-\(fileStamp()).json")
        try? fm.moveItem(at: paths.stateFile, to: corrupt)
        for url in backupFiles() {
            if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(StoredBot.self, from: data) {
                return LoadOutcome(stored: stored, note: "simulation.json war beschädigt; die Sicherung \(url.lastPathComponent) wurde wiederhergestellt.")
            }
        }
        return LoadOutcome(stored: nil, note: "simulation.json war beschädigt und keine Sicherung war lesbar; die Datei wurde beiseitegelegt.")
    }

    private func saveLocked(_ stored: StoredBot) throws {
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        try data.write(to: paths.stateFile, options: .atomic)
        if Date().timeIntervalSince(lastBackupAt) >= backupInterval {
            lastBackupAt = Date()
            let url = paths.backupsDirectory.appendingPathComponent("simulation-\(fileStamp()).json")
            try? data.write(to: url, options: .atomic)
            pruneBackups()
        }
    }

    private func backupFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: paths.backupsDirectory, includingPropertiesForKeys: keys)) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        return urls.filter { $0.lastPathComponent.hasPrefix("simulation-") && $0.pathExtension == "json" }
            .sorted { modified($0) > modified($1) }
    }

    private func pruneBackups() {
        // Nur die automatischen Sicherungen (Zeitstempel direkt hinter "simulation-") rotieren.
        let auto = backupFiles().filter { url in
            url.lastPathComponent.dropFirst("simulation-".count).first?.isNumber == true
        }
        for url in auto.dropFirst(keepBackups) { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Kerzen-Zwischenspeicher

/// Kompakte Ablage fuer Kerzen (fuer Backtests und den laengeren Chart-Verlauf).
public struct CandleCache: Codable, Sendable {
    public var version = 1
    /// Zeilen `[openedAt, open, high, low, close, volume]`.
    public var rows: [[Double]] = []

    public init() {}

    public init(candles: [PriceCandle]) {
        rows = candles.map { [$0.openedAt, $0.open, $0.high, $0.low, $0.close, $0.volume] }
    }

    public var candles: [PriceCandle] {
        rows.compactMap { r in
            guard r.count >= 6 else { return nil }
            return PriceCandle(openedAt: r[0], open: r[1], high: r[2], low: r[3], close: r[4], volume: r[5])
        }
    }

    /// Fuegt neue Kerzen hinzu (neuere ersetzen gleiche Zeitstempel) und verwirft sehr alte.
    public static func merged(_ existing: [PriceCandle], _ new: [PriceCandle], now: Double, maxAgeDays: Double = 45) -> [PriceCandle] {
        let cutoff = now - maxAgeDays * 86_400
        return Indicators.normalize(existing + new).filter { $0.openedAt >= cutoff }
    }
}

// MARK: - Marktprotokoll

public struct JournalEntry: Codable, Sendable {
    public var v = 2
    public var t: Double
    public var bid: Double
    public var ask: Double
    /// Die besten Stufen als `[Preis, Menge]`.
    public var bids: [[Double]]
    public var asks: [[Double]]
    public var share: Double?
    public var act: String
    public var why: String
    public var cash: Double
    public var tokens: Double
    public var eq: Double
    public var hold: Double?
    /// Letzte abgeschlossene Kerze `[t, o, h, l, c, v]`.
    public var candle: [Double]?

    public init(t: Double, bid: Double, ask: Double, bids: [[Double]], asks: [[Double]], share: Double?, act: String,
                why: String, cash: Double, tokens: Double, eq: Double, hold: Double?, candle: [Double]?) {
        self.t = t
        self.bid = bid
        self.ask = ask
        self.bids = bids
        self.asks = asks
        self.share = share
        self.act = act
        self.why = why
        self.cash = cash
        self.tokens = tokens
        self.eq = eq
        self.hold = hold
        self.candle = candle
    }
}

/// Schreibt Marktprotokoll-Zeilen gepuffert im Hintergrund (eine Datei pro UTC-Tag).
public final class MarketJournal: @unchecked Sendable {
    private let directory: URL
    private let legacyDirectory: URL?
    private let queue = DispatchQueue(label: "gomining.journal", qos: .utility)
    private var buffer: [(day: String, line: Data)] = []
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let lock = NSLock()
    private var _status = "Marktprotokoll bereit"
    public var retentionDays: Int

    public init(directory: URL, legacyDirectory: URL? = nil, retentionDays: Int = 7) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.retentionDays = max(1, retentionDays)
    }

    public var status: String {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    private func setStatus(_ s: String) {
        lock.lock(); _status = s; lock.unlock()
    }

    public func append(_ entry: JournalEntry) {
        queue.async { [self] in
            guard let data = try? encoder.encode(entry) else { return }
            var line = data
            line.append(0x0a)
            buffer.append((BotEngine.utcDay(entry.t), line))
            if buffer.count >= 25 { writeBuffer() }
        }
    }

    public func flush() {
        queue.async { [self] in writeBuffer() }
    }

    /// Wartet, bis alles geschrieben ist (beim Beenden).
    public func flushAndWait() {
        queue.sync { writeBuffer() }
    }

    private func writeBuffer() {
        guard !buffer.isEmpty else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var byDay: [String: Data] = [:]
            for item in buffer { byDay[item.day, default: Data()].append(item.line) }
            for (day, data) in byDay {
                let url = directory.appendingPathComponent("\(day).jsonl")
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            buffer.removeAll(keepingCapacity: true)
            setStatus("Marktprotokoll aktiv · lokale Aufbewahrung bis \(retentionDays) Tage")
        } catch {
            buffer.removeAll(keepingCapacity: true)
            setStatus("Marktprotokoll fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Loescht Tagesdateien, die aelter als die Aufbewahrungsdauer sind (auch im alten Protokollordner).
    public func prune(now: Double) {
        queue.async { [self] in
            let today = BotEngine.dayIndex(now)
            for dir in [directory, legacyDirectory].compactMap({ $0 }) {
                let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for url in urls where url.pathExtension == "jsonl" {
                    let name = url.deletingPathExtension().lastPathComponent
                    if let idx = BotEngine.dayIndex(fromDay: name), idx < today - retentionDays {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        }
    }

    /// Belegter Speicher aller Protokolldateien (neu und alt).
    public func diskUsageBytes() -> Int64 {
        var total: Int64 = 0
        for dir in [directory, legacyDirectory].compactMap({ $0 }) {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in urls {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}

// MARK: - CSV-Export

public enum CSVExport {
    /// Trades als CSV fuer Excel/Numbers im deutschen Format (Semikolon, Komma als Dezimaltrennzeichen).
    public static func trades(_ events: [BotEvent], decimalComma: Bool = true) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func num(_ v: Double, _ digits: Int) -> String {
            let s = String(format: "%.\(digits)f", v)
            return decimalComma ? s.replacingOccurrences(of: ".", with: ",") : s
        }
        func text(_ s: String) -> String {
            let needsQuotes = s.contains(";") || s.contains("\"") || s.contains("\n")
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return needsQuotes ? "\"\(escaped)\"" : escaped
        }
        var lines = ["Zeit;Aktion;Menge;Preis (USDT);Gebühr (USDT);Realisiert (USDT);Netto (bp);Haltedauer (min);Vermögen (USDT);Grund"]
        for e in events where e.isTrade {
            let time = timeFormatter.string(from: Date(timeIntervalSince1970: e.at))
            let held = e.heldSeconds.map { num($0 / 60, 1) } ?? ""
            let netBps = e.netBps.map { num($0, 1) } ?? ""
            lines.append([time, e.action, num(e.quantity, 4), num(e.priceUSDT, 6), num(e.feeUSDT, 6),
                          e.isSell ? num(e.realizedPnLUSDT, 6) : "", netBps, held, num(e.equityUSDT, 4), text(e.reason)]
                .joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
