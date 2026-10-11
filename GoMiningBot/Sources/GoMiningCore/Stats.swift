import Foundation

public struct EquityPoint: Codable, Hashable, Sendable, Identifiable {
    public var t: Double
    public var equity: Double
    /// Wert des unveraenderten Startbestands ("Halten"), falls es einen Startkauf gibt.
    public var hold: Double?

    public var id: Double { t }

    public init(t: Double, equity: Double, hold: Double? = nil) {
        self.t = t
        self.equity = equity
        self.hold = hold
    }
}

/// Vermoegensverlauf mit begrenzter Groesse (aeltere Haelfte wird ausgeduennt).
public struct EquityHistory: Codable, Equatable, Sendable {
    public var points: [EquityPoint]

    public init(points: [EquityPoint] = []) { self.points = points }

    public static let maxPoints = 20_000

    /// Haengt einen Punkt an, hoechstens einer pro `minInterval` Sekunden.
    @discardableResult
    public mutating func append(_ point: EquityPoint, minInterval: Double = 60) -> Bool {
        if let last = points.last, point.t - last.t < minInterval { return false }
        points.append(point)
        if points.count > EquityHistory.maxPoints { thin() }
        return true
    }

    /// Behaelt in der aelteren Haelfte nur jeden zweiten Punkt.
    mutating func thin() {
        let half = points.count / 2
        var thinned: [EquityPoint] = []
        thinned.reserveCapacity(points.count - half / 2)
        for (i, p) in points.enumerated() {
            if i >= half || i % 2 == 0 { thinned.append(p) }
        }
        points = thinned
    }
}

public struct DayResult: Hashable, Sendable, Identifiable {
    public var date: Date
    public var pnl: Double
    public var trades: Int
    public var id: Date { date }
}

public struct PerformanceStats: Sendable {
    public var closedTrades = 0
    public var wins = 0
    public var losses = 0
    public var winRate: Double = 0
    public var grossProfit: Double = 0
    public var grossLoss: Double = 0
    /// nil, solange es keinen Verlusttrade gibt.
    public var profitFactor: Double?
    public var averageWin: Double = 0
    public var averageLoss: Double = 0
    /// Durchschnittlicher Gewinn je Verkauf (USDT).
    public var expectancy: Double = 0
    public var bestTrade: Double = 0
    public var worstTrade: Double = 0
    public var averageHoldSeconds: Double?
    public var totalFees: Double = 0
    public var buyCount = 0
    public var maxDrawdownUSDT: Double = 0
    public var maxDrawdownFraction: Double = 0
    /// Positiv = Gewinnserie, negativ = Verlustserie (laufend).
    public var currentStreak = 0
    public var days: [DayResult] = []

    public init() {}

    public static func compute(events: [BotEvent], equity: [EquityPoint], calendar: Calendar = .current) -> PerformanceStats {
        var s = PerformanceStats()
        var holdSum = 0.0
        var holdCount = 0
        var byDay: [Date: (pnl: Double, trades: Int)] = [:]
        var streak = 0
        for e in events {
            s.totalFees += e.feeUSDT
            if e.isBuy { s.buyCount += 1 }
            guard e.isSell else { continue }
            s.closedTrades += 1
            let pnl = e.realizedPnLUSDT
            if pnl > 0 {
                s.wins += 1
                s.grossProfit += pnl
                streak = streak > 0 ? streak + 1 : 1
            } else {
                s.losses += 1
                s.grossLoss += -pnl
                streak = streak < 0 ? streak - 1 : -1
            }
            s.bestTrade = max(s.bestTrade, pnl)
            s.worstTrade = min(s.worstTrade, pnl)
            if let h = e.heldSeconds { holdSum += h; holdCount += 1 }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: e.at))
            var entry = byDay[day] ?? (0, 0)
            entry.pnl += pnl
            entry.trades += 1
            byDay[day] = entry
        }
        s.currentStreak = streak
        if s.closedTrades > 0 {
            s.winRate = Double(s.wins) / Double(s.closedTrades)
            s.expectancy = (s.grossProfit - s.grossLoss) / Double(s.closedTrades)
        }
        if s.wins > 0 { s.averageWin = s.grossProfit / Double(s.wins) }
        if s.losses > 0 { s.averageLoss = s.grossLoss / Double(s.losses) }
        if s.grossLoss > 0 { s.profitFactor = s.grossProfit / s.grossLoss }
        if holdCount > 0 { s.averageHoldSeconds = holdSum / Double(holdCount) }
        s.days = byDay.map { DayResult(date: $0.key, pnl: $0.value.pnl, trades: $0.value.trades) }.sorted { $0.date < $1.date }

        // Drawdown aus dem Vermoegensverlauf, ersatzweise aus den Trade-Ereignissen.
        let series: [Double]
        if equity.count >= 2 { series = equity.map(\.equity) } else { series = events.filter(\.isTrade).map(\.equityUSDT) }
        var peak = -Double.infinity
        for v in series {
            peak = max(peak, v)
            let dd = peak - v
            if dd > s.maxDrawdownUSDT {
                s.maxDrawdownUSDT = dd
                s.maxDrawdownFraction = peak > 0 ? dd / peak : 0
            }
        }
        return s
    }
}
