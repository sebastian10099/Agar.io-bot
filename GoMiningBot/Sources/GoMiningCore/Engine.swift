import Foundation

/// Kennzahlen, die Engine und Oberflaeche gemeinsam nutzen.
public struct EngineMetrics: Sendable {
    public var spreadBps: Double = 0
    public var volatilityBps: Double = 0
    /// Kaufschwelle (bp Rueckgang vom Hoch der letzten Kerzen).
    public var stepBps: Double = 0
    /// Verkaufsziel (bp Nettogewinn).
    public var exitBps: Double = 0
    public var dropBps: Double = 0
    public var riseBps: Double = 0
    public var windowHigh: Double = 0
    public var windowLow: Double = 0
    public var pressure: Double?
    public var minerWars: Bool = false
    public var moves: [Move] = []
    public var moveSignal: MoveSignal?
    /// "Dynamischer Kauf ab": Preis, unter dem der naechste Kauf ausloest.
    public var nextBuyPrice: Double?
    /// "Dynamischer Verkauf ab": Bid, ab dem das erste Los sein Nettoziel erreicht.
    public var nextSellPrice: Double?
    /// Kosten fuer sofortiges Kaufen und Zurueckverkaufen in bp (Spread + Gebuehren + Slippage).
    public var roundTripCostBps: Double = 0
}

public struct StepResult: Sendable {
    public enum Kind: String, Sendable { case paused, wait, watch, buy, sell, seed }
    public var kind: Kind
    public var reason: String
    /// Nur bei Trades gesetzt.
    public var event: BotEvent?

    public var isTrade: Bool { event != nil }
}

public enum BotEngine {
    /// Reste unter diesem Anteil des Trade-Einsatzes belegen keinen regulaeren Positionsplatz.
    public static let dustFraction = 0.10
    static let pressureCalm = 0.40
    static let pressureFast = 0.55
    static let pressureTrend = 0.60
    static let minerWarsFactor = 1.25

    // MARK: - Zeit (rein arithmetisch, ohne DateFormatter: schnell genug fuer Backtests)

    public static func dayIndex(_ t: Double) -> Int { Int((t / 86_400).rounded(.down)) }

    public static func utcDay(_ t: Double) -> String { civilDay(dayIndex(t)) }

    /// `yyyy-MM-dd` fuer einen Tag seit 1970-01-01 (proleptischer gregorianischer Kalender).
    public static func civilDay(_ daysSinceEpoch: Int) -> String {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        if m <= 2 { y += 1 }
        return String(format: "%04ld-%02ld-%02ld", y, m, d)
    }

    public static func dayIndex(fromDay day: String) -> Int? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, var y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        if m <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Miner-Wars-Fenster: Dienstag 00:00-18:00 UTC (moegliches Auszahlungsfenster).
    public static func inSettlementWindow(_ t: Double) -> Bool {
        let day = dayIndex(t)
        let weekday = ((day + 4) % 7 + 7) % 7        // 0 = Sonntag; 1970-01-01 war ein Donnerstag
        guard weekday == 2 else { return false }
        return t - Double(day) * 86_400 < 18 * 3_600
    }

    // MARK: - Positionen

    /// Zahl regulaerer Positionen (Reste unter 10 % des Trade-Einsatzes zaehlen nicht).
    public static func openPositionCount(_ lots: [PositionLot], bid: Double, settings: BotSettings, minNotional: Double) -> Int {
        let threshold = max(minNotional, dustFraction * settings.maxTradeUSDT)
        var n = 0
        for lot in lots where lot.quantity * bid >= threshold { n += 1 }
        return n
    }

    static func normalize(_ state: inout BotState) {
        var q = 0.0
        var c = 0.0
        for lot in state.lots { q += lot.quantity; c += lot.costBasisUSDT }
        state.tokens = q
        state.costBasisUSDT = c
    }

