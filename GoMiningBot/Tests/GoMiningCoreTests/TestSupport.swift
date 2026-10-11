import XCTest
@testable import GoMiningCore

/// Gemeinsame Bausteine fuer die Tests: ein deterministischer Markt.
enum Fixture {
    /// Mittwoch, 2026-10-14 12:00:00 UTC (ausserhalb des Miner-Wars-Fensters am Dienstag).
    static var now: Double { Double(BotEngine.dayIndex(fromDay: "2026-10-14")!) * 86_400 + 12 * 3_600 }

    static let rules = SymbolRules(minQuantity: 0, minNotional: 2, stepSize: 0.01)

    /// Ruhige Kerzen um `price`, die letzte schliesst 10 Sekunden vor `now`.
    static func candles(price: Double = 1.0, count: Int = 40, now: Double = Fixture.now) -> [PriceCandle] {
        let lastOpen = now - 70
        return (0..<count).map { i in
            let t = lastOpen - Double(count - 1 - i) * 60
            let close = i % 2 == 0 ? price : price * 1.0005
            let open = i % 2 == 0 ? price * 1.0005 : price
            return PriceCandle(openedAt: t, open: open, high: max(open, close) * 1.0002, low: min(open, close) * 0.9998,
                               close: close, volume: 100)
        }
    }

    /// Zehn Trades in den letzten 30 Sekunden, `buyers` davon vom Kaeufer ausgeloest.
    static func trades(price: Double, buyers: Int = 7, now: Double = Fixture.now) -> [PublicTrade] {
        (0..<10).map { i in
            PublicTrade(id: Int64(1_000 + i), at: now - 30 + Double(i) * 3, price: price, quantity: 100, buyerInitiated: i < buyers)
        }
    }

    /// Orderbuch mit `levels` Stufen und viel Tiefe. `mid` ist die Buchmitte, `spreadBps` der Abstand.
    static func snapshot(mid: Double, spreadBps: Double = 20, candles: [PriceCandle]? = nil,
                         trades: [PublicTrade]? = nil, now: Double = Fixture.now, bookAge: Double = 1,
                         tradesAvailable: Bool = true) -> MarketSnapshot {
        let bid = mid * (1 - spreadBps / 20_000)
        let ask = mid * (1 + spreadBps / 20_000)
        let bids = (0..<5).map { PriceLevel(price: bid * (1 - Double($0) * 0.0005), quantity: 10_000) }
        let asks = (0..<5).map { PriceLevel(price: ask * (1 + Double($0) * 0.0005), quantity: 10_000) }
        return MarketSnapshot(receivedAt: now, bookAt: now - bookAge, candles: candles ?? self.candles(now: now),
                              asks: asks, bids: bids, rules: rules, trades: trades ?? self.trades(price: mid, now: now),
                              tradeDataAvailable: tradesAvailable)
    }

    static func settings(_ edit: (inout BotSettings) -> Void = { _ in }) -> BotSettings {
        var s = BotSettings()
        s.minSecondsBetweenTrades = 0
        edit(&s)
        return s
    }

    /// Eine einfache Sinuswelle (Periode 90 Minuten, Amplitude 3 %) mit deterministischem Rauschen.
    static func sineCandles(count: Int, start: Double = 1_760_000_000, base: Double = 1.0) -> [PriceCandle] {
        var seed: UInt64 = 42
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 0.0006
        }
        var prev = base
        return (0..<count).map { i in
            let t = (start / 60).rounded(.down) * 60 + Double(i) * 60
            let price = base * (1 + 0.03 * sin(2 * .pi * Double(i) / 90)) * (1 + noise())
            let open = prev
            prev = price
            return PriceCandle(openedAt: t, open: open, high: max(open, price) * 1.0004, low: min(open, price) * 0.9996,
                               close: price, volume: 50)
        }
    }
}
