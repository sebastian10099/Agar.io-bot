import XCTest
@testable import GoMiningCore

// MARK: - Walk-forward und Robustheit

final class WalkForwardTests: XCTestCase {
    private func result(_ pnl: Double) -> BacktestResult {
        var r = BacktestResult()
        r.startingUSDT = 1_000
        r.finalEquity = 1_000 + pnl
        return r
    }

    private func entry(_ id: Int, _ segments: [Double], test: Double? = nil) -> OptimizerEntry {
        OptimizerEntry(id: id, values: [Double(id)], settings: BotSettings(), train: result(0),
                       test: test.map(result), segments: segments.map(result))
    }

    func testSegmentRangesAreContiguousAndNeedEnoughCandles() {
        let n = Backtester.warmupCandles + 4 * Optimizer.minSegmentCandles
        let ranges = Optimizer.segmentRanges(candleCount: n, count: 4)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges.first?.lowerBound, Backtester.warmupCandles)
        XCTAssertEqual(ranges.last?.upperBound, n)
        for i in 1..<ranges.count { XCTAssertEqual(ranges[i].lowerBound, ranges[i - 1].upperBound) }
        XCTAssertTrue(Optimizer.segmentRanges(candleCount: n - 1, count: 4).isEmpty)
        XCTAssertTrue(Optimizer.segmentRanges(candleCount: 10_000, count: 1).isEmpty)
    }

    func testWalkForwardChoosesOnlyWithPastSegments() throws {
        // A war im ersten Abschnitt am besten, verliert aber im zweiten; B holt im zweiten auf.
        let a = entry(0, [10, -5, 2])
        let b = entry(1, [-1, 20, 3])
        let summary = try XCTUnwrap(Optimizer.walkForward([a, b], objective: .netProfit, segmentStarts: [0, 1, 2], segmentEnds: [1, 2, 3]))
        XCTAssertEqual(summary.steps.count, 2)
        XCTAssertEqual(summary.steps[0].entryID, 0)                    // nur Abschnitt 0 bekannt -> A
        XCTAssertEqual(summary.steps[0].result.netPnL, -5, accuracy: 1e-9)
        XCTAssertEqual(summary.steps[1].entryID, 1)                    // Abschnitte 0+1: A 2,5 / B 9,5 -> B
        XCTAssertEqual(summary.steps[1].result.netPnL, 3, accuracy: 1e-9)
        XCTAssertEqual(summary.outOfSamplePnL, -2, accuracy: 1e-9)
        XCTAssertEqual(summary.positiveSteps, 1)
    }

    func testWalkForwardNeedsSegments() {
        XCTAssertNil(Optimizer.walkForward([entry(0, [])], objective: .netProfit, segmentStarts: [], segmentEnds: []))
        XCTAssertNil(Optimizer.walkForward([], objective: .netProfit, segmentStarts: [], segmentEnds: []))
    }

    func testRobustnessRankingAndApplyGate() {
        let steady = entry(0, [1, 2, 1, 3], test: 2)
        let lucky = entry(1, [50, -10, -10, -10], test: -5)
        let mixed = entry(2, [5, -1, 4, -1], test: 1)
        XCTAssertEqual(steady.positiveSegments, 4)
        XCTAssertEqual(steady.robustness, 1, accuracy: 1e-9)
        XCTAssertEqual(lucky.worstSegmentReturn ?? 0, -0.01, accuracy: 1e-9)
        let ranked = Optimizer.ranked([lucky, mixed, steady], by: .robustness, objective: .netProfit)
        XCTAssertEqual(ranked.map(\.id), [0, 2, 1])
        XCTAssertTrue(steady.passesTest)
        XCTAssertFalse(lucky.passesTest)
        XCTAssertFalse(entry(3, [1]).passesTest, "ohne Testabschnitt kein Übernehmen")
    }

    func testEndIndexMatchesPrefixRun() {
        let candles = Fixture.sineCandles(count: 3_000)
        let a = Backtester.run(candles: candles, settings: BotSettings(), config: BacktestConfig(), endIndex: 2_000, collect: false)
        let b = Backtester.run(candles: Array(candles[0..<2_000]), settings: BotSettings(), config: BacktestConfig(), collect: false)
        XCTAssertEqual(a.finalEquity, b.finalEquity, accuracy: 1e-9)
        XCTAssertEqual(a.buys, b.buys)
        XCTAssertEqual(a.sells, b.sells)
        XCTAssertEqual(a.lastTime, b.lastTime)
    }

    func testReportHasSegmentsAndWalkForward() async throws {
        let candles = Fixture.sineCandles(count: 3 * 24 * 60)
        let axes = [OptimizerAxis(parameter: .minNetProfitBps, values: [30, 80]),
                    OptimizerAxis(parameter: .stopLossFraction, values: [0.02, 0.05])]
        let report = await Optimizer.runReport(candles: candles, base: BotSettings(), config: BacktestConfig(), axes: axes,
                                               objective: .netProfit, trainFraction: 0.7, segments: 4, progress: { _, _ in })
        XCTAssertEqual(report.entries.count, 4)
        XCTAssertTrue(report.entries.allSatisfy { $0.segments.count == 4 && $0.test != nil })
        let wf = try XCTUnwrap(report.walkForward)
        XCTAssertEqual(wf.steps.count, 3)
        XCTAssertEqual(wf.segmentStarts.count, 4)
        for step in wf.steps {
            let chosen = try XCTUnwrap(report.entries.first { $0.id == step.entryID })
            XCTAssertEqual(step.result.netPnL, chosen.segments[step.segment].netPnL, accuracy: 1e-9)
        }
        // Die alte Schnittstelle liefert dieselben Kombinationen, sortiert nach Training.
        let plain = await Optimizer.run(candles: candles, base: BotSettings(), config: BacktestConfig(), axes: axes,
                                        objective: .netProfit, trainFraction: 0.7, progress: { _, _ in })
        XCTAssertEqual(Set(plain.map(\.id)), Set(report.entries.map(\.id)))
        let scores = plain.map { $0.train.score(.netProfit) }
        XCTAssertEqual(scores, scores.sorted(by: >))
    }
}