    /// Fasst mehrere Reste (unter Mindestbetrag bzw. 10 % des Einsatzes) zu einem Los zusammen.
    /// Einstand und Menge bleiben erhalten; so blockieren Reste keine Positionsplaetze.
    static func consolidateDust(_ state: inout BotState, bid: Double, settings: BotSettings, minNotional: Double) {
        guard state.lots.count >= 2, bid > 0 else { return }
        let threshold = max(minNotional, dustFraction * settings.maxTradeUSDT)
        var dustIndexes: [Int] = []
        for (i, lot) in state.lots.enumerated() where lot.quantity * bid < threshold { dustIndexes.append(i) }
        guard dustIndexes.count >= 2 else { return }
        var merged = state.lots[dustIndexes[0]]
        for i in dustIndexes.dropFirst() {
            let other = state.lots[i]
            merged.quantity += other.quantity
            merged.costBasisUSDT += other.costBasisUSDT
            merged.boughtAt = min(merged.boughtAt, other.boughtAt)
            merged.peakPriceUSDT = max(merged.peakPriceUSDT ?? 0, other.peakPriceUSDT ?? 0)
            merged.isSeed = merged.isSeed || other.isSeed
        }
        merged.buyPriceUSDT = merged.quantity > 0 ? merged.costBasisUSDT / merged.quantity : merged.buyPriceUSDT
        var lots: [PositionLot] = []
        lots.reserveCapacity(state.lots.count - dustIndexes.count + 1)
        for (i, lot) in state.lots.enumerated() {
            if i == dustIndexes[0] { lots.append(merged) } else if !dustIndexes.contains(i) { lots.append(lot) }
        }
        state.lots = lots
    }

    // MARK: - Kennzahlen

    public static func metrics(_ snap: MarketSnapshot, state: BotState, settings s: BotSettings, now: Double) -> EngineMetrics {
        var m = EngineMetrics()
        let bid = snap.bid
        let ask = snap.ask
        m.spreadBps = snap.spreadBps
        m.volatilityBps = Indicators.volatilityBps(snap.candles)
        m.minerWars = inSettlementWindow(now)
        m.roundTripCostBps = m.spreadBps + s.roundTripFeeBps

        let adaptive = max(5, 1.5 * m.spreadBps + 2 * (s.feeBps + s.slippageBps), 2 * m.volatilityBps)
        var step = min(adaptive, max(5, s.gridDropBps))
        if m.minerWars { step *= minerWarsFactor }
        m.stepBps = step
        m.exitBps = max(s.minNetProfitBps, 0.5 * m.spreadBps, 1.5 * m.volatilityBps)

        if let hl = Indicators.highLow(snap.candles, bars: s.lookbackBars) {
            m.windowHigh = hl.high
            m.windowLow = hl.low
            if hl.high > 0, ask > 0 { m.dropBps = max(0, (hl.high - ask) / hl.high * 10_000) }
            if hl.low > 0, bid > 0 { m.riseBps = max(0, (bid - hl.low) / hl.low * 10_000) }
        }
        m.pressure = Indicators.marketPressure(snap.trades, now: now) ?? snap.pressureHint

        if s.useMoveDetector {
            let detector = MoveDetector(settings: s)
            m.moves = detector.analyze(snap.candles)
            m.moveSignal = detector.signal(snap.candles, moves: m.moves)
        }

        if m.windowHigh > 0 {
            var nextBuy = m.windowHigh * (1 - step / 10_000)
            if let lowest = lowestPositionBuyPrice(state.lots, bid: bid, settings: s, minNotional: snap.rules.minNotional) {
                nextBuy = min(nextBuy, lowest * (1 - s.minLotDistanceFactor * step / 10_000))
            }
            m.nextBuyPrice = nextBuy
        }
        let feeRate = s.feeBps / 10_000
        let slipRate = s.slippageBps / 10_000
        let netFactor = (1 - feeRate) * (1 - slipRate)
        if netFactor > 0 {
            var lowestTarget: Double?
            for lot in state.lots where lot.quantity > 0 && lot.costBasisUSDT > 0 {
                let target = (lot.costBasisUSDT / lot.quantity) * (1 + m.exitBps / 10_000) / netFactor
                lowestTarget = min(lowestTarget ?? target, target)
            }
            m.nextSellPrice = lowestTarget
        }
        return m
    }

    static func lowestPositionBuyPrice(_ lots: [PositionLot], bid: Double, settings: BotSettings, minNotional: Double) -> Double? {
        let threshold = max(minNotional, dustFraction * settings.maxTradeUSDT)
        var lowest: Double?
        for lot in lots where lot.quantity * bid >= threshold {
            lowest = min(lowest ?? lot.buyPriceUSDT, lot.buyPriceUSDT)
        }
        return lowest
    }

    // MARK: - Gesundheitspruefungen

