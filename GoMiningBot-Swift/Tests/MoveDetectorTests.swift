import XCTest
@testable import GoMiningBot

final class MoveDetectorTests: XCTestCase {
    private let t0 = 1_700_000_040.0

    /// Jede Kerze eroeffnet am vorherigen Schluss.
    private func candles(_ closes: [Double]) -> [PriceCandle] {
        var prev = closes[0]
        return closes.enumerated().map { i, c in
            defer { prev = c }
            return PriceCandle(openedAt: t0 + Double(i) * 60, open: prev, high: max(prev, c), low: min(prev, c), close: c, volume: 1)
        }
    }

    private var flat: [Double] { Array(repeating: 100, count: 30) }

    func testRiseInSixMinutesIsDetected() throws {
        let c = candles(flat + [100, 100.5, 101, 101.5, 102, 102.5])
        let m = try XCTUnwrap(MoveDetector.measure(c, windowCandles: 6, window: MoveWindow(minutes: 6, thresholdPercent: 1.5)))
        XCTAssertEqual(m.direction, .up)
        XCTAssertEqual(m.movePercent, 2.5, accuracy: 1e-9)
        XCTAssertTrue(m.triggered)
    }

    func testFallIsDetected() throws {
        let c = candles(Array(repeating: 100, count: 10) + [99, 98, 97, 96])
        let m = try XCTUnwrap(MoveDetector.measure(c, windowCandles: 6, window: MoveWindow(minutes: 6, thresholdPercent: 1.5)))
        XCTAssertEqual(m.direction, .down)
        XCTAssertEqual(m.movePercent, 4.0, accuracy: 1e-9)
    }

    func testAllFourWindowsAreMeasured() {
        let closes = (0..<90).map { 100 + 0.1 * Double($0) }
        XCTAssertEqual(MoveDetector().analyze(candles(closes)).map(\.windowMinutes), [6, 8, 20, 60])
    }

    func testPumpThenRedCandleSells() throws {
        let s = try XCTUnwrap(MoveDetector().signal(candles(flat + [100, 101, 102, 103, 104, 103.6])))
        XCTAssertEqual(s.action, .sell)
        XCTAssertEqual(s.move.windowMinutes, 6)
        XCTAssertEqual(s.move.movePercent, 4.0, accuracy: 1e-9)
    }

    func testNoSellIntoRunningPump() {
        XCTAssertNil(MoveDetector().signal(candles(flat + [100, 101, 102, 103, 104, 105])))
    }

    func testDumpThenGreenCandleBuys() throws {
        let s = try XCTUnwrap(MoveDetector().signal(candles(flat + [100, 99, 98, 97, 96, 96.4])))
        XCTAssertEqual(s.action, .buy)
    }

    func testLateEntryIsRejected() {
        XCTAssertNil(MoveDetector().signal(candles(flat + [100, 101, 102, 103, 104, 101])))
    }

    func testQuietMarketGivesNoSignal() {
        XCTAssertNil(MoveDetector().signal(candles(Array(repeating: 100, count: 90))))
    }

    // MARK: - Kerze

    func testBingXRowIsParsed() throws {
        let row: [Any] = [1_700_000_040_000, "10.0", "12.0", "9.0", "11.0", "5", 1_700_000_099_999, "55"]
        let c = try XCTUnwrap(PriceCandle(bingXRow: row))
        XCTAssertEqual(c.openedAt, 1_700_000_040, accuracy: 1e-6)
        XCTAssertEqual([c.open, c.high, c.low, c.close], [10, 12, 9, 11])
        XCTAssertTrue(c.isGreen)
    }

    func testBadBingXRowIsRejected() {
        XCTAssertNil(PriceCandle(bingXRow: [1, "x", "1", "1", "1", "1"]))
        XCTAssertNil(PriceCandle(bingXRow: [1, "0", "1", "1", "1", "1"]))
    }

    func testOldStoredCandleStillDecodes() throws {
        let json = #"{"openedAt": 100, "close": 5.5, "volume": 3}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(PriceCandle.self, from: json)
        XCTAssertEqual([c.open, c.high, c.low, c.close], [5.5, 5.5, 5.5, 5.5])
        XCTAssertTrue(c.isCloseOnly)
    }

    // MARK: - Positionslimit

    func testTenPositionsAllowedEleventhNot() {
        XCTAssertTrue(PositionLimit.canOpenAnother(openCount: 9, limit: 10))
        XCTAssertFalse(PositionLimit.canOpenAnother(openCount: 10, limit: 10))
    }

    func testOldDefaultFourIsMigratedButCustomValuesStay() {
        XCTAssertEqual(PositionLimit.migrated(4), 10)
        XCTAssertEqual(PositionLimit.migrated(nil), 10)
        XCTAssertEqual(PositionLimit.migrated(2), 2)
        XCTAssertEqual(PositionLimit.migrated(7), 7)
    }
}
