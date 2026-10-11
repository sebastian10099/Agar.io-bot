import Foundation

// MARK: - Hilfen zum toleranten Dekodieren

extension KeyedDecodingContainer {
    /// Liest einen Wert; fehlt er oder hat er den falschen Typ, gilt der Standardwert.
    /// So bleiben alte `simulation.json`-Dateien ladbar, auch wenn neue Felder hinzukommen.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func optionalValue<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

// MARK: - Marktdaten

public struct PriceLevel: Codable, Hashable, Sendable {
    public var price: Double
    public var quantity: Double

    public init(price: Double, quantity: Double) {
        self.price = price
        self.quantity = quantity
    }
}

/// 1-Minuten-Kerze mit Eroeffnung, Hoch, Tief und Schluss.
/// Alte gespeicherte Kerzen ohne open/high/low werden weiter geladen (Werte = Schlusskurs).
public struct PriceCandle: Codable, Hashable, Sendable, Identifiable {
    public var openedAt: Double
    public var open: Double
    public var high: Double
    public var low: Double
    public var close: Double
    public var volume: Double

    public var id: Double { openedAt }
    /// Gruen: Schluss >= Eroeffnung.
    public var isGreen: Bool { close >= open }
    public var isCloseOnly: Bool { open == close && high == close && low == close }

    public init(openedAt: Double, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.openedAt = openedAt
        self.open = open
        self.high = max(high, open, close)
        self.low = min(low, open, close)
        self.close = close
        self.volume = volume
    }

    public init(openedAt: Double, close: Double, volume: Double) {
        self.init(openedAt: openedAt, open: close, high: close, low: close, close: close, volume: volume)
    }

    private enum CodingKeys: String, CodingKey {
        case openedAt, open, high, low, close, volume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let openedAt = try c.decode(Double.self, forKey: .openedAt)
        let close = try c.decode(Double.self, forKey: .close)
        let volume = c.value(.volume, 0.0)
        let open = c.value(.open, close)
        let high = c.value(.high, max(open, close))
        let low = c.value(.low, min(open, close))
        self.init(openedAt: openedAt, open: open, high: high, low: low, close: close, volume: volume)
    }
}

/// Oeffentlicher Markttrade (anonym).
public struct PublicTrade: Codable, Hashable, Sendable {
    public var id: Int64
    public var at: Double
    public var price: Double
    public var quantity: Double
    /// `true`, wenn der Kaeufer der aktive Teil (Taker) war.
    public var buyerInitiated: Bool

    public init(id: Int64, at: Double, price: Double, quantity: Double, buyerInitiated: Bool) {
        self.id = id
        self.at = at
        self.price = price
        self.quantity = quantity
        self.buyerInitiated = buyerInitiated
    }
}

/// Handelsregeln der Boerse fuer das Symbol.
public struct SymbolRules: Codable, Hashable, Sendable {
    public var minQuantity: Double
    public var minNotional: Double
    public var stepSize: Double
    public var buyEnabled: Bool
    public var sellEnabled: Bool
    /// `false`, wenn die Werte nur vorsichtig geschaetzt sind (BingX lieferte keine Mindestorder).
    public var verified: Bool

    public init(minQuantity: Double, minNotional: Double, stepSize: Double,
                buyEnabled: Bool = true, sellEnabled: Bool = true, verified: Bool = true) {
        self.minQuantity = minQuantity
        self.minNotional = minNotional
        self.stepSize = stepSize
        self.buyEnabled = buyEnabled
        self.sellEnabled = sellEnabled
        self.verified = verified
    }

