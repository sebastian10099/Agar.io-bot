import XCTest
@testable import GoMiningCore

final class ModelTests: XCTestCase {
    /// So aehnlich sieht eine `simulation.json` der Vorgaengerversion aus (kein `lots`, keine neuen Felder).
    private let legacyJSON = """
    {
      "state": {
        "cashUSDT": 400.5, "tokens": 1200, "costBasisUSDT": 600, "realizedPnLUSDT": 12.5,
        "totalFeesUSDT": 3.2, "anchorUSDT": 0.5, "lastTradeAt": 1760000000,
        "day": "2026-10-10", "dayStartEquityUSDT": 1000, "running": true
      },
      "settings": {
        "startingUSDT": 1000, "feeBps": 10, "slippageBps": 0, "gridDropBps": 160, "minNetProfitBps": 50,
        "maxTradeUSDT": 50, "maxPositionFraction": 0.5, "maxDailyLossFraction": 0.02,
        "minSecondsBetweenTrades": 20, "stopLossFraction": 0.03, "maxSpreadBps": 100,
        "maxBookParticipation": 0.3, "maxBookAgeSeconds": 15, "maxCandleAgeSeconds": 120,
        "lookbackBars": 20, "maxOpenPositions": 8
      },
      "events": [
        {"id": "11111111-1111-1111-1111-111111111111", "at": 1759990000, "action": "Startkauf", "reason": "x",
         "bidUSDT": 0.5, "askUSDT": 0.51, "quantity": 1900, "priceUSDT": 0.51, "feeUSDT": 0.9, "realizedPnLUSDT": 0, "equityUSDT": 999},
        {"id": "22222222-2222-2222-2222-222222222222", "at": 1759990100, "action": "Warten", "reason": "Spread",
         "bidUSDT": 0.5, "askUSDT": 0.51, "quantity": 0, "priceUSDT": 0, "feeUSDT": 0, "realizedPnLUSDT": 0, "equityUSDT": 999},
        {"id": "33333333-3333-3333-3333-333333333333", "at": 1759990200, "action": "Verkauf", "reason": "Ziel",
         "bidUSDT": 0.52, "askUSDT": 0.53, "quantity": 100, "priceUSDT": 0.52, "feeUSDT": 0.05, "realizedPnLUSDT": 1.2, "equityUSDT": 1001}
      ],
      "initialSeeded": true
    }
    """

    func testLegacyFileLoadsAndMigrates() throws {
        let stored = try JSONDecoder().decode(StoredBot.self, from: Data(legacyJSON.utf8))
        // Bestand ohne Lose wird als ein Los gefuehrt.
        XCTAssertEqual(stored.state.lots.count, 1)
        XCTAssertEqual(stored.state.lots[0].quantity, 1200, accuracy: 1e-9)
        XCTAssertEqual(stored.state.lots[0].costBasisUSDT, 600, accuracy: 1e-9)
        XCTAssertEqual(stored.state.lots[0].buyPriceUSDT, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stored.state.dayIndex, BotEngine.dayIndex(fromDay: "2026-10-10"))
        // Alter Standard (8) wird zu 10, Warte-Eintraege fallen weg, Trades bleiben.
        XCTAssertEqual(stored.settings.maxOpenPositions, 10)
        XCTAssertEqual(stored.events.map(\.action), ["Startkauf", "Verkauf"])
        // Neue Einstellungen haben Standardwerte.
        XCTAssertEqual(stored.settings.trailingStopBps, 0)
        XCTAssertTrue(stored.settings.useMoveDetector)
        XCTAssertEqual(stored.settings.moveWindows.map(\.minutes), [6, 8, 20, 60])
    }

    func testCustomPositionLimitIsKept() throws {
        let custom = legacyJSON.replacingOccurrences(of: "\"maxOpenPositions\": 8", with: "\"maxOpenPositions\": 6")
        let stored = try JSONDecoder().decode(StoredBot.self, from: Data(custom.utf8))
        XCTAssertEqual(stored.settings.maxOpenPositions, 6)
        XCTAssertEqual(StoredBot.migratedPositionLimit(4), 10)
        XCTAssertEqual(StoredBot.migratedPositionLimit(nil), 10)
        XCTAssertEqual(StoredBot.migratedPositionLimit(2), 2)
    }

