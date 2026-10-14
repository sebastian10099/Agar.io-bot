import XCTest
@testable import GoMiningCore

/// Deterministischer Zufall (SplitMix64) fuer reproduzierbare Fuzz- und Dauertests.
struct FuzzRNG {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

// MARK: - Selbstdiagnose

final class HealthMonitorTests: XCTestCase {
    private let now = 1_760_000_000.0

    private func input(book: Double = 1, stream: Double = 1, candles: Double = 30, trade: Double = 20,
                       network: Bool = true, errors: Int = 0, offset: Double? = 0.2, started: Double = 3_600) -> HealthInput {
        HealthInput(now: now, startedAt: now - started, lastStreamAt: stream < 0 ? 0 : now - stream,
                    lastBookAt: book < 0 ? 0 : now - book, candlesFetchedAt: now - candles, lastTradeAt: now - trade,
                    networkAvailable: network, recentErrors: errors, clockOffset: offset)
    }

    func testHealthyIsOK() {
        let r = HealthMonitor.evaluate(input())
        XCTAssertEqual(r.level, .ok)
        XCTAssertTrue(r.issues.isEmpty)
        XCTAssertEqual(r.summary, "Alles in Ordnung")
    }

    func testNoNetworkIsOffline() {
        let r = HealthMonitor.evaluate(input(network: false))
        XCTAssertEqual(r.level, .offline)
        XCTAssertTrue(r.isOffline)
        XCTAssertTrue(r.summary.hasPrefix("Offline: Keine Internetverbindung"))
    }

    func testStaleBookLevels() {
        XCTAssertEqual(HealthMonitor.evaluate(input(book: 20, stream: 20)).level, .warning)
        let offline = HealthMonitor.evaluate(input(book: 200, stream: 200))
        XCTAssertEqual(offline.level, .offline)
        XCTAssertTrue(offline.issues.first?.title.hasPrefix("Keine Marktdaten seit") ?? false)
    }

    func testStartupGraceAndNeverReceived() {
        // Direkt nach dem Start ist "noch nie Daten" normal ...
        XCTAssertEqual(HealthMonitor.evaluate(input(book: -1, stream: -1, started: 5)).level, .ok)
        // ... nach einer Minute nicht mehr.
        let r = HealthMonitor.evaluate(input(book: -1, stream: -1, started: 120))
        XCTAssertEqual(r.level, .offline)
        XCTAssertTrue(r.issues.first?.title.contains("noch nie") ?? false)
    }

    func testStreamStallWithRESTFallbackIsWarning() {
        let r = HealthMonitor.evaluate(input(book: 3, stream: 90))
        XCTAssertEqual(r.level, .warning)
        XCTAssertTrue(r.issues.contains { $0.title == "Livestream hängt" })
    }

    func testOtherWarningsAndInfo() {
        XCTAssertTrue(HealthMonitor.evaluate(input(candles: 600)).issues.contains { $0.title.hasPrefix("Kurskerzen veraltet") })
        XCTAssertTrue(HealthMonitor.evaluate(input(errors: 6)).issues.contains { $0.title.hasPrefix("Viele Fehler") })
        XCTAssertTrue(HealthMonitor.evaluate(input(offset: -12)).issues.contains { $0.title.hasPrefix("Mac-Uhr weicht") })
        let quiet = HealthMonitor.evaluate(input(trade: 3_600))
        XCTAssertEqual(quiet.level, .info)
        XCTAssertEqual(quiet.summary, "Alles in Ordnung")
    }

    func testIssuesAreSortedWorstFirst() {
        let r = HealthMonitor.evaluate(input(candles: 600, network: false, errors: 9))
        XCTAssertEqual(r.issues.first?.level, .offline)
        XCTAssertEqual(r.issues.map(\.level), r.issues.map(\.level).sorted(by: >))
    }
}

// MARK: - Kerzenspeicher

final class CandleStoreTests: XCTestCase {
    private func tempPaths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gomining-store-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.prepare()
        return paths
    }

    func testRoundTripIsExactAndCompact() throws {
        let candles = Fixture.sineCandles(count: 5_000)
        let data = CandleStore.encode(candles)
        XCTAssertEqual(data.count, 8 + 5_000 * 48)
        let back = try XCTUnwrap(CandleStore.decode(data))
        XCTAssertEqual(back, candles)
    }

