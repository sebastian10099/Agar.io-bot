import XCTest
@testable import GoMiningCore

final class MoveDetectorTests: XCTestCase {
    /// Jede Kerze eroeffnet am vorherigen Schluss; die letzte Kerze beginnt bei `endingAt`.
    static func candles(_ closes: [Double], endingAt: Double = 1_700_000_040) -> [PriceCandle] {
        var prev = closes[0]
        let first = endingAt - Double(closes.count - 1) * 60
        return closes.enumerated().map { i, c in
            defer { prev = c }
            return PriceCandle(openedAt: first + Double(i) * 60, open: prev, high: max(prev, c), low: min(prev, c), close: c, volume: 1)
        }
    }

    private func candles(_ closes: [Double]) -> [PriceCandle] { MoveDetectorTests.candles(closes) }

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

    func testSignalWithoutConfirmationFiresImmediately() throws {
        let detector = MoveDetector(requireConfirmation: false)
        let s = try XCTUnwrap(detector.signal(candles(flat + [100, 101, 102, 103, 104, 105])))
        XCTAssertEqual(s.action, .sell)
    }

    func testCustomWindowsAreUsed() {
        let detector = MoveDetector(windows: [MoveWindow(minutes: 3, thresholdPercent: 1)])
        XCTAssertEqual(detector.analyze(candles(flat + [101, 102, 103])).map(\.windowMinutes), [3])
    }
}