    public static let fallback = SymbolRules(minQuantity: 0, minNotional: 5, stepSize: 0.0001, verified: false)
}

/// Ein Moment des Marktes: Orderbuch, geschlossene Kerzen, jüngste Trades.
public struct MarketSnapshot: Sendable {
    public var receivedAt: Double
    public var bookAt: Double
    /// Abgeschlossene 1-Minuten-Kerzen, aufsteigend nach Zeit.
    public var candles: [PriceCandle]
    /// Asks aufsteigend, Bids absteigend.
    public var asks: [PriceLevel]
    public var bids: [PriceLevel]
    public var rules: SymbolRules
    public var trades: [PublicTrade]
    /// `false` im Kerzen-Backtest: es gibt keine Einzeltrades.
    public var tradeDataAvailable: Bool
    /// Ersatz fuer den Kaeuferanteil, wenn keine Trades vorliegen (Backtest).
    public var pressureHint: Double?

    public init(receivedAt: Double, bookAt: Double, candles: [PriceCandle], asks: [PriceLevel], bids: [PriceLevel],
                rules: SymbolRules, trades: [PublicTrade] = [], tradeDataAvailable: Bool = true,
                pressureHint: Double? = nil) {
        self.receivedAt = receivedAt
        self.bookAt = bookAt
        self.candles = candles
        self.asks = asks
        self.bids = bids
        self.rules = rules
        self.trades = trades
        self.tradeDataAvailable = tradeDataAvailable
        self.pressureHint = pressureHint
    }

    public var minQuantity: Double { rules.minQuantity }
    public var minNotional: Double { rules.minNotional }
    public var stepSize: Double { rules.stepSize }

    public var bid: Double { bids.first?.price ?? 0 }
    public var ask: Double { asks.first?.price ?? 0 }
    public var mid: Double { (bid > 0 && ask > 0) ? (bid + ask) / 2 : 0 }
    public var spreadBps: Double { mid > 0 ? (ask - bid) / mid * 10_000 : 0 }

    public var lastTradePrice: Double? {
        trades.last?.price
    }

    /// Kurs fuer die Anzeige: letzter Trade, sonst Buchmitte, sonst letzter Schlusskurs.
    public var displayPrice: Double {
        if let p = lastTradePrice, p > 0 { return p }
        if mid > 0 { return mid }
        return candles.last?.close ?? 0
    }

    public var bidDepthUSDT: Double { bids.reduce(0) { $0 + $1.price * $1.quantity } }
    public var askDepthUSDT: Double { asks.reduce(0) { $0 + $1.price * $1.quantity } }
}

// MARK: - Einstellungen

public struct MoveWindow: Codable, Hashable, Sendable {
    public var minutes: Int
    public var thresholdPercent: Double

    public init(minutes: Int, thresholdPercent: Double) {
        self.minutes = minutes
        self.thresholdPercent = thresholdPercent
    }
}

public struct BotSettings: Codable, Equatable, Sendable {
    // Papierkonto
    public var startingUSDT: Double = 1_000
    public var feeBps: Double = 10
    public var slippageBps: Double = 0

    // Einstieg
    /// Obergrenze fuer den dynamischen Kaufabstand (bp).
    public var gridDropBps: Double = 160
    public var maxTradeUSDT: Double = 50
    public var maxPositionFraction: Double = 0.5
    public var maxOpenPositions: Int? = 10
    public var lookbackBars: Int = 20
    /// Mindestabstand des naechsten Kaufs zum tiefsten offenen Kauf, in Vielfachen des Kaufabstands.
    public var minLotDistanceFactor: Double = 0.5

    // Ausstieg
    public var minNetProfitBps: Double = 50
    public var stopLossFraction: Double = 0.03
    /// 0 = aus. Verkauft, wenn der Kurs so viele bp unter das Hoch seit dem Kauf faellt.
    public var trailingStopBps: Double = 0
    /// Gewinn (bp ueber Einstand), ab dem der Trailing-Stop scharf wird.
    public var trailingActivationBps: Double = 100
    /// 0 = aus. Nach dieser Haltedauer genuegt Kostendeckung als Verkaufsziel.
    public var maxHoldMinutes: Double = 0

    // Risiko
    public var maxDailyLossFraction: Double = 0.02
    /// 0 = aus. Stoppt Neukaeufe, wenn das Vermoegen so weit unter sein Hoch faellt.
    public var maxDrawdownFraction: Double = 0
    public var minSecondsBetweenTrades: Double = 20
    public var cooldownAfterStopSeconds: Double = 300

