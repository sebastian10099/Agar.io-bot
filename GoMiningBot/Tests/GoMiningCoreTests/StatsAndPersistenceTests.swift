import XCTest
@testable import GoMiningCore

final class StatsTests: XCTestCase {
    private func sell(_ pnl: Double, at: Double, held: Double? = nil, equity: Double = 1000) -> BotEvent {
        BotEvent(at: at, action: BotAction.sell, reason: "t", bidUSDT: 1, askUSDT: 1, quantity: 10, priceUSDT: 1,
                 feeUSDT: 0.01, realizedPnLUSDT: pnl, equityUSDT: equity, heldSeconds: held)
    }

    func testWinRateProfitFactorAndStreak() {
        let events = [sell(2, at: 1_000, held: 60), sell(-1, at: 2_000, held: 120), sell(1, at: 3_000, held: 180)]
        let s = PerformanceStats.compute(events: events, equity: [])
        XCTAssertEqual(s.closedTrades, 3)
        XCTAssertEqual(s.winRate, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.profitFactor ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(s.expectancy, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.bestTrade, 2)
        XCTAssertEqual(s.worstTrade, -1)
        XCTAssertEqual(s.averageHoldSeconds ?? 0, 120, accuracy: 1e-9)
        XCTAssertEqual(s.currentStreak, 1)
    }

    func testProfitFactorIsNilWithoutLosses() {
        let s = PerformanceStats.compute(events: [sell(1, at: 1), sell(2, at: 2)], equity: [])
        XCTAssertNil(s.profitFactor)
        XCTAssertEqual(s.winRate, 1)
    }

    func testMaxDrawdownFromEquityCurve() {
        let curve = [1000, 1010, 1005, 990, 1000].enumerated().map { EquityPoint(t: Double($0.offset) * 60, equity: $0.element) }
        let s = PerformanceStats.compute(events: [], equity: curve)
        XCTAssertEqual(s.maxDrawdownUSDT, 20, accuracy: 1e-9)
        XCTAssertEqual(s.maxDrawdownFraction, 20.0 / 1010.0, accuracy: 1e-9)
    }

    func testDailyResultsAreGrouped() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day: Double = 1_760_000_000 - (1_760_000_000.truncatingRemainder(dividingBy: 86_400))
        let events = [sell(1, at: day + 100), sell(2, at: day + 200), sell(-0.5, at: day + 86_400 + 5)]
        let s = PerformanceStats.compute(events: events, equity: [], calendar: calendar)
        XCTAssertEqual(s.days.count, 2)
        XCTAssertEqual(s.days[0].pnl, 3, accuracy: 1e-9)
        XCTAssertEqual(s.days[0].trades, 2)
        XCTAssertEqual(s.days[1].pnl, -0.5, accuracy: 1e-9)
    }

    func testEquityHistoryThrottlesAndThins() {
        var h = EquityHistory()
        XCTAssertTrue(h.append(EquityPoint(t: 0, equity: 1)))
        XCTAssertFalse(h.append(EquityPoint(t: 30, equity: 2)))
        XCTAssertTrue(h.append(EquityPoint(t: 60, equity: 3)))
        for i in 2...(EquityHistory.maxPoints + 100) { h.append(EquityPoint(t: Double(i) * 60, equity: Double(i))) }
        XCTAssertLessThanOrEqual(h.points.count, EquityHistory.maxPoints)
        // Die neuesten Punkte bleiben unberuehrt.
        XCTAssertEqual(h.points.last?.t, Double(EquityHistory.maxPoints + 100) * 60)
    }

    func testCSVExportUsesGermanFormat() {
        let e = BotEvent(at: 1_760_000_000, action: BotAction.sell, reason: "Ziel; \"fein\"", bidUSDT: 1, askUSDT: 1,
                         quantity: 10.5, priceUSDT: 1.25, feeUSDT: 0.01, realizedPnLUSDT: 0.5, equityUSDT: 1000,
                         heldSeconds: 120, netBps: 80)
        let csv = CSVExport.trades([e])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Zeit;Aktion"))
        XCTAssertTrue(lines[1].contains("10,5000"))
        XCTAssertTrue(lines[1].contains("\"Ziel; \"\"fein\"\"\""))
        XCTAssertTrue(CSVExport.trades([e], decimalComma: false).contains("10.5000"))
    }
}