// MARK: - Replay aus dem Marktprotokoll

final class ReplayTests: XCTestCase {
    /// Marktmomente alle 15 s entlang der Sinus-Kerzen, mit echtem Buch (10 Stufen) und Spread `spreadBps`.
    static func frames(for candles: [PriceCandle], spreadBps: Double = 10, depthPerLevel: Double = 5_000) -> [ReplayFrame] {
        var out: [ReplayFrame] = []
        for c in candles {
            for k in 0..<4 {
                let price = c.open + (c.close - c.open) * Double(k + 1) / 4
                let half = spreadBps / 20_000
                let bids = (0..<10).map { PriceLevel(price: price * (1 - half - 0.0005 * Double($0)), quantity: depthPerLevel) }
                let asks = (0..<10).map { PriceLevel(price: price * (1 + half + 0.0005 * Double($0)), quantity: depthPerLevel) }
                out.append(ReplayFrame(t: c.openedAt + 60 + Double(k) * 15, bids: bids, asks: asks, share: 0.5))
            }
        }
        return out
    }

    func testReplayTradesOnRealBooks() {
        let candles = Fixture.sineCandles(count: 2 * 24 * 60)
        let frames = Self.frames(for: candles)
        let r = Backtester.replay(frames: frames, candles: candles, settings: BotSettings(), config: BacktestConfig())
        XCTAssertEqual(r.frameCount, frames.count)
        XCTAssertGreaterThan(r.buys, 0)
        XCTAssertGreaterThan(r.sells, 0)
        XCTAssertTrue(r.finalEquity.isFinite)
        XCTAssertFalse(r.equityCurve.isEmpty)
        XCTAssertLessThanOrEqual(r.equityCurve.count, 700)
        let again = Backtester.replay(frames: frames, candles: candles, settings: BotSettings(), config: BacktestConfig())
        XCTAssertEqual(r.finalEquity, again.finalEquity)
    }

    func testReplaySkipsBrokenBooksAndNeedsTwoFrames() {
        let candles = Fixture.sineCandles(count: 300)
        var frames = Self.frames(for: candles)
        frames.insert(ReplayFrame(t: frames[5].t + 1, bids: [PriceLevel(price: 2, quantity: 1)], asks: [PriceLevel(price: 1, quantity: 1)], share: nil), at: 6)
        let r = Backtester.replay(frames: frames, candles: candles, settings: BotSettings(), config: BacktestConfig(), collect: false)
        XCTAssertEqual(r.frameCount, frames.count - 1)
        let empty = Backtester.replay(frames: Array(frames.prefix(1)), candles: candles, settings: BotSettings(), config: BacktestConfig())
        XCTAssertEqual(empty.buys, 0)
        XCTAssertEqual(empty.finalEquity, empty.startingUSDT)
    }