    // Marktqualitaet
    public var maxSpreadBps: Double = 100
    public var maxBookParticipation: Double = 0.3
    public var maxBookAgeSeconds: Double = 15
    public var maxCandleAgeSeconds: Double = 120

    // Anstiegs-/Fall-Erkennung (6/8/20/60 Minuten)
    public var useMoveDetector: Bool = true
    public var moveWindows: [MoveWindow] = MoveDetector.defaultWindows
    public var moveRequireConfirmation: Bool = true
    public var moveMaxRetracePercent: Double = 60

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case startingUSDT, feeBps, slippageBps
        case gridDropBps, maxTradeUSDT, maxPositionFraction, maxOpenPositions, lookbackBars, minLotDistanceFactor
        case minNetProfitBps, stopLossFraction, trailingStopBps, trailingActivationBps, maxHoldMinutes
        case maxDailyLossFraction, maxDrawdownFraction, minSecondsBetweenTrades, cooldownAfterStopSeconds
        case maxSpreadBps, maxBookParticipation, maxBookAgeSeconds, maxCandleAgeSeconds
        case useMoveDetector, moveWindows, moveRequireConfirmation, moveMaxRetracePercent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BotSettings()
        startingUSDT = c.value(.startingUSDT, d.startingUSDT)
        feeBps = c.value(.feeBps, d.feeBps)
        slippageBps = c.value(.slippageBps, d.slippageBps)
        gridDropBps = c.value(.gridDropBps, d.gridDropBps)
        maxTradeUSDT = c.value(.maxTradeUSDT, d.maxTradeUSDT)
        maxPositionFraction = c.value(.maxPositionFraction, d.maxPositionFraction)
        maxOpenPositions = c.optionalValue(.maxOpenPositions)
        lookbackBars = c.value(.lookbackBars, d.lookbackBars)
        minLotDistanceFactor = c.value(.minLotDistanceFactor, d.minLotDistanceFactor)
        minNetProfitBps = c.value(.minNetProfitBps, d.minNetProfitBps)
        stopLossFraction = c.value(.stopLossFraction, d.stopLossFraction)
        trailingStopBps = c.value(.trailingStopBps, d.trailingStopBps)
        trailingActivationBps = c.value(.trailingActivationBps, d.trailingActivationBps)
        maxHoldMinutes = c.value(.maxHoldMinutes, d.maxHoldMinutes)
        maxDailyLossFraction = c.value(.maxDailyLossFraction, d.maxDailyLossFraction)
        maxDrawdownFraction = c.value(.maxDrawdownFraction, d.maxDrawdownFraction)
        minSecondsBetweenTrades = c.value(.minSecondsBetweenTrades, d.minSecondsBetweenTrades)
        cooldownAfterStopSeconds = c.value(.cooldownAfterStopSeconds, d.cooldownAfterStopSeconds)
        maxSpreadBps = c.value(.maxSpreadBps, d.maxSpreadBps)
        maxBookParticipation = c.value(.maxBookParticipation, d.maxBookParticipation)
        maxBookAgeSeconds = c.value(.maxBookAgeSeconds, d.maxBookAgeSeconds)
        maxCandleAgeSeconds = c.value(.maxCandleAgeSeconds, d.maxCandleAgeSeconds)
        useMoveDetector = c.value(.useMoveDetector, d.useMoveDetector)
        moveWindows = c.value(.moveWindows, d.moveWindows)
        moveRequireConfirmation = c.value(.moveRequireConfirmation, d.moveRequireConfirmation)
        moveMaxRetracePercent = c.value(.moveMaxRetracePercent, d.moveMaxRetracePercent)
    }

    /// Wirksames Positionslimit (mindestens 1).
    public var openPositionLimit: Int { max(1, maxOpenPositions ?? BotSettings.defaultMaxOpenPositions) }
    public static let defaultMaxOpenPositions = 10

