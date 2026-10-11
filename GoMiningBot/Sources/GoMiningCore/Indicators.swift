import Foundation

public enum Indicators {
    /// Typische Kursbewegung pro Minute: Median der absoluten Schlusskurs-Aenderungen
    /// der letzten 20 Kerzen in Basispunkten. 0, wenn weniger als 3 Kerzen vorliegen.
    public static func volatilityBps(_ candles: [PriceCandle]) -> Double {
        let n = candles.count
        guard n >= 3 else { return 0 }
        let start = max(1, n - 20)
        var changes: [Double] = []
        changes.reserveCapacity(n - start)
        for i in start..<n {
            let prev = candles[i - 1].close
            guard prev > 0 else { continue }
            changes.append(abs(candles[i].close / prev - 1) * 10_000)
        }
        guard !changes.isEmpty else { return 0 }
        changes.sort()
        return changes[changes.count / 2]
    }

    /// Exponentieller gleitender Durchschnitt der Schlusskurse (Periode in Kerzen).
    /// Rechnet ueber die letzten 3 x Periode Kerzen; nil, wenn weniger als `period` Kerzen vorliegen.
    public static func ema(_ candles: [PriceCandle], period: Int) -> Double? {
        let n = candles.count
        guard period >= 2, n >= period else { return nil }
        let start = max(0, n - period * 3)
        let alpha = 2.0 / Double(period + 1)
        var value = candles[start].close
        var i = start + 1
        while i < n {
            value += alpha * (candles[i].close - value)
            i += 1
        }
        return value
    }

    /// Hoechstes Hoch und tiefstes Tief der letzten `bars` Kerzen.
    public static func highLow(_ candles: [PriceCandle], bars: Int) -> (high: Double, low: Double)? {
        guard !candles.isEmpty else { return nil }
        let start = max(0, candles.count - max(1, bars))
        var high = candles[start].high
        var low = candles[start].low
        var i = start + 1
        while i < candles.count {
            if candles[i].high > high { high = candles[i].high }
            if candles[i].low < low { low = candles[i].low }
            i += 1
        }
        return (high, low)
    }

    /// Anteil des Kaeufer-getriebenen Volumens (nach Wert) in den letzten `window` Sekunden.
    /// nil, wenn weniger als `minTrades` Trades vorliegen.
    public static func marketPressure(_ trades: [PublicTrade], now: Double, window: Double = 60, minTrades: Int = 3) -> Double? {
        var buy = 0.0
        var total = 0.0
        var count = 0
        var i = trades.count - 1
        while i >= 0 {
            let t = trades[i]
            if t.at < now - window { break }
            let value = t.price * t.quantity
            total += value
            if t.buyerInitiated { buy += value }
            count += 1
            i -= 1
        }
        guard count >= minTrades, total > 0 else { return nil }
        return buy / total
    }

    /// Anzahl Trades der letzten `window` Sekunden.
    public static func recentTradeCount(_ trades: [PublicTrade], now: Double, window: Double) -> Int {
        var count = 0
        var i = trades.count - 1
        while i >= 0, now - trades[i].at <= window {
            count += 1
            i -= 1
        }
        return count
    }

    /// Fasst 1-Minuten-Kerzen zu groesseren Kerzen zusammen (z. B. 5, 15, 60 Minuten).
    public static func aggregate(_ candles: [PriceCandle], minutes: Int) -> [PriceCandle] {
        guard minutes > 1, !candles.isEmpty else { return candles }
        let bucket = Double(minutes) * 60
        var result: [PriceCandle] = []
        var current: PriceCandle?
        var currentBucket = -1.0
        for c in candles {
            let b = (c.openedAt / bucket).rounded(.down)
            if var cur = current, b == currentBucket {
                cur.high = max(cur.high, c.high)
                cur.low = min(cur.low, c.low)
                cur.close = c.close
                cur.volume += c.volume
                current = cur
            } else {
                if let cur = current { result.append(cur) }
                currentBucket = b
                current = PriceCandle(openedAt: b * bucket, open: c.open, high: c.high, low: c.low, close: c.close, volume: c.volume)
            }
        }
        if let cur = current { result.append(cur) }
        return result
    }

