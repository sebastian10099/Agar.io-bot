import XCTest
@testable import GoMiningCore

final class EngineTests: XCTestCase {
    private let now = Fixture.now

    private func fresh(_ s: BotSettings) -> BotState { BotState.fresh(s, at: now) }

    /// Fuegt ein Los hinzu und haelt Summen/Bargeld konsistent.
    private func addLot(_ state: inout BotState, quantity: Double, buyPrice: Double, boughtAt: Double? = nil, peak: Double? = nil) {
        let cost = quantity * buyPrice * 1.001
        state.lots.append(PositionLot(quantity: quantity, costBasisUSDT: cost, buyPriceUSDT: buyPrice,
                                      boughtAt: boughtAt ?? now - 600, peakPriceUSDT: peak))
        state.cashUSDT -= cost
        BotEngine.normalize(&state)
    }

    // MARK: Einstieg

    func testBuysOnAdaptiveDrop() throws {
        let s = Fixture.settings()
        var state = fresh(s)
        let snap = Fixture.snapshot(mid: 0.986)
        let r = BotEngine.step(snap, state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .buy, r.reason)
        XCTAssertEqual(r.event?.action, BotAction.buy)
        XCTAssertEqual(r.reason, "Adaptiver Rückgang erkannt")
        XCTAssertEqual(state.lots.count, 1)
        XCTAssertGreaterThan(state.tokens, 50)
        XCTAssertEqual(state.costBasisUSDT, s.startingUSDT - state.cashUSDT, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(state.costBasisUSDT, s.maxTradeUSDT + 1e-9)
        XCTAssertEqual(state.lastTradeAt, now)
        XCTAssertGreaterThan(state.totalFeesUSDT, 0)
    }

    func testWatchesInQuietMarket() {
        let s = Fixture.settings()
        var state = fresh(s)
        let r = BotEngine.step(Fixture.snapshot(mid: 1.0), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .watch)
        XCTAssertTrue(r.reason.contains("Schwelle"))
        XCTAssertTrue(state.lots.isEmpty)
    }

    func testPausedDoesNothing() {
        let s = Fixture.settings()
        var state = fresh(s)
        state.running = false
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .paused)
        XCTAssertTrue(state.lots.isEmpty)
    }