    func testRoundTripKeepsEverything() throws {
        var stored = StoredBot.fresh(at: Fixture.now, seedStartPosition: true)
        stored.state.lots = [PositionLot(quantity: 10, costBasisUSDT: 11, buyPriceUSDT: 1.1, boughtAt: Fixture.now, peakPriceUSDT: 1.3)]
        stored.state.tokens = 10
        stored.state.costBasisUSDT = 11
        stored.record(BotEvent(at: Fixture.now, action: BotAction.buy, reason: "t", bidUSDT: 1, askUSDT: 1.01, equityUSDT: 1000))
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredBot.self, from: data)
        XCTAssertEqual(decoded, stored)
        XCTAssertEqual(decoded.version, StoredBot.currentVersion)
    }

    func testOnlyTradesAreRecorded() {
        var stored = StoredBot.fresh(at: Fixture.now, seedStartPosition: false)
        stored.record(BotEvent(at: 1, action: BotAction.wait, reason: "x", bidUSDT: 1, askUSDT: 1, equityUSDT: 1))
        stored.record(BotEvent(at: 2, action: BotAction.buy, reason: "x", bidUSDT: 1, askUSDT: 1, equityUSDT: 1))
        XCTAssertEqual(stored.events.count, 1)
    }

    func testEventLimitKeepsSeedEvent() {
        var stored = StoredBot.fresh(at: Fixture.now, seedStartPosition: false)
        stored.record(BotEvent(at: 0, action: BotAction.seed, reason: "s", bidUSDT: 1, askUSDT: 1, quantity: 5, equityUSDT: 1), limit: 3)
        for i in 1...5 {
            stored.record(BotEvent(at: Double(i), action: BotAction.buy, reason: "b", bidUSDT: 1, askUSDT: 1, equityUSDT: 1), limit: 3)
        }
        XCTAssertEqual(stored.events.count, 3)
        XCTAssertEqual(stored.events.first?.action, BotAction.seed)
        XCTAssertEqual(stored.events.last?.at, 5)
    }

    func testOldCandleWithoutOHLCDecodes() throws {
        let json = #"{"openedAt": 100, "close": 5.5, "volume": 3}"#
        let c = try JSONDecoder().decode(PriceCandle.self, from: Data(json.utf8))
        XCTAssertEqual([c.open, c.high, c.low, c.close], [5.5, 5.5, 5.5, 5.5])
        XCTAssertTrue(c.isCloseOnly)
    }

    func testCandleKeepsHighAndLowConsistent() {
        let c = PriceCandle(openedAt: 0, open: 10, high: 9, low: 11, close: 10.5, volume: 1)
        XCTAssertGreaterThanOrEqual(c.high, max(c.open, c.close))
        XCTAssertLessThanOrEqual(c.low, min(c.open, c.close))
    }

    func testSettingsAreClamped() {
        var s = BotSettings()
        s.stopLossFraction = 5
        s.feeBps = -3
        s.maxOpenPositions = 500
        s.maxBookParticipation = .nan
        let c = s.clamped()
        XCTAssertEqual(c.stopLossFraction, 0.9)
        XCTAssertEqual(c.feeBps, 0)
        XCTAssertEqual(c.maxOpenPositions, 50)
        XCTAssertTrue(c.maxBookParticipation.isFinite)
    }

    func testHoldBenchmarkIncludesLeftoverCash() {
        var stored = StoredBot.fresh(at: Fixture.now, seedStartPosition: true)
        stored.events = [BotEvent(at: 0, action: BotAction.seed, reason: "s", bidUSDT: 0.99, askUSDT: 1.0,
                                  quantity: 990, priceUSDT: 1.0, feeUSDT: 0.99, equityUSDT: 1000)]
        // 990 Tokens zu 1.0 = 990 + 0.99 Gebuehr -> 9.01 Restbargeld.
        XCTAssertEqual(stored.holdBenchmarkUSDT(bid: 1.0) ?? 0, 990 + 9.01, accuracy: 1e-6)
    }

    func testCivilDayRoundTrip() {
        for day in ["1970-01-01", "2000-02-29", "2026-10-14", "2099-12-31"] {
            let idx = BotEngine.dayIndex(fromDay: day)
            XCTAssertNotNil(idx)
            XCTAssertEqual(BotEngine.civilDay(idx!), day)
        }
        XCTAssertEqual(BotEngine.dayIndex(fromDay: "1970-01-01"), 0)
        XCTAssertNil(BotEngine.dayIndex(fromDay: "kaputt"))
    }

    func testSettlementWindowIsTuesdayUntil18UTC() {
        let tuesday = Double(BotEngine.dayIndex(fromDay: "2026-10-13")!) * 86_400
        XCTAssertTrue(BotEngine.inSettlementWindow(tuesday + 3_600))
        XCTAssertTrue(BotEngine.inSettlementWindow(tuesday + 17 * 3_600 + 3_599))
        XCTAssertFalse(BotEngine.inSettlementWindow(tuesday + 18 * 3_600))
        XCTAssertFalse(BotEngine.inSettlementWindow(tuesday - 3_600))
        XCTAssertFalse(BotEngine.inSettlementWindow(Fixture.now)) // Mittwoch
    }
}