    /// Grund, warum ueberhaupt nicht gehandelt werden darf (Orderbuch).
    static func bookProblem(_ snap: MarketSnapshot, settings s: BotSettings, now: Double) -> String? {
        let bid = snap.bid
        let ask = snap.ask
        if !(bid > 0) || !(ask > 0) || ask < bid { return "Ungültiges Orderbuch" }
        if now - snap.bookAt > s.maxBookAgeSeconds { return "Orderbuch veraltet" }
        return nil
    }

    /// Grund, warum keine neuen Kaeufe ausgeloest werden duerfen (Kerzen, Spread, Handelsaktivitaet).
    static func entryProblem(_ snap: MarketSnapshot, settings s: BotSettings, now: Double, verbose: Bool) -> String? {
        let candles = snap.candles
        guard let last = candles.last else { return "Keine Kurskerzen" }
        if candles.count < max(3, min(s.lookbackBars, 10)) { return "Zu wenige Kurskerzen" }
        if now - (last.openedAt + 60) > s.maxCandleAgeSeconds { return "Kurskerzen veraltet" }
        let spread = snap.spreadBps
        if spread > s.maxSpreadBps { return verbose ? String(format: "Spread zu groß (%.0f bp)", spread) : "Spread zu groß" }
        if snap.tradeDataAvailable, Indicators.recentTradeCount(snap.trades, now: now, window: 300) < 1 {
            return "Zu wenig jüngster Handel"
        }
        return nil
    }

    // MARK: - Schritt

    private enum ExitKind { case stop, trailing, target, hold }

    private static func result(_ kind: StepResult.Kind, _ reason: String, event: BotEvent? = nil) -> StepResult {
        StepResult(kind: kind, reason: reason, event: event)
    }

    /// Ein Marktdurchlauf. Veraendert `state`, wenn gehandelt wird (oder bei Tageswechsel).
    public static func step(_ snap: MarketSnapshot, state: inout BotState, settings s: BotSettings,
                            fastMoveBps: Double, now: Double, verbose: Bool = true) -> StepResult {
        let bid = snap.bid
        if bid > 0 {
            let equity = state.equity(atBid: bid)
            let idx = dayIndex(now)
            if idx != state.dayIndex || state.day.isEmpty {
                state.dayIndex = idx
                state.day = civilDay(idx)
                state.dayStartEquityUSDT = equity
            }
            if equity > state.peakEquityUSDT { state.peakEquityUSDT = equity }
        }
        guard state.running else { return result(.paused, "Simulation angehalten") }
        if let problem = bookProblem(snap, settings: s, now: now) { return result(.wait, problem) }

        consolidateDust(&state, bid: bid, settings: s, minNotional: snap.rules.minNotional)
        let m = metrics(snap, state: state, settings: s, now: now)

        if let exit = evaluateExits(snap, state: &state, settings: s, metrics: m, now: now, verbose: verbose) { return exit }
        return evaluateEntries(snap, state: &state, settings: s, metrics: m, fastMoveBps: fastMoveBps, now: now, verbose: verbose)
    }

    // MARK: Ausstiege