    func testStaleBookBlocksTrading() {
        let s = Fixture.settings()
        var state = fresh(s)
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986, bookAge: 60), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .wait)
        XCTAssertEqual(r.reason, "Orderbuch veraltet")
    }

    func testCrossedBookIsInvalid() {
        let s = Fixture.settings()
        var state = fresh(s)
        var snap = Fixture.snapshot(mid: 1.0)
        snap.bids = [PriceLevel(price: 1.1, quantity: 10)]
        snap.asks = [PriceLevel(price: 1.0, quantity: 10)]
        let r = BotEngine.step(snap, state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.reason, "Ungültiges Orderbuch")
    }

    func testWideSpreadBlocksBuy() {
        let s = Fixture.settings()
        var state = fresh(s)
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986, spreadBps: 150), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .wait)
        XCTAssertTrue(r.reason.hasPrefix("Spread zu groß"), r.reason)
    }

    func testStaleCandlesBlockBuy() {
        let s = Fixture.settings()
        var state = fresh(s)
        let old = Fixture.candles(now: now - 600)
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986, candles: old), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.reason, "Kurskerzen veraltet")
    }

    func testDailyLossLimitBlocksNewBuys() {
        let s = Fixture.settings()
        var state = fresh(s)
        state.cashUSDT = 950
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.reason, "Tagesverlustgrenze erreicht")
    }

    func testPositionLimitBlocksBuy() {
        var s = Fixture.settings()
        s.maxOpenPositions = 2
        var state = fresh(s)
        addLot(&state, quantity: 50, buyPrice: 1.0)
        addLot(&state, quantity: 50, buyPrice: 1.0)
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .wait)
        XCTAssertEqual(r.reason, "Alle 2 Positionen belegt")
    }

    func testTenPositionsAreTheDefault() {
        XCTAssertEqual(BotSettings().openPositionLimit, 10)
    }

    func testHoldingsFractionBlocksBuy() {
        let s = Fixture.settings()
        var state = fresh(s)
        addLot(&state, quantity: 600, buyPrice: 1.0)
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.reason, "Kauf: Bestandsgrenze für Neukäufe erreicht")
    }

    func testMinimumDistanceToLowestLot() {
        let s = Fixture.settings()
        var state = fresh(s)
        // Ein Los knapp ueber dem aktuellen Kurs: ein weiterer Kauf waere zu nah
        // (Mindestabstand 0,5 x Kaufabstand = 25 bp unter dem tiefsten Kauf).
        addLot(&state, quantity: 50, buyPrice: 0.9875)
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .watch, r.reason)
        XCTAssertEqual(state.lots.count, 1)
    }

    func testMinSecondsBetweenTrades() {
        var s = Fixture.settings()
        s.minSecondsBetweenTrades = 60
        var state = fresh(s)
        state.lastTradeAt = now - 10
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.reason, "Mindestabstand zwischen Trades")
    }

    func testWeakBuyerPressureBlocksDropBuy() {
        let s = Fixture.settings()
        var state = fresh(s)
        let trades = Fixture.trades(price: 0.986, buyers: 2)   // 20 % Kaeuferanteil
        let r = BotEngine.step(Fixture.snapshot(mid: 0.986, trades: trades), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .watch)
    }

    // MARK: Ausstieg

    func testSellsAtNetTarget() throws {
        let s = Fixture.settings()
        var state = fresh(s)
        addLot(&state, quantity: 50, buyPrice: 1.0)
        let r = BotEngine.step(Fixture.snapshot(mid: 1.02), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .sell, r.reason)
        let e = try XCTUnwrap(r.event)
        XCTAssertGreaterThan(e.realizedPnLUSDT, 0)
        XCTAssertEqual(e.heldSeconds ?? 0, 600, accuracy: 1)
        XCTAssertGreaterThan(e.netBps ?? 0, 50)
        XCTAssertTrue(state.lots.isEmpty)
        XCTAssertEqual(state.tokens, 0, accuracy: 1e-9)
        XCTAssertEqual(state.realizedPnLUSDT, e.realizedPnLUSDT, accuracy: 1e-9)
    }

    func testDoesNotSellBelowNetTarget() {
        let s = Fixture.settings()
        var state = fresh(s)
        addLot(&state, quantity: 50, buyPrice: 1.0)
        // +30 bp brutto bleiben nach Gebuehren und Spread unter dem Ziel.
        let r = BotEngine.step(Fixture.snapshot(mid: 1.004), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertNotEqual(r.kind, .sell)
        XCTAssertEqual(state.lots.count, 1)
    }

    func testStopLossSellsAndStartsCooldown() throws {
        let s = Fixture.settings()
        var state = fresh(s)
        addLot(&state, quantity: 50, buyPrice: 1.0)
        let r = BotEngine.step(Fixture.snapshot(mid: 0.95), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .sell)
        XCTAssertTrue(r.reason.hasPrefix("Stop-Loss"), r.reason)
        XCTAssertLessThan(try XCTUnwrap(r.event).realizedPnLUSDT, 0)
        XCTAssertEqual(state.cooldownUntil, now + s.cooldownAfterStopSeconds, accuracy: 1e-6)

        // Waehrend der Abkuehlphase wird trotz Rueckgang nicht nachgekauft.
        let later = now + 10
        let r2 = BotEngine.step(Fixture.snapshot(mid: 0.90, now: later), state: &state, settings: s, fastMoveBps: 0, now: later)
        XCTAssertEqual(r2.reason, "Abkühlphase nach Stop-Loss")
    }

    func testLargeLotIsSoldInTranches() throws {
        let s = Fixture.settings()
        var state = fresh(s)
        addLot(&state, quantity: 500, buyPrice: 1.0)
        let r = BotEngine.step(Fixture.snapshot(mid: 1.02), state: &state, settings: s, fastMoveBps: 0, now: now)
        let e = try XCTUnwrap(r.event)
        XCTAssertEqual(e.quantity, 49.07, accuracy: 0.05)          // ca. 50 USDT je Verkauf
        XCTAssertEqual(state.lots.count, 1)
        XCTAssertEqual(state.lots[0].quantity, 500 - e.quantity, accuracy: 1e-9)
        XCTAssertEqual(state.tokens, state.lots[0].quantity, accuracy: 1e-9)
    }

    func testTrailingStopSellsAfterPullback() throws {
        var s = Fixture.settings()
        s.trailingStopBps = 60
        s.trailingActivationBps = 100
        s.minNetProfitBps = 500          // das normale Ziel soll hier nicht ausloesen
        var state = fresh(s)
        addLot(&state, quantity: 50, buyPrice: 1.0, peak: 1.03)
        let r = BotEngine.step(Fixture.snapshot(mid: 1.02), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .sell, r.reason)
        XCTAssertTrue(r.reason.hasPrefix("Trailing-Stop"), r.reason)
        XCTAssertGreaterThan(try XCTUnwrap(r.event).realizedPnLUSDT, 0)
    }

    func testMaxHoldLowersTargetToBreakEven() {
        var s = Fixture.settings()
        s.maxHoldMinutes = 10
        s.minNetProfitBps = 500
        var state = fresh(s)
        addLot(&state, quantity: 50, buyPrice: 1.0, boughtAt: now - 700)
        let r = BotEngine.step(Fixture.snapshot(mid: 1.012), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .sell, r.reason)
        XCTAssertTrue(r.reason.hasPrefix("Zeit-Ausstieg"), r.reason)
    }

    func testStopLossBlockedWhenBookTooThin() {
        let s = Fixture.settings()
        var state = fresh(s)
        addLot(&state, quantity: 50, buyPrice: 1.0)
        var snap = Fixture.snapshot(mid: 0.95)
        snap.bids = [PriceLevel(price: 0.949, quantity: 0.5)]       // viel zu duenn
        let r = BotEngine.step(snap, state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .wait)
        XCTAssertTrue(r.reason.hasPrefix("Stop-Loss ausgelöst"))
        XCTAssertEqual(state.lots.count, 1)
    }

    // MARK: Hilfen

    func testDustLotsAreMergedWithoutLosingCost() {
        let s = Fixture.settings()
        var state = fresh(s)
        for _ in 0..<3 { addLot(&state, quantity: 1, buyPrice: 1.0) }
        let before = state.costBasisUSDT
        _ = BotEngine.step(Fixture.snapshot(mid: 1.0), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(state.lots.count, 1)
        XCTAssertEqual(state.lots[0].quantity, 3, accuracy: 1e-9)
        XCTAssertEqual(state.costBasisUSDT, before, accuracy: 1e-9)
    }

    func testSeedPosition() throws {
        let s = Fixture.settings()
        var state = fresh(s)
        let e = try XCTUnwrap(BotEngine.seedReferencePosition(Fixture.snapshot(mid: 1.0), state: &state, settings: s,
                                                              budgetUSDT: 1000, now: now))
        XCTAssertEqual(e.action, BotAction.seed)
        XCTAssertTrue(state.lots[0].isSeed)
        XCTAssertLessThan(state.cashUSDT, 2)
        XCTAssertEqual(state.cashUSDT + state.costBasisUSDT, 1000, accuracy: 1e-9)
    }

    func testMinerWarsWindowRaisesBuyThreshold() {
        let s = Fixture.settings()
        let wednesday = now
        let tuesday = Double(BotEngine.dayIndex(fromDay: "2026-10-13")!) * 86_400 + 6 * 3_600
        let state = fresh(s)
        let a = BotEngine.metrics(Fixture.snapshot(mid: 1.0, now: wednesday), state: state, settings: s, now: wednesday)
        let b = BotEngine.metrics(Fixture.snapshot(mid: 1.0, now: tuesday), state: state, settings: s, now: tuesday)
        XCTAssertFalse(a.minerWars)
        XCTAssertTrue(b.minerWars)
        XCTAssertEqual(b.stepBps, a.stepBps * 1.25, accuracy: 1e-6)
    }

    func testDayRolloverResetsDailyBaseline() {
        let s = Fixture.settings()
        var state = fresh(s)
        state.cashUSDT = 900
        let tomorrow = now + 86_400
        _ = BotEngine.step(Fixture.snapshot(mid: 1.0, now: tomorrow), state: &state, settings: s, fastMoveBps: 0, now: tomorrow)
        XCTAssertEqual(state.day, BotEngine.utcDay(tomorrow))
        XCTAssertEqual(state.dayStartEquityUSDT, 900, accuracy: 1e-9)
    }

    func testMetricsExposeNextBuyAndSellLevels() {
        let s = Fixture.settings()
        var state = fresh(s)
        addLot(&state, quantity: 50, buyPrice: 1.0)
        let snap = Fixture.snapshot(mid: 1.0)
        let m = BotEngine.metrics(snap, state: state, settings: s, now: now)
        XCTAssertNotNil(m.nextBuyPrice)
        XCTAssertNotNil(m.nextSellPrice)
        XCTAssertGreaterThan(m.nextSellPrice ?? 0, 1.0)
        XCTAssertLessThan(m.nextBuyPrice ?? 9, 1.0)
        XCTAssertEqual(m.roundTripCostBps, m.spreadBps + 20, accuracy: 1e-9)
    }

    func testPumpThenRedCandleBlocksBuying() {
        let s = Fixture.settings()
        var state = fresh(s)
        let closes = Array(repeating: 1.0, count: 30) + [1.0, 1.01, 1.02, 1.03, 1.04, 1.036]
        let candles = MoveDetectorTests.candles(closes, endingAt: now - 70)
        let r = BotEngine.step(Fixture.snapshot(mid: 1.028, candles: candles), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .wait)
        XCTAssertTrue(r.reason.hasPrefix("Anstieg erkannt"), r.reason)
    }
}
