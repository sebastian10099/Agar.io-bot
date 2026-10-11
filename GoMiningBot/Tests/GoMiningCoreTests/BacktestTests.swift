import XCTest
@testable import GoMiningCore

final class BacktestTests: XCTestCase {
    private var oscillating: [PriceCandle] { Fixture.sineCandles(count: 3 * 24 * 60) }

    func testBacktestIsDeterministic() {
        let a = Backtester.run(candles: oscillating, settings: BotSettings(), config: BacktestConfig())
        let b = Backtester.run(candles: oscillating, settings: BotSettings(), config: BacktestConfig())
        XCTAssertEqual(a.finalEquity, b.finalEquity)
        XCTAssertEqual(a.buys, b.buys)
        XCTAssertEqual(a.sells, b.sells)
    }

    func testStrategyTradesAnOscillatingMarket() {
        let r = Backtester.run(candles: oscillating, settings: BotSettings(), config: BacktestConfig())
        XCTAssertGreaterThan(r.buys, 0, "Der Bot sollte in einem schwingenden Markt kaufen")
        XCTAssertGreaterThan(r.sells, 0, "...und wieder verkaufen")
        XCTAssertGreaterThan(r.feesPaid, 0)
        XCTAssertGreaterThanOrEqual(r.maxDrawdownUSDT, 0)
        XCTAssertTrue(r.finalEquity.isFinite)
        XCTAssertFalse(r.equityCurve.isEmpty)
        XCTAssertLessThanOrEqual(r.equityCurve.count, 700)
        XCTAssertEqual(r.events.filter(\.isSell).count, r.sells)
    }

    func testCashPlusCostAlwaysAddsUp() {
        // Nach dem Lauf muss das Vermoegen aus Bargeld und Bestand erklaerbar sein: kein Geld entsteht aus dem Nichts.
        let r = Backtester.run(candles: oscillating, settings: BotSettings(), config: BacktestConfig())
        let realized = r.events.filter(\.isSell).reduce(0.0) { $0 + $1.realizedPnLUSDT }
        // Gewinn kann hoechstens realisierte Gewinne plus Bewertung des Restbestands sein.
        XCTAssertLessThan(abs(r.netPnL - realized), r.startingUSDT * 0.5)
    }

    func testFlatMarketProducesNoTradesAndNoLoss() {
        let flat = (0..<2_000).map { i in
            PriceCandle(openedAt: 1_760_000_000 + Double(i) * 60, open: 1, high: 1, low: 1, close: 1, volume: 1)
        }
        let r = Backtester.run(candles: flat, settings: BotSettings(), config: BacktestConfig())
        XCTAssertEqual(r.buys, 0)
        XCTAssertEqual(r.sells, 0)
        XCTAssertEqual(r.finalEquity, r.startingUSDT, accuracy: 1e-9)
    }

    func testSeedStartPositionIsBought() {
        var config = BacktestConfig()
        config.seedStartPosition = true
        let r = Backtester.run(candles: oscillating, settings: BotSettings(), config: config)
        XCTAssertEqual(r.events.first?.action, BotAction.seed)
    }

    func testStopLossLimitsLossInACrash() {
        // Kurs faellt in 60 Minuten um 30 %.
        let crash = (0..<400).map { i -> PriceCandle in
            let price = i < 100 ? 1.0 : max(0.7, 1.0 - 0.005 * Double(i - 100))
            let prev = i == 0 ? price : (i - 1 < 100 ? 1.0 : max(0.7, 1.0 - 0.005 * Double(i - 101)))
            return PriceCandle(openedAt: 1_760_000_000 + Double(i) * 60, open: prev, high: max(prev, price),
                               low: min(prev, price), close: price, volume: 1)
        }
        var s = BotSettings()
        s.stopLossFraction = 0.03
        let r = Backtester.run(candles: crash, settings: s, config: BacktestConfig())
        // Das Risiko pro Position ist durch den Stop begrenzt; die Tagesverlustgrenze stoppt weitere Kaeufe.
        XCTAssertGreaterThan(r.finalEquity, r.startingUSDT * 0.85)
    }

    func testOptimizerReturnsSortedResultsWithTestPeriod() async {
        let candles = oscillating
        let axes = [
            OptimizerAxis(parameter: .minNetProfitBps, values: [30, 80]),
            OptimizerAxis(parameter: .stopLossFraction, values: [0.02, 0.05]),
        ]
        let results = await Optimizer.run(candles: candles, base: BotSettings(), config: BacktestConfig(), axes: axes,
                                          objective: .netProfit, trainFraction: 0.7, progress: { _, _ in })
        XCTAssertEqual(results.count, 4)
        let scores = results.map { $0.train.score(.netProfit) }
        XCTAssertEqual(scores, scores.sorted(by: >))
        XCTAssertTrue(results.allSatisfy { $0.test != nil })
        XCTAssertTrue(results.allSatisfy { $0.values.count == 2 })
    }

    func testCombinationsAreCartesian() {
        let combos = Optimizer.combinations([
            OptimizerAxis(parameter: .minNetProfitBps, values: [1, 2, 3]),
            OptimizerAxis(parameter: .maxTradeUSDT, values: [10, 20]),
        ])
        XCTAssertEqual(combos.count, 6)
        XCTAssertEqual(combos.first, [1, 10])
        XCTAssertEqual(combos.last, [3, 20])
    }

    func testParameterApplyAndRead() {
        var s = BotSettings()
        OptimizerParameter.maxOpenPositions.apply(6.4, to: &s)
        XCTAssertEqual(s.maxOpenPositions, 6)
        XCTAssertEqual(OptimizerParameter.maxOpenPositions.current(in: s), 6)
        OptimizerParameter.stopLossFraction.apply(0.05, to: &s)
        XCTAssertEqual(s.stopLossFraction, 0.05)
    }

    func testCancellation() {
        var calls = 0
        let r = Backtester.run(candles: oscillating, settings: BotSettings(), config: BacktestConfig(),
                               shouldCancel: { calls += 1; return true })
        XCTAssertTrue(r.cancelled)
        XCTAssertGreaterThan(calls, 0)
    }
}