    func testBrokenDataIsRejected() {
        let data = CandleStore.encode(Fixture.sineCandles(count: 10))
        XCTAssertNil(CandleStore.decode(data.prefix(data.count - 1)))
        XCTAssertNil(CandleStore.decode(Data("GMC2".utf8) + data.dropFirst(4)))
        XCTAssertNil(CandleStore.decode(Data()))
        XCTAssertEqual(CandleStore.decode(CandleStore.encode([]))?.count, 0)
    }

    func testLegacyJSONIsReadAndReplaced() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let candles = Fixture.sineCandles(count: 300)
        try JSONFile.write(CandleCache(candles: candles), to: paths.candleCacheFile)
        XCTAssertEqual(CandleStore.load(paths: paths).count, 300)
        try CandleStore.save(candles, paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.candleCacheFile.path))
        XCTAssertEqual(CandleStore.load(paths: paths), candles)
    }

    func testRetentionIs90Days() {
        let now = 1_760_000_000.0
        let old = PriceCandle(openedAt: now - 80 * 86_400, close: 1, volume: 1)
        let tooOld = PriceCandle(openedAt: now - 95 * 86_400, close: 1, volume: 1)
        let merged = CandleCache.merged([tooOld, old], [], now: now)
        XCTAssertEqual(merged.map(\.openedAt), [old.openedAt])
    }
}

// MARK: - Sicherungen

final class BackupRestoreTests: XCTestCase {
    func testBackupsAreListedWithKindAndCanBeRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gomining-backup-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(paths: paths)
        var stored = StoredBot.fresh(at: Fixture.now, seedStartPosition: false)
        stored.state.cashUSDT = 900
        stored.record(BotEvent(at: Fixture.now, action: BotAction.sell, reason: "t", bidUSDT: 1, askUSDT: 1, quantity: 5,
                               priceUSDT: 1, realizedPnLUSDT: 0.5, equityUSDT: 1_000))
        try store.save(stored)                                        // erste Speicherung legt eine automatische Sicherung an
        let manual = try XCTUnwrap(store.backupNow(stored, tag: "vor-reset"))
        let list = store.listBackups()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.kind)), ["automatisch", "vor dem Zurücksetzen"])
        XCTAssertTrue(list.allSatisfy { $0.bytes > 0 })
        let read = try XCTUnwrap(StateStore.readBackup(manual))
        XCTAssertEqual(read.state.cashUSDT, 900)
        let summary = StoredBotSummary(read)
        XCTAssertEqual(summary.trades, 1)
        XCTAssertEqual(summary.sells, 1)
        XCTAssertEqual(summary.cash, 900)
        XCTAssertEqual(summary.lastTradeAt, Fixture.now)
        XCTAssertNil(StateStore.readBackup(root.appendingPathComponent("fehlt.json")))
    }
}

// MARK: - Fuzz-Tests

final class FuzzTests: XCTestCase {
    static let seeds: [String] = [
        #"{"code":0,"data":[[1700000060000,"1.05","1.10","1.00","1.08","50",1700000119999,"54"],[1700000000000,"1.00","1.06","0.98","1.05","40"]]}"#,
        #"{"code":0,"data":[{"time":1700000000000,"open":"1","high":"2","low":"0.5","close":"1.5","volume":"9"}]}"#,
        #"{"code":0,"data":{"bids":[["0.99","10"],["1.00","5"]],"asks":[["1.03","2"],["1.01","7"]],"lastUpdateId":77}}"#,
        #"{"code":0,"data":[{"id":2,"price":"1.02","qty":"10","time":1700000010000,"buyerMaker":false}]}"#,
        #"{"code":0,"dataType":"GOMINING-USDT@trade","data":{"E":1700000000000,"T":1700000000001,"m":false,"p":"1.2","q":"10","t":99}}"#,
        #"{"code":0,"dataType":"GOMINING-USDT@depth20","data":{"bids":[["1.0","3"]],"asks":[["1.1","4"]],"lastUpdateId":5}}"#,
        #"{"code":0,"data":{"symbols":[{"symbol":"GOMINING-USDT","status":1,"minQty":0.01,"minNotional":2,"stepSize":0.01}]}}"#,
        #"{"code":0,"data":{"balances":[{"asset":"USDT","free":"12.5","locked":"0"}]}}"#,
        #"{"code":0,"data":{"commission":{"takerCommissionRate":0.001,"makerCommissionRate":0.001}}}"#,
        #"{"tag_name":"gomining-bot-v4.4","html_url":"https://x/y","assets":[{"name":"GoMining-Bot.zip","browser_download_url":"https://x/z"}]}"#,
        #"{"t":1760000000,"bid":1,"ask":1.01,"bids":[[1,5]],"asks":[[1.01,5]],"share":0.6,"candle":[1759999940,1,1.1,0.9,1.05,7]}"#,
        #"{"format":"gomining-bot-profile","version":1,"appVersion":"4.4","profile":{"name":"A","settings":{"minNetProfitBps":60},"createdAt":1}}"#,
        #"{"state":{"cashUSDT":10,"day":"2026-10-10","dayStartEquityUSDT":10,"lots":[{"quantity":5,"costBasisUSDT":5}]},"settings":{"feeBps":10},"events":[{"at":1,"action":"Kauf","reason":"x"}],"version":4}"#,
    ]

