import Foundation

// MARK: - Schattenkonten

/// Ein Schattenkonto: eigene Einstellungen und ein eigenes Papierkonto, das auf denselben Live-Daten wie das
/// Hauptkonto handelt. So lassen sich mehrere Einstellungen gleichzeitig unter echten Bedingungen vergleichen.
public struct ShadowAccount: Codable, Identifiable, Equatable, Sendable {
    public static let maxAccounts = 5
    public static let eventLimit = 500

    public var id: UUID
    public var name: String
    public var settings: BotSettings
    public var state: BotState
    /// Nur Trades, aelteste zuerst (begrenzt auf `eventLimit`).
    public var events: [BotEvent]
    public var createdAt: Double
    /// Bid beim Anlegen (Vergleich mit Halten).
    public var startBid: Double?
    /// Letzte Entscheidung der Engine (fuer die Anzeige).
    public var lastReason: String
    public var sells: Int
    public var wins: Int

    public init(id: UUID = UUID(), name: String, settings: BotSettings, at now: Double, bid: Double?) {
        let clamped = settings.clamped()
        self.id = id
        self.name = name
        self.settings = clamped
        state = BotState.fresh(clamped, at: now)
        events = []
        createdAt = now
        startBid = (bid ?? 0) > 0 ? bid : nil
        lastReason = "Wartet auf Marktdaten"
        sells = 0
        wins = 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, settings, state, events, createdAt, startBid, lastReason, sells, wins
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let settings: BotSettings = c.value(.settings, BotSettings())
        id = c.value(.id, UUID())
        name = c.value(.name, "Schattenkonto")
        self.settings = settings.clamped()
        createdAt = c.value(.createdAt, 0.0)
        state = c.value(.state, BotState.fresh(settings, at: createdAt))
        events = c.value(.events, [])
        startBid = c.optionalValue(.startBid)
        lastReason = c.value(.lastReason, "")
        sells = c.value(.sells, 0)
        wins = c.value(.wins, 0)
    }

    /// Ein Marktdurchlauf mit den eigenen Einstellungen. Gibt den Trade zurueck, falls gehandelt wurde.
    @discardableResult
    public mutating func step(_ snap: MarketSnapshot, fastMoveBps: Double, now: Double) -> BotEvent? {
        let r = BotEngine.step(snap, state: &state, settings: settings, fastMoveBps: fastMoveBps, now: now, verbose: true)
        lastReason = r.reason
        guard let e = r.event else { return nil }
        if e.isSell {
            sells += 1
            if e.realizedPnLUSDT > 0 { wins += 1 }
        }
        events.append(e)
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
        return e
    }

    public func equity(bid: Double) -> Double { state.equity(atBid: bid) }

    public func result(bid: Double) -> Double { equity(bid: bid) - settings.startingUSDT }

    public func returnFraction(bid: Double) -> Double {
        settings.startingUSDT > 0 ? result(bid: bid) / settings.startingUSDT : 0
    }

    /// Kursveraenderung seit dem Anlegen (reines Halten, ohne Kosten).
    public func holdReturnFraction(bid: Double) -> Double? {
        guard let start = startBid, start > 0, bid > 0 else { return nil }
        return bid / start - 1
    }

    public var winRate: Double? { sells > 0 ? Double(wins) / Double(sells) : nil }
    public var buys: Int { events.reduce(0) { $0 + ($1.isBuy ? 1 : 0) } }

    /// Setzt das Papierkonto zurueck (Einstellungen bleiben).
    public mutating func reset(at now: Double, bid: Double?) {
        self = ShadowAccount(id: id, name: name, settings: settings, at: now, bid: bid)
    }
}

/// Alle Schattenkonten (Datei `shadow-accounts.json`).
public struct ShadowBook: Codable, Equatable, Sendable {
    public var version = 1
    public var accounts: [ShadowAccount] = []

    public init(accounts: [ShadowAccount] = []) { self.accounts = accounts }

    private enum CodingKeys: String, CodingKey { case version, accounts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, 1)
        accounts = Array(c.value(.accounts, [ShadowAccount]()).prefix(ShadowAccount.maxAccounts))
    }
}

/// Vorlagen fuer neue Schattenkonten. Gebuehren, Startkapital und Slippage kommen immer aus den aktuellen Einstellungen.
public enum ShadowPreset: String, CaseIterable, Identifiable, Sendable {
    case current = "Aktuelle Einstellungen"
    case cautious = "Vorsichtig"
    case balanced = "Ausgewogen (Standard)"
    case active = "Aktiv"
    case maker = "Aktuelle mit Limit-Kauf am Bid"
    case noTrendFilter = "Aktuelle ohne Trendfilter"

    public var id: String { rawValue }

    public var summary: String {
        switch self {
        case .current: return "Genau die Einstellungen des Hauptkontos – als Vergleichsbasis."
        case .cautious: return "Kleiner Einsatz (25 USDT), höchstens 4 Positionen, Ziel 80 bp, Stop 2 %, mehr Abstand zwischen Käufen."
        case .balanced: return "Die Standardwerte der App."
        case .active: return "Ziel 30 bp, Stop 4 %, 10 Positionen, kürzere Abstände – handelt häufiger."
        case .maker: return "Kauft mit Limit-Order am Bid statt sofort zum Ask (spart den Spread, wird aber nicht immer ausgeführt)."
        case .noTrendFilter: return "Kauft auch im Abwärtstrend nach – zeigt, was der Trendfilter bringt."
        }
    }

    public func settings(from current: BotSettings) -> BotSettings {
        var s: BotSettings
        switch self {
        case .current, .maker, .noTrendFilter:
            s = current
        case .cautious, .balanced, .active:
            s = BotSettings()
        }
        // Kontobezogene Werte bleiben gleich, damit der Vergleich fair ist.
        s.startingUSDT = current.startingUSDT
        s.feeBps = current.feeBps
        s.makerFeeBps = current.makerFeeBps
        s.slippageBps = current.slippageBps
        switch self {
        case .current, .balanced:
            break
        case .cautious:
            s.maxTradeUSDT = 25
            s.maxOpenPositions = 4
            s.minNetProfitBps = 80
            s.stopLossFraction = 0.02
            s.minLotDistanceFactor = 1
            s.maxDailyLossFraction = 0.01
        case .active:
            s.minNetProfitBps = 30
            s.stopLossFraction = 0.04
            s.maxOpenPositions = 10
            s.minLotDistanceFactor = 0.3
            s.minSecondsBetweenTrades = 10
        case .maker:
            s.makerEntries = true
        case .noTrendFilter:
            s.trendFilterEnabled = false
        }
        return s.clamped()
    }
}