    private static func evaluateExits(_ snap: MarketSnapshot, state: inout BotState, settings s: BotSettings,
                                      metrics m: EngineMetrics, now: Double, verbose: Bool) -> StepResult? {
        guard !state.lots.isEmpty else { return nil }
        let bid = snap.bid
        let rules = snap.rules
        let feeRate = s.feeBps / 10_000
        let slipRate = s.slippageBps / 10_000
        let netPerToken = bid * (1 - feeRate) * (1 - slipRate)
        let intervalOK = now - state.lastTradeAt >= s.minSecondsBetweenTrades
        let sellSignal = m.moveSignal?.action == .sell
        let baseTarget = sellSignal ? s.minNetProfitBps : m.exitBps

        for i in state.lots.indices where (state.lots[i].peakPriceUSDT ?? 0) < bid { state.lots[i].peakPriceUSDT = bid }

        var stopIndex: Int?
        var stopWorst = Double.infinity
        var otherIndex: Int?
        var otherKind: ExitKind = .target
        var otherBest = -Double.infinity
        var otherTarget = 0.0

        for i in state.lots.indices {
            let lot = state.lots[i]
            guard lot.quantity > 0, lot.costBasisUSDT > 0 else { continue }
            let costPerToken = lot.costBasisUSDT / lot.quantity
            let markBps = (netPerToken / costPerToken - 1) * 10_000

            if markBps <= -s.stopLossFraction * 10_000 {
                if markBps < stopWorst { stopWorst = markBps; stopIndex = i }
                continue
            }
            guard intervalOK else { continue }

            var kind: ExitKind = .target
            var target = baseTarget
            if s.maxHoldMinutes > 0, now - lot.boughtAt >= s.maxHoldMinutes * 60 {
                kind = .hold
                target = 0
            }
            var qualifies = markBps >= target
            if !qualifies, s.trailingStopBps > 0, markBps > 0 {
                let peak = lot.peakPriceUSDT ?? bid
                let peakGainBps = (peak / lot.buyPriceUSDT - 1) * 10_000
                if peakGainBps >= s.trailingActivationBps, bid <= peak * (1 - s.trailingStopBps / 10_000) {
                    qualifies = true
                    kind = .trailing
                    target = 0
                }
            }
            if qualifies, markBps > otherBest {
                otherBest = markBps
                otherIndex = i
                otherKind = kind
                otherTarget = target
            }
        }

        if let i = stopIndex {
            let lot = state.lots[i]
            guard let q = Book.sellQuote(snap, quantity: lot.quantity, settings: s, allowPartial: true) else {
                return result(.wait, "Stop-Loss ausgelöst, aber Orderbuchtiefe oder Mindestmenge verhindern den Verkauf")
            }
            let partial = q.quantity < lot.quantity - max(rules.stepSize, 1e-9)
            var reason = verbose ? String(format: "Stop-Loss bei %.1f %%", s.stopLossFraction * 100) : "Stop-Loss"
            if partial { reason += " · Teilverkauf nach Orderbuchtiefe" }
            let event = applySale(snap, state: &state, lotIndex: i, quote: q, reason: reason, settings: s, now: now, isStop: true)
            return result(.sell, reason, event: event)
        }

        guard let i = otherIndex else { return nil }
        let lot = state.lots[i]
        var wantQty = lot.quantity
        let tranche = Book.floorToStep(s.maxTradeUSDT / bid, step: rules.stepSize)
        if tranche > 0, tranche < lot.quantity {
            let remainder = lot.quantity - tranche
            let dust = max(rules.minNotional, dustFraction * s.maxTradeUSDT)
            wantQty = remainder * bid < dust ? lot.quantity : tranche
        }
        guard let q = Book.sellQuote(snap, quantity: wantQty, settings: s, allowPartial: true) else { return nil }
        let costPart = q.quantity >= lot.quantity - 1e-12 ? lot.costBasisUSDT : lot.costBasisUSDT * q.quantity / lot.quantity
        guard costPart > 0 else { return nil }
        let netBps = (q.netUSDT - costPart) / costPart * 10_000
        if otherKind == .trailing { guard netBps > 0 else { return nil } }
        else if netBps < otherTarget { return nil }

        let partialByDepth = q.quantity < wantQty - max(rules.stepSize, 1e-9)
        var reason: String
        switch otherKind {
        case .trailing:
            reason = verbose ? String(format: "Trailing-Stop (%.0f bp unter dem Hoch)", s.trailingStopBps) : "Trailing-Stop"
        case .hold:
            reason = "Zeit-Ausstieg: Kostendeckung nach \(Int(s.maxHoldMinutes)) min"
        default:
            if sellSignal, let sig = m.moveSignal { reason = "Gewinnmitnahme nach \(sig.reason)" } else { reason = "Adaptives Nettoziel" }
            if verbose { reason += String(format: " (%+.0f bp)", netBps) }
        }
        if partialByDepth { reason += " · Teilverkauf nach Orderbuchtiefe" }
        let event = applySale(snap, state: &state, lotIndex: i, quote: q, reason: reason, settings: s, now: now, isStop: false)
        return result(.sell, reason, event: event)
    }

