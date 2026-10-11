import XCTest
@testable import GoMiningCore

final class HelperTests: XCTestCase {
    func testHMACMatchesKnownVector() {
        // Standard-Testvektor: HMAC_SHA256("key", "The quick brown fox jumps over the lazy dog")
        XCTAssertEqual(BingXSigner.signature(query: "The quick brown fox jumps over the lazy dog", secret: "key"),
                       "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    }

    func testCanonicalQueryIsSorted() {
        XCTAssertEqual(BingXSigner.canonicalQuery(["timestamp": "5", "recvWindow": "5000", "symbol": "A-B"]),
                       "recvWindow=5000&symbol=A-B&timestamp=5")
    }

    func testExtendFlatFillsUpToLastClosedMinute() {
        let base = 1_760_000_040.0
        let candles = [PriceCandle(openedAt: base, open: 1, high: 1.1, low: 0.9, close: 1.05, volume: 3)]
        let extended = Indicators.extendFlat(candles, upTo: base + 180)
        XCTAssertEqual(extended.map(\.openedAt), [base, base + 60, base + 120, base + 180])
        XCTAssertEqual(extended.last?.close, 1.05)
        XCTAssertEqual(extended.last?.volume, 0)
        // Nichts zu tun, wenn die Serie schon aktuell ist.
        XCTAssertEqual(Indicators.extendFlat(candles, upTo: base).count, 1)
    }

    func testMergeTailReplacesAndAppends() {
        let base = 1_760_000_040.0
        var series = (0..<5).map { PriceCandle(openedAt: base + Double($0) * 60, close: Double($0 + 1), volume: 1) }
        let update = [
            PriceCandle(openedAt: base + 4 * 60, close: 99, volume: 2),     // ersetzt die letzte
            PriceCandle(openedAt: base + 5 * 60, close: 6, volume: 1),      // neu
        ]
        Indicators.mergeTail(&series, update)
        XCTAssertEqual(series.count, 6)
        XCTAssertEqual(series[4].close, 99)
        XCTAssertEqual(series[5].close, 6)
        XCTAssertEqual(series.map(\.openedAt), series.map(\.openedAt).sorted())
    }

    func testMergeTailInsertsMissingOlderCandle() {
        let base = 1_760_000_040.0
        var series = [PriceCandle(openedAt: base, close: 1, volume: 1), PriceCandle(openedAt: base + 120, close: 3, volume: 1)]
        Indicators.mergeTail(&series, [PriceCandle(openedAt: base + 60, close: 2, volume: 1)])
        XCTAssertEqual(series.map(\.close), [1, 2, 3])
    }

    func testHistoryCandlesWithGapsGiveNoStaleCandleBlock() {
        // Illiquider Markt: letzte Kerze ist 10 Minuten alt, wird aber flach bis zur letzten Minute verlaengert.
        let now = Fixture.now
        let lastClosedOpen = (now / 60).rounded(.down) * 60 - 60
        let old = Fixture.candles(price: 1.0, count: 40, now: now - 600)
        let extended = Indicators.extendFlat(old, upTo: lastClosedOpen)
        let s = Fixture.settings()
        var state = BotState.fresh(s, at: now)
        let snap = Fixture.snapshot(mid: 0.986, candles: extended, now: now)
        let r = BotEngine.step(snap, state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertNotEqual(r.reason, "Kurskerzen veraltet")
    }
}