    /// Rundtrip-Kosten (Kauf + Verkauf) in bp ohne Spread.
    public var roundTripFeeBps: Double { 2 * (feeBps + slippageBps) }

    /// Begrenzt alle Werte auf sinnvolle Bereiche (schuetzt vor Tippfehlern in der Oberflaeche).
    public func clamped() -> BotSettings {
        var s = self
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v.isFinite ? v : lo)) }
        s.startingUSDT = clamp(s.startingUSDT, 10, 10_000_000)
        s.feeBps = clamp(s.feeBps, 0, 200)
        s.slippageBps = clamp(s.slippageBps, 0, 500)
        s.gridDropBps = clamp(s.gridDropBps, 10, 5_000)
        s.maxTradeUSDT = clamp(s.maxTradeUSDT, 1, 1_000_000)
        s.maxPositionFraction = clamp(s.maxPositionFraction, 0.05, 1)
        if let n = s.maxOpenPositions { s.maxOpenPositions = min(50, max(1, n)) }
        s.lookbackBars = min(240, max(3, s.lookbackBars))
        s.minLotDistanceFactor = clamp(s.minLotDistanceFactor, 0, 10)
        s.minNetProfitBps = clamp(s.minNetProfitBps, 0, 5_000)
        s.stopLossFraction = clamp(s.stopLossFraction, 0.002, 0.9)
        s.trailingStopBps = clamp(s.trailingStopBps, 0, 5_000)
        s.trailingActivationBps = clamp(s.trailingActivationBps, 0, 5_000)
        s.maxHoldMinutes = clamp(s.maxHoldMinutes, 0, 100_000)
        s.maxDailyLossFraction = clamp(s.maxDailyLossFraction, 0.001, 1)
        s.maxDrawdownFraction = clamp(s.maxDrawdownFraction, 0, 0.95)
        s.minSecondsBetweenTrades = clamp(s.minSecondsBetweenTrades, 0, 86_400)
        s.cooldownAfterStopSeconds = clamp(s.cooldownAfterStopSeconds, 0, 86_400)
        s.maxSpreadBps = clamp(s.maxSpreadBps, 1, 5_000)
        s.maxBookParticipation = clamp(s.maxBookParticipation, 0.01, 1)
        s.maxBookAgeSeconds = clamp(s.maxBookAgeSeconds, 1, 600)
        s.maxCandleAgeSeconds = clamp(s.maxCandleAgeSeconds, 30, 3_600)
        s.moveMaxRetracePercent = clamp(s.moveMaxRetracePercent, 5, 100)
        s.moveWindows = s.moveWindows
            .map { MoveWindow(minutes: min(720, max(2, $0.minutes)), thresholdPercent: clamp($0.thresholdPercent, 0.1, 100)) }
            .sorted { $0.minutes < $1.minutes }
        if s.moveWindows.isEmpty { s.moveWindows = MoveDetector.defaultWindows }
        return s
    }
}

// MARK: - Zustand des Papierkontos

public struct PositionLot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var quantity: Double
    /// Einstand inklusive Kaufgebuehr.
    public var costBasisUSDT: Double
    public var buyPriceUSDT: Double
    public var boughtAt: Double
    /// Hoechster Bid seit dem Kauf (fuer den Trailing-Stop).
    public var peakPriceUSDT: Double?
    /// `true` fuer den virtuellen Startkauf.
    public var isSeed: Bool

    public init(id: UUID = UUID(), quantity: Double, costBasisUSDT: Double, buyPriceUSDT: Double,
                boughtAt: Double, peakPriceUSDT: Double? = nil, isSeed: Bool = false) {
        self.id = id
        self.quantity = quantity
        self.costBasisUSDT = costBasisUSDT
        self.buyPriceUSDT = buyPriceUSDT
        self.boughtAt = boughtAt
        self.peakPriceUSDT = peakPriceUSDT
        self.isSeed = isSeed
    }

    private enum CodingKeys: String, CodingKey {
        case id, quantity, costBasisUSDT, buyPriceUSDT, boughtAt, peakPriceUSDT, isSeed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let quantity = c.value(.quantity, 0.0)
        let cost = c.value(.costBasisUSDT, 0.0)
        id = c.value(.id, UUID())
        self.quantity = quantity
        costBasisUSDT = cost
        buyPriceUSDT = c.value(.buyPriceUSDT, quantity > 0 ? cost / quantity : 0)
        boughtAt = c.value(.boughtAt, 0.0)
        peakPriceUSDT = c.optionalValue(.peakPriceUSDT)
        isSeed = c.value(.isSeed, false)
    }
}