    private static func applySale(_ snap: MarketSnapshot, state: inout BotState, lotIndex i: Int, quote q: SpotSellQuote,
                                  reason: String, settings s: BotSettings, now: Double, isStop: Bool) -> BotEvent {
        let lot = state.lots[i]
        let full = q.quantity >= lot.quantity - 1e-12
        let costPart = full ? lot.costBasisUSDT : lot.costBasisUSDT * q.quantity / lot.quantity
        let pnl = q.netUSDT - costPart
        if full {
            state.lots.remove(at: i)
        } else {
            state.lots[i].quantity -= q.quantity
            state.lots[i].costBasisUSDT -= costPart
        }
        state.cashUSDT += q.netUSDT
        state.realizedPnLUSDT += pnl
        state.totalFeesUSDT += q.feeUSDT
        state.anchorUSDT = q.priceUSDT
        state.lastSellPriceUSDT = q.priceUSDT
        state.lastTradeAt = now
        if isStop { state.cooldownUntil = now + s.cooldownAfterStopSeconds }
        normalize(&state)
        let equity = state.equity(atBid: snap.bid)
        return BotEvent(at: now, action: BotAction.sell, reason: reason, bidUSDT: snap.bid, askUSDT: snap.ask,
                        quantity: q.quantity, priceUSDT: q.priceUSDT, feeUSDT: q.feeUSDT, realizedPnLUSDT: pnl,
                        equityUSDT: equity, heldSeconds: max(0, now - lot.boughtAt),
                        netBps: costPart > 0 ? pnl / costPart * 10_000 : nil)
    }

    // MARK: Einstiege

    private static func evaluateEntries(_ snap: MarketSnapshot, state: inout BotState, settings s: BotSettings,
                                        metrics m: EngineMetrics, fastMoveBps: Double, now: Double, verbose: Bool) -> StepResult {
        let bid = snap.bid
        let ask = snap.ask
        let rules = snap.rules
        let equity = state.equity(atBid: bid)

        if equity < state.dayStartEquityUSDT * (1 - s.maxDailyLossFraction) {
            return result(.wait, "Tagesverlustgrenze erreicht")
        }
        if s.maxDrawdownFraction > 0, state.peakEquityUSDT > 0, equity < state.peakEquityUSDT * (1 - s.maxDrawdownFraction) {
            return result(.wait, "Drawdown-Grenze erreicht")
        }
        if now < state.cooldownUntil { return result(.wait, "Abkühlphase nach Stop-Loss") }
        if now - state.lastTradeAt < s.minSecondsBetweenTrades { return result(.wait, "Mindestabstand zwischen Trades") }

        let positions = openPositionCount(state.lots, bid: bid, settings: s, minNotional: rules.minNotional)
        let limit = s.openPositionLimit
        if positions >= limit {
            return result(.wait, verbose ? "Alle \(limit) Positionen belegt" : "Positionen belegt")
        }
        if state.lots.count >= max(10, limit * 2) { return result(.wait, "Zehn Bestandslose einschließlich kleiner Reste belegt") }

        let tokenValue = state.tokens * bid
        let room = s.maxPositionFraction * equity - tokenValue
        if room < rules.minNotional { return result(.wait, "Kauf: Bestandsgrenze für Neukäufe erreicht") }
        if state.cashUSDT < max(rules.minNotional, 0.01) { return result(.wait, "Kauf: kein virtuelles USDT verfügbar") }

        if let problem = entryProblem(snap, settings: s, now: now, verbose: verbose) { return result(.wait, problem) }

        // --- Ausloeser ---
        let step = m.stepBps
        let press = m.pressure
        let pressureFloor = m.minerWars ? pressureFast : pressureCalm
        let calmOK: Bool = {
            if let p = press { return p >= pressureFloor }
            return !m.minerWars                      // ohne Handelsdaten nur ausserhalb des Miner-Wars-Fensters
        }()

        var distanceOK = true
        if let lowest = lowestPositionBuyPrice(state.lots, bid: bid, settings: s, minNotional: rules.minNotional) {
            distanceOK = ask <= lowest * (1 - s.minLotDistanceFactor * step / 10_000)
        }

        if m.moveSignal?.action == .sell {
            return result(.wait, "Anstieg erkannt: kein Kauf in den Pump (\(m.moveSignal?.reason ?? ""))")
        }

        var trigger: String?
        if m.dropBps >= step, calmOK, distanceOK {
            trigger = "Adaptiver Rückgang erkannt"
        } else if snap.tradeDataAvailable, fastMoveBps <= -max(10, 0.25 * step), m.dropBps >= 0.5 * step,
                  let p = press, p >= pressureFast, distanceOK {
            trigger = "Schneller Rückgang mit frischem Kaufdruck erkannt"
        } else if let sig = m.moveSignal, sig.action == .buy, calmOK, distanceOK {
            trigger = "Fall bestätigt: \(sig.reason)"
        } else if m.riseBps >= minerWarsFactor * step, let p = press, p >= pressureTrend, risingCloses(snap.candles),
                  positions < max(1, limit / 2) {
            trigger = "Aufwärtstrend und Kaufdruck erkannt"
        }

        guard let reason = trigger else {
            if !verbose { return result(.watch, "") }
            var text = String(format: "Rückgang %.0f / Anstieg %.0f bp · Schwelle %.0f bp", m.dropBps, m.riseBps, step)
            if m.minerWars { text += " · Miner-Wars-Fenster" }
            if let p = press { text += String(format: " · Käuferanteil %.0f%%", p * 100) }
            return result(.watch, text)
        }

        // --- Kauf ---
        var budget = min(s.maxTradeUSDT, state.cashUSDT, room)
        budget = max(0, budget)
        switch Book.buyQuote(snap, budgetUSDT: budget, settings: s) {
        case .failure(let failure):
            switch failure {
            case .bookTooThin: return result(.wait, "Kauf: Orderbucheinfluss zu groß")
            case .tradingDisabled: return result(.wait, "Kauf: Handel für das Symbol derzeit gesperrt")
            default: return result(.wait, "Kauf: Mindestmenge oder Orderbuchtiefe")
            }
        case .success(let q):
            let lot = PositionLot(quantity: q.quantity, costBasisUSDT: q.totalUSDT, buyPriceUSDT: q.priceUSDT,
                                  boughtAt: now, peakPriceUSDT: bid)
            state.lots.append(lot)
            state.cashUSDT -= q.totalUSDT
            state.totalFeesUSDT += q.feeUSDT
            state.anchorUSDT = q.priceUSDT
            state.lastTradeAt = now
            normalize(&state)
            let event = BotEvent(at: now, action: BotAction.buy, reason: reason, bidUSDT: bid, askUSDT: ask,
                                 quantity: q.quantity, priceUSDT: q.priceUSDT, feeUSDT: q.feeUSDT,
                                 equityUSDT: state.equity(atBid: bid))
            return result(.buy, reason, event: event)
        }
    }