    func testWideRealSpreadBlocksBuying() {
        let candles = Fixture.sineCandles(count: 24 * 60)
        let frames = Self.frames(for: candles, spreadBps: 300)
        let r = Backtester.replay(frames: frames, candles: candles, settings: BotSettings(), config: BacktestConfig(), collect: false)
        XCTAssertEqual(r.buys, 0, "Spread über dem Limit (100 bp): kein Kauf")
    }

    func testCalibrationMedians() throws {
        var frames: [ReplayFrame] = []
        for i in 0..<11 {
            let spread = Double(i + 1) * 10                 // 10 ... 110 bp
            let bid = 1 - spread / 20_000
            let ask = 1 + spread / 20_000
            frames.append(ReplayFrame(t: Double(i), bids: [PriceLevel(price: bid, quantity: 1_000)],
                                      asks: [PriceLevel(price: ask, quantity: 2_000)], share: nil))
        }
        let c = try XCTUnwrap(MarketCalibration(frames: frames))
        XCTAssertEqual(c.medianSpreadBps, 60, accuracy: 0.01)
        XCTAssertEqual(c.p90SpreadBps, 100, accuracy: 0.01)
        XCTAssertEqual(c.medianDepthUSDT, 1_000, accuracy: 5)          // kleinere Seite (Bids)
        XCTAssertEqual(c.samples, 11)
        XCTAssertNil(MarketCalibration(frames: Array(frames.prefix(5))))
    }

    func testParserSkipsBrokenLines() {
        let good = #"{"t":100,"bid":1,"ask":1.01,"bids":[[1,5],[0.99,5]],"asks":[[1.01,5]],"share":0.6,"candle":[0,1,1.1,0.9,1.05,7],"act":"Warten","why":"","cash":1,"tokens":0,"eq":1,"v":2}"#
        let noBook = #"{"t":101,"bids":[],"asks":[[1.01,5]]}"#
        let ok = JournalReader.parse(Data((good + "\n" + good.replacingOccurrences(of: "\"t\":100", with: "\"t\":105") + "\n").utf8))
        XCTAssertEqual(ok.rows.count, 2)
        XCTAssertEqual(ok.badLines, 0)
        XCTAssertEqual(ok.rows[0].0.share ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(ok.rows[0].1?.close ?? 0, 1.05, accuracy: 1e-9)
        let broken = JournalReader.parse(Data((good + "\n{kaputt\n" + noBook + "\n").utf8))
        XCTAssertEqual(broken.rows.count, 1)
        XCTAssertEqual(broken.badLines, 2)
    }

    func testJournalRoundTripAndDateFilter() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gomining-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let journal = MarketJournal(directory: dir)
        let day1 = Fixture.now - 86_400
        for (i, t) in [day1, day1 + 5, Fixture.now, Fixture.now + 5, Fixture.now + 10].enumerated() {
            journal.append(JournalEntry(t: t, bid: 1, ask: 1.001, bids: [[1, 100], [0.999, 100]], asks: [[1.001, 100]],
                                        share: 0.5, act: "Warten", why: "", cash: 1_000, tokens: 0, eq: 1_000, hold: nil,
                                        candle: [t - 70 - Double(i % 2) * 60, 1, 1, 1, 1, 10]))
        }
        journal.flushAndWait()
        let all = JournalReader.load(directory: dir, from: day1 - 10, to: Fixture.now + 100)
        XCTAssertEqual(all.frames.count, 5)
        XCTAssertEqual(all.filesRead, 2)
        XCTAssertEqual(all.frames.map(\.t), all.frames.map(\.t).sorted())
        XCTAssertFalse(all.candles.isEmpty)
        let today = JournalReader.load(directory: dir, from: Fixture.now - 1, to: Fixture.now + 100)
        XCTAssertEqual(today.frames.count, 3)
        XCTAssertEqual(today.coveredHours, 10.0 / 3_600, accuracy: 1e-9)
    }
}

// MARK: - Limit-Kauf am Bid

final class MakerOrderTests: XCTestCase {
    private let now = Fixture.now

    private func settings() -> BotSettings {
        Fixture.settings { $0.makerEntries = true; $0.makerFeeBps = 5 }
    }