public struct BotState: Codable, Equatable, Sendable {
    public var cashUSDT: Double
    public var tokens: Double
    public var costBasisUSDT: Double
    public var realizedPnLUSDT: Double
    public var totalFeesUSDT: Double
    public var anchorUSDT: Double
    public var lastTradeAt: Double
    /// UTC-Tag `yyyy-MM-dd`.
    public var day: String
    public var dayStartEquityUSDT: Double
    public var running: Bool
    public var lots: [PositionLot]
    // neu in 4.0 (optional im Altbestand)
    public var dayIndex: Int
    public var peakEquityUSDT: Double
    public var cooldownUntil: Double
    public var lastSellPriceUSDT: Double

    public init(cashUSDT: Double, tokens: Double = 0, costBasisUSDT: Double = 0, realizedPnLUSDT: Double = 0,
                totalFeesUSDT: Double = 0, anchorUSDT: Double = 0, lastTradeAt: Double = 0, day: String,
                dayStartEquityUSDT: Double, running: Bool = true, lots: [PositionLot] = [],
                dayIndex: Int = 0, peakEquityUSDT: Double = 0, cooldownUntil: Double = 0,
                lastSellPriceUSDT: Double = 0) {
        self.cashUSDT = cashUSDT
        self.tokens = tokens
        self.costBasisUSDT = costBasisUSDT
        self.realizedPnLUSDT = realizedPnLUSDT
        self.totalFeesUSDT = totalFeesUSDT
        self.anchorUSDT = anchorUSDT
        self.lastTradeAt = lastTradeAt
        self.day = day
        self.dayStartEquityUSDT = dayStartEquityUSDT
        self.running = running
        self.lots = lots
        self.dayIndex = dayIndex
        self.peakEquityUSDT = peakEquityUSDT
        self.cooldownUntil = cooldownUntil
        self.lastSellPriceUSDT = lastSellPriceUSDT
    }

    public static func fresh(_ settings: BotSettings, at now: Double) -> BotState {
        BotState(cashUSDT: settings.startingUSDT, day: BotEngine.utcDay(now),
                 dayStartEquityUSDT: settings.startingUSDT, running: true,
                 dayIndex: BotEngine.dayIndex(now), peakEquityUSDT: settings.startingUSDT)
    }

    private enum CodingKeys: String, CodingKey {
        case cashUSDT, tokens, costBasisUSDT, realizedPnLUSDT, totalFeesUSDT, anchorUSDT, lastTradeAt
        case day, dayStartEquityUSDT, running, lots
        case dayIndex, peakEquityUSDT, cooldownUntil, lastSellPriceUSDT
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cash = c.value(.cashUSDT, 0.0)
        var tokens = c.value(.tokens, 0.0)
        var cost = c.value(.costBasisUSDT, 0.0)
        let lastTradeAt = c.value(.lastTradeAt, 0.0)
        var lots: [PositionLot] = c.optionalValue(.lots) ?? []
        if lots.isEmpty, tokens > 0 {
            // Altbestand ohne Lose: den Bestand als ein Los fuehren.
            lots = [PositionLot(quantity: tokens, costBasisUSDT: cost,
                                buyPriceUSDT: cost / tokens, boughtAt: lastTradeAt)]
        } else if !lots.isEmpty {
            tokens = lots.reduce(0) { $0 + $1.quantity }
            cost = lots.reduce(0) { $0 + $1.costBasisUSDT }
        }
        let day = c.value(.day, "")
        cashUSDT = cash
        self.tokens = tokens
        costBasisUSDT = cost
        realizedPnLUSDT = c.value(.realizedPnLUSDT, 0.0)
        totalFeesUSDT = c.value(.totalFeesUSDT, 0.0)
        anchorUSDT = c.value(.anchorUSDT, 0.0)
        self.lastTradeAt = lastTradeAt
        self.day = day
        dayStartEquityUSDT = c.value(.dayStartEquityUSDT, cash + cost)
        running = c.value(.running, true)
        self.lots = lots
        dayIndex = c.value(.dayIndex, BotEngine.dayIndex(fromDay: day) ?? 0)
        peakEquityUSDT = c.value(.peakEquityUSDT, cash + cost)
        cooldownUntil = c.value(.cooldownUntil, 0.0)
        lastSellPriceUSDT = c.value(.lastSellPriceUSDT, 0.0)
    }

