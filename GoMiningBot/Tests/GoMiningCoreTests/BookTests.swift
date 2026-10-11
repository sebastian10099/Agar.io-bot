import XCTest
@testable import GoMiningCore

final class BookTests: XCTestCase {
    func testFloorToStepToleratesFloatingPointNoise() {
        XCTAssertEqual(Book.floorToStep(0.3, step: 0.1), 0.3, accuracy: 1e-12)
        XCTAssertEqual(Book.floorToStep(1.239, step: 0.01), 1.23, accuracy: 1e-12)
        XCTAssertEqual(Book.floorToStep(-1, step: 0.01), 0)
        XCTAssertEqual(Book.floorToStep(5, step: 0), 5)
    }

    func testFillComputesVolumeWeightedPrice() throws {
        let levels = [PriceLevel(price: 1.00, quantity: 10), PriceLevel(price: 1.10, quantity: 10)]
        let vwap = try XCTUnwrap(Book.fill(levels, quantity: 15, participation: 1))
        XCTAssertEqual(vwap, (10 * 1.0 + 5 * 1.1) / 15, accuracy: 1e-12)
    }

    func testFillRespectsParticipationLimit() {
        let levels = [PriceLevel(price: 1.00, quantity: 10), PriceLevel(price: 1.10, quantity: 10)]
        XCTAssertNil(Book.fill(levels, quantity: 15, participation: 0.5))   // erlaubt waeren 10
        XCTAssertNotNil(Book.fill(levels, quantity: 10, participation: 0.5))
    }

    func testBuyQuoteStaysWithinBudgetIncludingFee() throws {
        let snap = Fixture.snapshot(mid: 1.0)
        let s = Fixture.settings()
        let q = try Book.buyQuote(snap, budgetUSDT: 50, settings: s).get()
        XCTAssertLessThanOrEqual(q.totalUSDT, 50 + 1e-9)
        XCTAssertEqual(q.totalUSDT, q.quantity * q.priceUSDT * (1 + s.feeBps / 10_000), accuracy: 1e-9)
        XCTAssertEqual(q.unspentUSDT, 50 - q.totalUSDT, accuracy: 1e-9)
        // Menge liegt auf dem Raster.
        XCTAssertEqual((q.quantity / 0.01).rounded(), q.quantity / 0.01, accuracy: 1e-6)
    }

    func testBuyQuoteBelowMinimumNotional() {
        let snap = Fixture.snapshot(mid: 1.0)
        if case .success = Book.buyQuote(snap, budgetUSDT: 1, settings: Fixture.settings()) {
            XCTFail("1 USDT liegt unter dem Mindestbetrag von 2 USDT")
        }
    }

    func testBuyQuoteShrinksToBookDepth() throws {
        var snap = Fixture.snapshot(mid: 1.0)
        snap.asks = [PriceLevel(price: 1.001, quantity: 40), PriceLevel(price: 1.01, quantity: 40)]
        var s = Fixture.settings()
        s.maxBookParticipation = 0.5       // erlaubt: 40 Tokens
        let q = try Book.buyQuote(snap, budgetUSDT: 100, settings: s).get()
        XCTAssertLessThanOrEqual(q.quantity, 40 + 1e-9)
    }

    func testSellQuoteAppliesFeeAndSlippage() throws {
        let snap = Fixture.snapshot(mid: 1.0)
        var s = Fixture.settings()
        s.slippageBps = 5
        let q = try XCTUnwrap(Book.sellQuote(snap, quantity: 20, settings: s, allowPartial: false))
        XCTAssertEqual(q.netUSDT, q.grossUSDT - q.feeUSDT, accuracy: 1e-12)
        XCTAssertLessThan(q.priceUSDT, snap.bid)
    }

    func testSellQuotePartialOnlyWhenAllowed() throws {
        var snap = Fixture.snapshot(mid: 1.0)
        snap.bids = [PriceLevel(price: 0.999, quantity: 100)]
        var s = Fixture.settings()
        s.maxBookParticipation = 0.3        // erlaubt: 30
        XCTAssertNil(Book.sellQuote(snap, quantity: 50, settings: s, allowPartial: false))
        let q = try XCTUnwrap(Book.sellQuote(snap, quantity: 50, settings: s, allowPartial: true))
        XCTAssertEqual(q.quantity, 30, accuracy: 1e-9)
    }

    func testCandleHelpers() {
        let c = Fixture.candles(count: 10)
        XCTAssertTrue((2...3).contains(Indicators.aggregate(c, minutes: 5).count))
        let gap = [
            PriceCandle(openedAt: 600, open: 1, high: 1.1, low: 0.9, close: 1.05, volume: 1),
            PriceCandle(openedAt: 840, open: 1.05, high: 1.1, low: 1.0, close: 1.02, volume: 1),
        ]
        let filled = Indicators.fillGaps(gap)
        XCTAssertEqual(filled.map(\.openedAt), [600, 660, 720, 780, 840])
        XCTAssertEqual(filled[1].close, 1.05)
        XCTAssertEqual(filled[1].volume, 0)
        XCTAssertEqual(Indicators.normalize(gap + gap).count, 2)
    }

    func testAggregateBucketsAlignToWallClock() {
        let base = 1_700_000_000.0 - (1_700_000_000.0.truncatingRemainder(dividingBy: 300))   // Vielfaches von 5 min
        let candles = (0..<10).map { i in
            PriceCandle(openedAt: base + Double(i) * 60, open: Double(i), high: Double(i) + 1, low: Double(i) - 1,
                        close: Double(i) + 0.5, volume: 2)
        }
        let agg = Indicators.aggregate(candles, minutes: 5)
        XCTAssertEqual(agg.count, 2)
        XCTAssertEqual(agg[0].open, 0)
        XCTAssertEqual(agg[0].close, 4.5)
        XCTAssertEqual(agg[0].high, 5)
        XCTAssertEqual(agg[0].low, -1)
        XCTAssertEqual(agg[0].volume, 10)
    }

    func testMarketPressureCountsValueOfBuyerTrades() throws {
        let trades = Fixture.trades(price: 1.0, buyers: 7)
        let p = try XCTUnwrap(Indicators.marketPressure(trades, now: Fixture.now))
        XCTAssertEqual(p, 0.7, accuracy: 1e-9)
        XCTAssertNil(Indicators.marketPressure(Array(trades.prefix(2)), now: Fixture.now))
    }

    func testFastMoveDetector() {
        var d = FastMoveDetector()
        let t = Fixture.now
        d.add(price: 1.000, at: t - 2.5)
        d.add(price: 0.995, at: t - 1)
        d.add(price: 0.990, at: t)
        XCTAssertEqual(d.value(now: t), -100, accuracy: 1e-6)
        // Spaeter ist alles ausserhalb des 3-Sekunden-Fensters.
        XCTAssertEqual(d.value(now: t + 10), 0)
    }

    func testVolatilityIsMedianOfAbsoluteChanges() {
        let closes = [100.0, 101, 100, 101, 100, 101]
        let candles = closes.enumerated().map { PriceCandle(openedAt: Double($0.offset) * 60, close: $0.element, volume: 1) }
        let v = Indicators.volatilityBps(candles)
        XCTAssertEqual(v, 99.0, accuracy: 2)      // ca. 1 % je Minute
        XCTAssertEqual(Indicators.volatilityBps(Array(candles.prefix(2))), 0)
    }
}