    static let tokens = ["null", "-1", "0", "1e309", "-1e308", "9999999999999999999999", "\"NaN\"", "\"inf\"", "[]", "{}", "\"\"",
                         "true", ",", "]", "}", "[", "{", "\"x\"", "1700000000000", "-0", "\"9e99\"", "[[[[[", "0.0000001"]

    static func mutate(_ seed: [UInt8], _ rng: inout FuzzRNG) -> Data {
        var b = seed
        for _ in 0...rng.int(4) {
            switch rng.int(7) {
            case 0 where !b.isEmpty:                                           // Byte kippen
                b[rng.int(b.count)] = UInt8(truncatingIfNeeded: rng.next())
            case 1 where b.count > 2:                                          // Bereich loeschen
                let a = rng.int(b.count), len = min(b.count - a, 1 + rng.int(12))
                b.removeSubrange(a..<(a + len))
            case 2:                                                            // Token einfuegen
                let t = Array(tokens[rng.int(tokens.count)].utf8)
                b.insert(contentsOf: t, at: rng.int(b.count + 1))
            case 3 where b.count > 1:                                          // abschneiden
                b = Array(b.prefix(rng.int(b.count)))
            case 4 where !b.isEmpty:                                           // Bereich verdoppeln
                let a = rng.int(b.count), len = min(b.count - a, 1 + rng.int(20))
                b.insert(contentsOf: b[a..<(a + len)], at: rng.int(b.count + 1))
            case 5:                                                            // Zahl durch Token ersetzen
                if let i = b.firstIndex(where: { (48...57).contains($0) }) {
                    var j = i
                    while j < b.count, (48...57).contains(b[j]) || b[j] == 46 { j += 1 }
                    b.replaceSubrange(i..<j, with: Array(tokens[rng.int(tokens.count)].utf8))
                }
            default:                                                           // reiner Zufall
                b = (0..<rng.int(64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            }
        }
        return Data(b)
    }

    private func checkCandles(_ candles: [PriceCandle], file: StaticString = #filePath, line: UInt = #line) {
        for c in candles {
            XCTAssertTrue([c.openedAt, c.open, c.high, c.low, c.close, c.volume].allSatisfy(\.isFinite), file: file, line: line)
            XCTAssertGreaterThanOrEqual(c.high, c.low, file: file, line: line)
            XCTAssertGreaterThan(c.close, 0, file: file, line: line)
        }
        // Folgeverarbeitung darf nicht abstuerzen.
        _ = Indicators.fillGaps(candles)
        if let last = candles.last { _ = Indicators.extendFlat(candles, upTo: last.openedAt + 600) }
        _ = Indicators.volatilityBps(candles)
    }

    func testParsersSurviveMutatedInput() {
        var rng = FuzzRNG(seed: 0x4744_4D42)
        let decoder = JSONDecoder()
        var accepted = 0
        for seed in Self.seeds {
            let bytes = Array(seed.utf8)
            for _ in 0..<500 {
                let data = Self.mutate(bytes, &rng)
                if let candles = try? BingXParser.parseKlines(data) {
                    accepted += 1
                    checkCandles(candles)
                    XCTAssertTrue(candles.allSatisfy { (946_684_800...4_102_444_800).contains($0.openedAt) })
                }
                if let book = try? BingXParser.parseDepth(data) {
                    XCTAssertTrue(book.bids.allSatisfy { $0.price > 0 && $0.quantity > 0 && $0.price.isFinite })
                    XCTAssertEqual(book.bids.map(\.price), book.bids.map(\.price).sorted(by: >))
                }
                if let trades = try? BingXParser.parseTrades(data) {
                    XCTAssertTrue(trades.allSatisfy { $0.price > 0 && $0.quantity > 0 && $0.at.isFinite })
                }
                switch BingXParser.parseStream(data) {
                case .trades(let list): XCTAssertTrue(list.allSatisfy { $0.price > 0 })
                case .depth(let bids, let asks, _): XCTAssertFalse(bids.isEmpty || asks.isEmpty)
                default: break
                }
                _ = try? BingXParser.parseSymbolRules(data, symbol: "GOMINING-USDT")
                _ = try? BingXParser.parseBalances(data)
                _ = try? BingXParser.parseCommission(data)
                _ = ReleaseParser.parseLatest(data)
                let journal = JournalReader.parse(data)
                for (frame, candle) in journal.rows {
                    XCTAssertTrue(frame.bids.allSatisfy { $0.price > 0 })
                    if let candle { checkCandles([candle]) }
                }
                _ = ProfileFile.decode(data)
                _ = try? SafeJSON.decode(StoredBot.self, from: data, decoder: decoder)
                _ = try? SafeJSON.decode(ShadowBook.self, from: data, decoder: decoder)
                _ = try? SafeJSON.decode(ProfileBook.self, from: data, decoder: decoder)
                _ = try? SafeJSON.decode(BotSettings.self, from: data, decoder: decoder).clamped()
                _ = Gzip.decode(data)
                _ = AppVersion(String(decoding: data.prefix(40), as: UTF8.self))
                if let candles = CandleStore.decode(data) { checkCandles(candles) }
            }
        }
        XCTAssertGreaterThan(accepted, 0, "einige Mutationen sollten noch gültige Kerzen ergeben")
    }

    /// Apples JSONDecoder stuerzt bei einem Steuerzeichen in einem Schluessel ab; SafeJSON lehnt solche Daten vorher ab.
    func testControlCharacterInKeyIsRejectedNotCrashing() {
        let broken = Data([0x7b, 0x22, 0x73, 0x74, 0x61, 0x1d, 0x74, 0x65, 0x22, 0x3a, 0x31, 0x7d])     // {"sta\u{1D}te":1}
        XCTAssertThrowsError(try SafeJSON.decode(StoredBot.self, from: broken))
        XCTAssertThrowsError(try SafeJSON.decode(BotSettings.self, from: broken))
        XCTAssertNoThrow(try SafeJSON.decode(BotSettings.self, from: Data("{}".utf8)))
    }

    func testHugeNumbersDoNotCrash() throws {
        let huge = #"{"code":1e300,"msg":"x","data":{"bids":[["1","1"]],"asks":[["2","1"]],"lastUpdateId":1e300}}"#
        XCTAssertThrowsError(try BingXParser.parseDepth(Data(huge.utf8)))
        let seq = #"{"code":0,"data":{"bids":[["1","1"]],"asks":[["2","1"]],"lastUpdateId":1e300}}"#
        XCTAssertNil(try BingXParser.parseDepth(Data(seq.utf8)).sequence)
        let trade = #"{"code":0,"data":[{"id":1e300,"price":"1","qty":"1","time":1700000000000}]}"#
        XCTAssertEqual(try BingXParser.parseTrades(Data(trade.utf8)).count, 1)
        let farFuture = #"{"code":0,"data":[[1e300,"1","1","1","1","1"],[1700000000000,"1","1","1","1","1"]]}"#
        XCTAssertEqual(try BingXParser.parseKlines(Data(farFuture.utf8)).count, 1)
        if case .error = BingXParser.parseStream(Data(#"{"code":-1e300}"#.utf8)) {} else { XCTFail("Fehlercode erwartet") }
    }

    func testGapFillingSurvivesAbsurdTimes() {
        let a = PriceCandle(openedAt: 1_700_000_000, close: 1, volume: 1)
        let b = PriceCandle(openedAt: 1e300, close: 1, volume: 1)
        XCTAssertEqual(Indicators.fillGaps([a, b]).count, 2)
        XCTAssertEqual(Indicators.extendFlat([a], upTo: 1e300).count, 1)
        XCTAssertEqual(Indicators.extendFlat([a], upTo: .infinity).count, 1)
    }
}

// MARK: - Dauertest der Engine

final class EngineSoakTests: XCTestCase {
    /// Zehntausende Marktmomente mit Zufallskurs, Spruengen, duennen Buechern und Trades: Bargeld nie negativ,
    /// Bestand = Summe der Lose, Vermoegen endlich, keine unbegrenzt wachsenden Listen.
    func testInvariantsHoldOverManySteps() {
        for variant in 0..<4 {
            var rng = FuzzRNG(seed: UInt64(1_000 + variant))
            var s = BotSettings()
            s.minSecondsBetweenTrades = 2
            s.makerEntries = variant % 2 == 1
            s.minBuyStepBps = variant >= 2 ? 0 : 80
            s.trailingStopBps = variant == 3 ? 40 : 0
            s = s.clamped()
            let rules = SymbolRules(minQuantity: 1, minNotional: 1, stepSize: 0.01)
            var now = Fixture.now
            var state = BotState.fresh(s, at: now)
            var price = 1.0
            var candles = Fixture.candles(price: price, count: 140, now: now)
            var trades: [PublicTrade] = []
            var tradeID: Int64 = 1
            var events = 0
            for step in 0..<12_000 {
                now += 5
                // Kurs: Zufallsschritt, selten Spruenge.
                var move = (rng.unit() - 0.5) * 0.004
                if rng.chance(0.002) { move += (rng.unit() - 0.6) * 0.08 }
                price = max(0.05, price * (1 + move))
                if step % 12 == 0 {
                    let last = candles[candles.count - 1]
                    candles.append(PriceCandle(openedAt: last.openedAt + 60, open: last.close, high: max(last.close, price),
                                               low: min(last.close, price), close: price, volume: 10 + rng.unit() * 100))
                    if candles.count > 300 { candles.removeFirst(candles.count - 300) }
                }
                let spread = 0.0005 + rng.unit() * 0.004
                let depth = rng.chance(0.05) ? 5.0 : 5_000.0                     // gelegentlich sehr duenn
                let bids = (0..<5).map { PriceLevel(price: price * (1 - spread / 2) * (1 - 0.001 * Double($0)), quantity: depth) }
                let asks = (0..<5).map { PriceLevel(price: price * (1 + spread / 2) * (1 + 0.001 * Double($0)), quantity: depth) }
                for _ in 0..<rng.int(3) {
                    let buyer = rng.chance(0.5)
                    trades.append(PublicTrade(id: tradeID, at: now - rng.unit(), price: buyer ? asks[0].price : bids[0].price,
                                              quantity: 1 + rng.unit() * 8_000, buyerInitiated: buyer))
                    tradeID += 1
                }
                trades.removeAll { now - $0.at > 600 }
                let snap = MarketSnapshot(receivedAt: now, bookAt: now - rng.unit(), candles: candles, asks: asks, bids: bids,
                                          rules: rules, trades: trades)
                let r = BotEngine.step(snap, state: &state, settings: s, fastMoveBps: (rng.unit() - 0.5) * 40, now: now,
                                       verbose: step % 50 == 0)
                if r.event != nil { events += 1 }

                XCTAssertGreaterThanOrEqual(state.cashUSDT, -1e-6, "Bargeld negativ (Variante \(variant), Schritt \(step))")
                XCTAssertEqual(state.tokens, state.lots.reduce(0) { $0 + $1.quantity }, accuracy: 1e-6)
                XCTAssertTrue(state.equity(atBid: bids[0].price).isFinite)
                XCTAssertGreaterThanOrEqual(state.totalFeesUSDT, 0)
                XCTAssertLessThanOrEqual(state.lots.count, max(10, s.openPositionLimit * 2) + 1)
                XCTAssertTrue(state.lots.allSatisfy { $0.quantity > 0 && $0.costBasisUSDT.isFinite })
                if state.cashUSDT < -1e-6 { return }                          // eine Meldung genuegt
            }
            XCTAssertGreaterThan(events, 0, "Variante \(variant) sollte handeln")
        }
    }
}

final class DateRobustnessTests: XCTestCase {
    func testAbsurdTimesAndDaysDoNotCrash() throws {
        XCTAssertEqual(BotEngine.dayIndex(.nan), 0)
        XCTAssertEqual(BotEngine.dayIndex(1e300), 3_000_000)
        XCTAssertFalse(BotEngine.utcDay(-1e300).isEmpty)
        XCTAssertNil(BotEngine.dayIndex(fromDay: "99999999999999999-01-01"))
        XCTAssertEqual(BotEngine.dayIndex(fromDay: "1970-01-02"), 1)
        // Schattenkonto mit unsinniger Anlagezeit laedt trotzdem.
        let json = #"{"accounts":[{"name":"Kaputt","createdAt":-1e300}]}"#
        let book = try JSONDecoder().decode(ShadowBook.self, from: Data(json.utf8))
        XCTAssertEqual(book.accounts.first?.name, "Kaputt")
    }
}