    /// Vermoegen zum Bid (vor Verkaufskosten).
    public func equity(atBid bid: Double) -> Double { cashUSDT + tokens * bid }

    public func tokenValue(atBid bid: Double) -> Double { tokens * bid }
}

// MARK: - Ereignisse

public enum BotAction {
    public static let seed = "Startkauf"
    public static let buy = "Kauf"
    public static let sell = "Verkauf"
    public static let wait = "Warten"
    public static let watch = "Beobachten"
    public static let paused = "Pausiert"
}

public struct BotEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var at: Double
    public var action: String
    public var reason: String
    public var bidUSDT: Double
    public var askUSDT: Double
    public var quantity: Double
    public var priceUSDT: Double
    public var feeUSDT: Double
    public var realizedPnLUSDT: Double
    public var equityUSDT: Double
    // neu in 4.0
    /// Haltedauer des verkauften Loses in Sekunden.
    public var heldSeconds: Double?
    /// Netto-Ergebnis des Verkaufs in bp auf den eingesetzten Betrag.
    public var netBps: Double?

    public var isTrade: Bool { action == BotAction.buy || action == BotAction.sell || action == BotAction.seed }
    public var isSell: Bool { action == BotAction.sell }
    public var isBuy: Bool { action == BotAction.buy || action == BotAction.seed }

    public init(id: UUID = UUID(), at: Double, action: String, reason: String, bidUSDT: Double, askUSDT: Double,
                quantity: Double = 0, priceUSDT: Double = 0, feeUSDT: Double = 0, realizedPnLUSDT: Double = 0,
                equityUSDT: Double, heldSeconds: Double? = nil, netBps: Double? = nil) {
        self.id = id
        self.at = at
        self.action = action
        self.reason = reason
        self.bidUSDT = bidUSDT
        self.askUSDT = askUSDT
        self.quantity = quantity
        self.priceUSDT = priceUSDT
        self.feeUSDT = feeUSDT
        self.realizedPnLUSDT = realizedPnLUSDT
        self.equityUSDT = equityUSDT
        self.heldSeconds = heldSeconds
        self.netBps = netBps
    }

    private enum CodingKeys: String, CodingKey {
        case id, at, action, reason, bidUSDT, askUSDT, quantity, priceUSDT, feeUSDT
        case realizedPnLUSDT, equityUSDT, heldSeconds, netBps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        at = c.value(.at, 0.0)
        action = c.value(.action, "")
        reason = c.value(.reason, "")
        bidUSDT = c.value(.bidUSDT, 0.0)
        askUSDT = c.value(.askUSDT, 0.0)
        quantity = c.value(.quantity, 0.0)
        priceUSDT = c.value(.priceUSDT, 0.0)
        feeUSDT = c.value(.feeUSDT, 0.0)
        realizedPnLUSDT = c.value(.realizedPnLUSDT, 0.0)
        equityUSDT = c.value(.equityUSDT, 0.0)
        heldSeconds = c.optionalValue(.heldSeconds)
        netBps = c.optionalValue(.netBps)
    }
}