    /// Platziert einen Limit-Kauf (Kursrueckgang auf 0,986).
    private func placed() throws -> (BotSettings, BotState, PendingOrder) {
        let s = settings()
        var state = BotState.fresh(s, at: now)
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .wait)
        XCTAssertTrue(r.reason.hasPrefix("Limit-Kauf am Bid platziert"), r.reason)
        return (s, state, try XCTUnwrap(state.pendingBuy))
    }

    func testTriggerPlacesLimitAtBidInsteadOfBuying() throws {
        let (_, state, order) = try placed()
        XCTAssertTrue(state.lots.isEmpty)
        XCTAssertEqual(state.cashUSDT, 1_000, accuracy: 1e-9)
        XCTAssertEqual(order.price, Fixture.snapshot(mid: 0.986).bid, accuracy: 1e-12)
        XCTAssertEqual(order.queueAhead, 10_000, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(order.quantity * order.price * 1.0005, 50 + 1e-9)
    }

    func testFillsAtLimitWithMakerFeeWhenBidDropsBelow() throws {
        let (s, start, order) = try placed()
        var state = start
        let r = BotEngine.step(Fixture.snapshot(mid: 0.984, now: now + 5), state: &state, settings: s, fastMoveBps: 0, now: now + 5)
        XCTAssertEqual(r.kind, .buy, r.reason)
        XCTAssertTrue(r.reason.hasSuffix("Limit-Kauf am Bid ausgeführt"), r.reason)
        let e = try XCTUnwrap(r.event)
        XCTAssertEqual(e.priceUSDT, order.price, accuracy: 1e-12)
        XCTAssertEqual(e.feeUSDT, order.quantity * order.price * 5 / 10_000, accuracy: 1e-12)
        XCTAssertNil(state.pendingBuy)
        XCTAssertEqual(state.lots.count, 1)
        XCTAssertEqual(state.cashUSDT, 1_000 - e.quantity * e.priceUSDT - e.feeUSDT, accuracy: 1e-9)
    }

    func testQueueAheadMustBeTradedThrough() throws {
        let (s, start, order) = try placed()
        var state = start
        func sales(_ quantity: Double, at t: Double) -> [PublicTrade] {
            [PublicTrade(id: Int64(t), at: t, price: order.price, quantity: quantity, buyerInitiated: false)]
        }
        let r1 = BotEngine.step(Fixture.snapshot(mid: 0.986, trades: sales(5_000, at: now + 3), now: now + 3),
                                state: &state, settings: s, fastMoveBps: 0, now: now + 3)
        XCTAssertEqual(r1.kind, .wait)
        XCTAssertTrue(r1.reason.hasPrefix("Limit-Kauf zu"), r1.reason)
        XCTAssertEqual(state.pendingBuy?.tradedAtPrice ?? 0, 5_000, accuracy: 1e-9)
        // Derselbe Trade zaehlt nicht zweimal.
        _ = BotEngine.step(Fixture.snapshot(mid: 0.986, trades: sales(5_000, at: now + 3), now: now + 4),
                           state: &state, settings: s, fastMoveBps: 0, now: now + 4)
        XCTAssertEqual(state.pendingBuy?.tradedAtPrice ?? 0, 5_000, accuracy: 1e-9)
        let r2 = BotEngine.step(Fixture.snapshot(mid: 0.986, trades: sales(5_000, at: now + 3) + sales(5_100, at: now + 6), now: now + 6),
                                state: &state, settings: s, fastMoveBps: 0, now: now + 6)
        XCTAssertEqual(r2.kind, .buy, r2.reason)
        XCTAssertNil(state.pendingBuy)
    }

    func testCancelledAfterTimeout() throws {
        let (s, start, _) = try placed()
        var state = start
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986, now: now + 91), state: &state, settings: s, fastMoveBps: 0, now: now + 91)
        XCTAssertTrue(r.reason.hasPrefix("Limit-Kauf gestrichen"), r.reason)
        XCTAssertNil(state.pendingBuy)
        XCTAssertTrue(state.lots.isEmpty)
    }

    func testCancelledWhenPriceRunsAway() throws {
        let (s, start, _) = try placed()
        var state = start
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986 * 1.006, now: now + 5), state: &state, settings: s, fastMoveBps: 0, now: now + 5)
        XCTAssertEqual(r.reason, "Limit-Kauf gestrichen: Kurs davongelaufen")
        XCTAssertNil(state.pendingBuy)
    }

    func testPausingDropsPendingOrder() throws {
        let (s, start, _) = try placed()
        var state = start
        state.running = false
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986, now: now + 2), state: &state, settings: s, fastMoveBps: 0, now: now + 2)
        XCTAssertEqual(r.kind, .paused)
        XCTAssertNil(state.pendingBuy)
    }

    func testPendingOrderIsSavedAndOldFilesLoad() throws {
        let (_, state, order) = try placed()
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(BotState.self, from: data)
        XCTAssertEqual(back.pendingBuy, order)
        let old = try JSONDecoder().decode(BotState.self, from: Data(#"{"cashUSDT":5,"day":"2026-10-10","dayStartEquityUSDT":5}"#.utf8))
        XCTAssertNil(old.pendingBuy)
        let settings = try JSONDecoder().decode(BotSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.makerEntries)
    }

    func testMakerBacktestBuysWithMakerFees() {
        var s = BotSettings()
        s.makerEntries = true
        s.makerFeeBps = 2
        let r = Backtester.run(candles: Fixture.sineCandles(count: 2 * 24 * 60), settings: s, config: BacktestConfig())
        XCTAssertGreaterThan(r.buys, 0)
        XCTAssertTrue(r.finalEquity.isFinite)
        let buy = r.events.first { $0.action == BotAction.buy }
        XCTAssertNotNil(buy)
        if let buy { XCTAssertEqual(buy.feeUSDT, buy.quantity * buy.priceUSDT * 2 / 10_000, accuracy: 1e-9) }
    }
}

// MARK: - Schattenkonten

final class ShadowAccountTests: XCTestCase {
    private let now = Fixture.now

    func testPresetsKeepAccountValues() {
        var current = BotSettings()
        current.feeBps = 7
        current.startingUSDT = 500
        current.minNetProfitBps = 65
        let cautious = ShadowPreset.cautious.settings(from: current)
        XCTAssertEqual(cautious.feeBps, 7)
        XCTAssertEqual(cautious.startingUSDT, 500)
        XCTAssertEqual(cautious.maxTradeUSDT, 25)
        XCTAssertEqual(ShadowPreset.current.settings(from: current).minNetProfitBps, 65)
        XCTAssertEqual(ShadowPreset.balanced.settings(from: current).minNetProfitBps, BotSettings().minNetProfitBps)
        XCTAssertTrue(ShadowPreset.maker.settings(from: current).makerEntries)
        XCTAssertFalse(ShadowPreset.noTrendFilter.settings(from: current).trendFilterEnabled)
    }

    func testShadowTradesOnLiveSnapshot() {
        var account = ShadowAccount(name: "Test", settings: Fixture.settings(), at: now, bid: 1.0)
        let e = account.step(Fixture.snapshot(mid: 0.986), fastMoveBps: 0, now: now)
        XCTAssertEqual(e?.action, BotAction.buy)
        XCTAssertEqual(account.buys, 1)
        XCTAssertEqual(account.state.lots.count, 1)
        XCTAssertLessThan(account.result(bid: 0.985), 0)
        XCTAssertEqual(account.holdReturnFraction(bid: 0.99) ?? 0, -0.01, accuracy: 1e-9)
        account.reset(at: now + 10, bid: 0.99)
        XCTAssertTrue(account.events.isEmpty)
        XCTAssertEqual(account.name, "Test")
        XCTAssertEqual(account.state.cashUSDT, account.settings.startingUSDT)
    }

    func testBookRoundTripAndLimit() throws {
        let accounts = (0..<7).map { ShadowAccount(name: "K\($0)", settings: BotSettings(), at: now, bid: 1) }
        let data = try JSONEncoder().encode(ShadowBook(accounts: accounts))
        let back = try JSONDecoder().decode(ShadowBook.self, from: data)
        XCTAssertEqual(back.accounts.count, ShadowAccount.maxAccounts)
        XCTAssertEqual(back.accounts.first, accounts.first)
        let sparse = try JSONDecoder().decode(ShadowBook.self, from: Data(#"{"accounts":[{"name":"Alt"}]}"#.utf8))
        XCTAssertEqual(sparse.accounts.first?.name, "Alt")
        XCTAssertEqual(sparse.accounts.first?.settings, BotSettings().clamped())
    }
}