final class PersistenceTests: XCTestCase {
    private func tempPaths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gomining-test-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.prepare()
        return paths
    }

    func testSaveAndLoadRoundTrip() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = StateStore(paths: paths)
        var stored = StoredBot.fresh(at: Fixture.now, seedStartPosition: true)
        stored.state.cashUSDT = 123.45
        try store.save(stored)
        let outcome = store.load()
        XCTAssertEqual(outcome.stored?.state.cashUSDT, 123.45)
        XCTAssertNil(outcome.note)
    }

    func testCorruptFileFallsBackToBackup() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = StateStore(paths: paths)
        var stored = StoredBot.fresh(at: Fixture.now, seedStartPosition: false)
        stored.state.cashUSDT = 777
        try store.save(stored)                                   // legt auch die erste Sicherung an
        try Data("{ kaputt".utf8).write(to: paths.stateFile)
        let outcome = store.load()
        XCTAssertEqual(outcome.stored?.state.cashUSDT, 777)
        XCTAssertNotNil(outcome.note)
    }

    func testMissingFileLoadsNothing() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let outcome = StateStore(paths: paths).load()
        XCTAssertNil(outcome.stored)
    }

    func testOldVersionIsBackedUpBeforeUse() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let legacy = """
        {"state":{"cashUSDT":10,"tokens":0,"costBasisUSDT":0,"realizedPnLUSDT":0,"totalFeesUSDT":0,"anchorUSDT":0,
        "lastTradeAt":0,"day":"2026-10-10","dayStartEquityUSDT":10,"running":true},"settings":{},"events":[]}
        """
        try Data(legacy.utf8).write(to: paths.stateFile)
        let outcome = StateStore(paths: paths).load()
        XCTAssertNotNil(outcome.stored)
        XCTAssertNotNil(outcome.note)
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.backupsDirectory.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("simulation-vor-update-") })
    }

    func testLegacyDataIsCopiedOnceAndOldFolderStays() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("gomining-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let legacy = base.appendingPathComponent(AppPaths.legacyFolderName, isDirectory: true)
        let root = base.appendingPathComponent(AppPaths.folderName, isDirectory: true)
        try fm.createDirectory(at: legacy.appendingPathComponent("backups"), withIntermediateDirectories: true)
        try Data("alt".utf8).write(to: legacy.appendingPathComponent("simulation.json"))
        try Data("b".utf8).write(to: legacy.appendingPathComponent("backups/eins.json"))

        XCTAssertTrue(AppPaths.importLegacyData(from: legacy, to: root))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("simulation.json"), encoding: .utf8), "alt")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("backups/eins.json").path))
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("simulation.json").path))
        XCTAssertFalse(fm.fileExists(atPath: root.path + ".import"))

        // Zweiter Start: eigener Ordner existiert, nichts wird ueberschrieben.
        try Data("neu".utf8).write(to: root.appendingPathComponent("simulation.json"))
        XCTAssertFalse(AppPaths.importLegacyData(from: legacy, to: root))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("simulation.json"), encoding: .utf8), "neu")
    }

    func testLegacyImportSkipsFoldersWithoutAccount() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("gomining-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let legacy = base.appendingPathComponent(AppPaths.legacyFolderName, isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let root = base.appendingPathComponent(AppPaths.folderName, isDirectory: true)
        XCTAssertFalse(AppPaths.importLegacyData(from: legacy, to: root))
        XCTAssertFalse(AppPaths.importLegacyData(from: base.appendingPathComponent("fehlt"), to: root))
        XCTAssertFalse(fm.fileExists(atPath: root.path))
    }

    func testCandleCacheMergeDropsOldAndDuplicates() {
        let now = 1_760_000_000.0
        let old = PriceCandle(openedAt: now - 60 * 86_400, close: 1, volume: 1)
        let a = PriceCandle(openedAt: now - 120, open: 1, high: 1.1, low: 0.9, close: 1.05, volume: 1)
        let aNew = PriceCandle(openedAt: now - 120, open: 1, high: 1.2, low: 0.9, close: 1.1, volume: 2)
        let merged = CandleCache.merged([old, a], [aNew], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].close, 1.1)
        // Zeilenformat ueberlebt Speichern und Laden.
        let cache = CandleCache(candles: merged)
        let data = try! JSONEncoder().encode(cache)
        let back = try! JSONDecoder().decode(CandleCache.self, from: data).candles
        XCTAssertEqual(back, merged)
    }

    func testJournalWritesDailyFilesAndPrunes() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let journal = MarketJournal(directory: paths.journalDirectory, legacyDirectory: paths.legacyJournalDirectory, retentionDays: 7)
        let entry = JournalEntry(t: Fixture.now, bid: 1, ask: 1.01, bids: [[1, 10]], asks: [[1.01, 10]], share: 0.6,
                                 act: "Warten", why: "x", cash: 1000, tokens: 0, eq: 1000, hold: nil, candle: nil)
        journal.append(entry)
        journal.flushAndWait()
        let day = BotEngine.utcDay(Fixture.now)
        let file = paths.journalDirectory.appendingPathComponent("\(day).jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertGreaterThan(journal.diskUsageBytes(), 0)

        // Eine alte Datei wird beim Aufraeumen entfernt, die heutige bleibt.
        let oldFile = paths.journalDirectory.appendingPathComponent("2020-01-01.jsonl")
        try Data("x".utf8).write(to: oldFile)
        journal.prune(now: Fixture.now)
        journal.flushAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