    /// Die letzten drei Schlusskurse steigen.
    private static func risingCloses(_ candles: [PriceCandle]) -> Bool {
        let n = candles.count
        guard n >= 3 else { return false }
        return candles[n - 1].close > candles[n - 2].close && candles[n - 2].close > candles[n - 3].close
    }

    // MARK: - Startkauf

    /// Einmaliger virtueller Kauf zum Ask-Referenzpreis (Vergleichsbasis "Halten").
    public static func seedReferencePosition(_ snap: MarketSnapshot, state: inout BotState, settings s: BotSettings,
                                             budgetUSDT: Double, now: Double) -> BotEvent? {
        let ask = snap.ask
        let rules = snap.rules
        guard ask > 0, budgetUSDT > 0, state.cashUSDT >= budgetUSDT - 1e-9 else { return nil }
        let price = ask * (1 + s.slippageBps / 10_000)
        let feeRate = s.feeBps / 10_000
        let qty = Book.floorToStep(budgetUSDT / (price * (1 + feeRate)), step: rules.stepSize)
        guard qty > 0, qty >= rules.minQuantity else { return nil }
        let notional = qty * price
        let fee = notional * feeRate
        let total = notional + fee
        state.cashUSDT -= total
        state.totalFeesUSDT += fee
        state.lots.append(PositionLot(quantity: qty, costBasisUSDT: total, buyPriceUSDT: price, boughtAt: now,
                                      peakPriceUSDT: snap.bid, isSeed: true))
        state.anchorUSDT = price
        state.lastTradeAt = now
        normalize(&state)
        let reason = String(format: "Einmaliger virtueller Kauf mit %.0f USDT zum Ask-Referenzpreis; keine bestätigte Ausführung über volle Orderbuchtiefe", budgetUSDT)
        return BotEvent(at: now, action: BotAction.seed, reason: reason, bidUSDT: snap.bid, askUSDT: ask,
                        quantity: qty, priceUSDT: price, feeUSDT: fee, equityUSDT: state.equity(atBid: snap.bid))
    }
}