// MARK: - Gespeicherter Gesamtzustand (simulation.json)

public struct StoredBot: Codable, Equatable, Sendable {
    public static let currentVersion = 4

    public var state: BotState
    public var settings: BotSettings
    /// Nur echte Trades (Startkauf, Kauf, Verkauf). Warte-Entscheidungen werden nicht gespeichert.
    public var events: [BotEvent]
    public var version: Int?
    public var initialSeedPending: Bool?
    public var initialSeeded: Bool?

    public init(state: BotState, settings: BotSettings, events: [BotEvent] = [],
                version: Int? = StoredBot.currentVersion, initialSeedPending: Bool? = nil, initialSeeded: Bool? = nil) {
        self.state = state
        self.settings = settings
        self.events = events
        self.version = version
        self.initialSeedPending = initialSeedPending
        self.initialSeeded = initialSeeded
    }

    public static func fresh(settings: BotSettings = BotSettings(), at now: Double, seedStartPosition: Bool) -> StoredBot {
        StoredBot(state: .fresh(settings, at: now), settings: settings, events: [],
                  version: currentVersion, initialSeedPending: seedStartPosition, initialSeeded: false)
    }

    private enum CodingKeys: String, CodingKey {
        case state, settings, events, version, initialSeedPending, initialSeeded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var settings: BotSettings = c.value(.settings, BotSettings())
        let version: Int? = c.optionalValue(.version)
        let state: BotState = try c.decode(BotState.self, forKey: .state)
        let rawEvents: [BotEvent] = c.value(.events, [])
        self.version = version
        initialSeedPending = c.optionalValue(.initialSeedPending)
        initialSeeded = c.optionalValue(.initialSeeded)

        // Migration aus Version < 4: alte Standardwerte fuer die Positionszahl (4 bzw. 8) werden zu 10;
        // bewusst gesetzte andere Werte bleiben unveraendert. Warte-Eintraege werden verworfen.
        if (version ?? 0) < StoredBot.currentVersion {
            settings.maxOpenPositions = StoredBot.migratedPositionLimit(settings.maxOpenPositions)
            events = rawEvents.filter { $0.isTrade }
        } else {
            events = rawEvents
        }
        self.state = state
        self.settings = settings
    }

    public static func migratedPositionLimit(_ stored: Int?) -> Int {
        guard let stored else { return BotSettings.defaultMaxOpenPositions }
        return (stored == 4 || stored == 8) ? BotSettings.defaultMaxOpenPositions : max(1, stored)
    }

    // MARK: Auswertung

    /// Wert des unveraenderten virtuellen Startbestands zum Bid, inklusive des beim Startkauf
    /// nicht investierten Restbargelds (nil ohne Startkauf).
    public func holdBenchmarkUSDT(bid: Double) -> Double? {
        guard let seed = events.first(where: { $0.action == BotAction.seed }) else { return nil }
        let spent = seed.quantity * seed.priceUSDT + seed.feeUSDT
        let leftover = max(0, settings.startingUSDT - spent)
        return seed.quantity * bid + leftover
    }

    /// Ergebnis gegenueber Halten in USDT (nil ohne Startkauf).
    public func performanceVsHoldingUSDT(bid: Double) -> Double? {
        guard let hold = holdBenchmarkUSDT(bid: bid) else { return nil }
        return state.equity(atBid: bid) - hold
    }

    /// Haengt ein Ereignis an. Nur Trades werden dauerhaft gefuehrt; die Liste ist auf `limit` begrenzt.
    public mutating func record(_ event: BotEvent, limit: Int = 5_000) {
        guard event.isTrade else { return }
        events.append(event)
        if events.count > limit {
            // Aeltere Trades verwerfen, den Startkauf (Vergleichsbasis) aber behalten.
            var kept = events
            var excess = kept.count - limit
            var i = 0
            while excess > 0, i < kept.count {
                if kept[i].action == BotAction.seed { i += 1; continue }
                kept.remove(at: i)
                excess -= 1
            }
            events = kept
        }
    }
}