    /// Fuellt fehlende Minuten mit flachen Kerzen (Schlusskurs der Vorgaengerin, Volumen 0).
    /// Illiquide Maerkte haben Minuten ohne Trade; ohne Auffuellen wuerde der Bot "Luecke in den Kurskerzen" melden.
    public static func fillGaps(_ candles: [PriceCandle], interval: Double = 60, maxGap: Int = 240) -> [PriceCandle] {
        guard candles.count >= 2 else { return candles }
        var result: [PriceCandle] = []
        result.reserveCapacity(candles.count)
        for (i, c) in candles.enumerated() {
            if i > 0 {
                let prev = result[result.count - 1]
                let missing = Int(((c.openedAt - prev.openedAt) / interval).rounded()) - 1
                if missing > 0, missing <= maxGap {
                    for k in 1...missing {
                        result.append(PriceCandle(openedAt: prev.openedAt + interval * Double(k), open: prev.close,
                                                  high: prev.close, low: prev.close, close: prev.close, volume: 0))
                    }
                }
            }
            result.append(c)
        }
        return result
    }

    /// Verlaengert die Serie mit flachen Kerzen bis zur letzten abgeschlossenen Minute (`lastClosedOpen`).
    /// Minuten ohne Trade sind in Wahrheit "kein Kurs, keine Bewegung" - die Boerse liefert dafuer oft keine Kerze.
    public static func extendFlat(_ candles: [PriceCandle], upTo lastClosedOpen: Double, interval: Double = 60, maxGap: Int = 240) -> [PriceCandle] {
        guard let last = candles.last, lastClosedOpen > last.openedAt else { return candles }
        let missing = Int(((lastClosedOpen - last.openedAt) / interval).rounded(.down))
        guard missing > 0, missing <= maxGap else { return candles }
        var result = candles
        result.reserveCapacity(candles.count + missing)
        for k in 1...missing {
            result.append(PriceCandle(openedAt: last.openedAt + interval * Double(k), open: last.close, high: last.close,
                                      low: last.close, close: last.close, volume: 0))
        }
        return result
    }

    /// Fuegt neue Kerzen an eine sortierte Serie an; gleiche Zeitstempel im hinteren Teil werden ersetzt.
    public static func mergeTail(_ series: inout [PriceCandle], _ new: [PriceCandle]) {
        for c in new.sorted(by: { $0.openedAt < $1.openedAt }) {
            guard c.close > 0 else { continue }
            if let last = series.last, c.openedAt <= last.openedAt {
                var i = series.count - 1
                var replaced = false
                while i >= 0, i > series.count - 400 {
                    if series[i].openedAt == c.openedAt { series[i] = c; replaced = true; break }
                    if series[i].openedAt < c.openedAt { break }
                    i -= 1
                }
                if !replaced, c.openedAt < last.openedAt {
                    // Luecke in der Mitte oder weit zurueck: einsortieren.
                    series.append(c)
                    series.sort { $0.openedAt < $1.openedAt }
                }
            } else {
                series.append(c)
            }
        }
    }

    /// Sortiert aufsteigend und entfernt doppelte Zeitstempel (die spaetere Kerze gewinnt).
    public static func normalize(_ candles: [PriceCandle]) -> [PriceCandle] {
        var byTime: [Double: PriceCandle] = [:]
        for c in candles where c.close > 0 && c.openedAt > 0 { byTime[c.openedAt] = c }
        return byTime.values.sorted { $0.openedAt < $1.openedAt }
    }
}

/// Misst die Kursbewegung der letzten Sekunden aus dem Trade-Strom (Basispunkte).
public struct FastMoveDetector: Sendable {
    public static let window: Double = 3
    private var samples: [(at: Double, price: Double)] = []

    public init() {}

    public mutating func add(price: Double, at: Double) {
        guard price > 0 else { return }
        samples.append((at, price))
        if samples.count > 2_000 { samples.removeFirst(samples.count - 1_000) }
    }

    /// Bewegung zwischen erstem und letztem Sample im Fenster; 0 bei weniger als 2 Samples.
    public mutating func value(now: Double) -> Double {
        let cutoff = now - FastMoveDetector.window
        if let firstKeep = samples.firstIndex(where: { $0.at >= cutoff }) {
            if firstKeep > 0 { samples.removeFirst(firstKeep) }
        } else {
            samples.removeAll(keepingCapacity: true)
        }
        guard samples.count >= 2, let first = samples.first, let last = samples.last, first.price > 0 else { return 0 }
        return (last.price - first.price) / first.price * 10_000
    }
}
