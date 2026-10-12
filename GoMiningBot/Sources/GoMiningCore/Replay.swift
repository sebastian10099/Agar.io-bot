import Foundation

// MARK: - Replay aus dem Marktprotokoll

/// Ein Marktmoment aus dem eigenen Protokoll: echtes Orderbuch (beste Stufen) und Kaeuferanteil.
public struct ReplayFrame: Sendable, Equatable {
    public var t: Double
    /// Bids absteigend, Asks aufsteigend.
    public var bids: [PriceLevel]
    public var asks: [PriceLevel]
    /// Kaeuferanteil der juengsten Trades (0...1), falls bekannt.
    public var share: Double?

    public init(t: Double, bids: [PriceLevel], asks: [PriceLevel], share: Double?) {
        self.t = t
        self.bids = bids
        self.asks = asks
        self.share = share
    }

    public var bid: Double { bids.first?.price ?? 0 }
    public var ask: Double { asks.first?.price ?? 0 }
    public var isValid: Bool { bid > 0 && ask >= bid }
    public var spreadBps: Double {
        let mid = (bid + ask) / 2
        return mid > 0 ? (ask - bid) / mid * 10_000 : 0
    }
    /// Kleinere der beiden sichtbaren Seiten in USDT.
    public var depthUSDT: Double {
        let b = bids.reduce(0) { $0 + $1.price * $1.quantity }
        let a = asks.reduce(0) { $0 + $1.price * $1.quantity }
        return min(a, b)
    }
}

/// Gelesenes Marktprotokoll.
public struct ReplayData: Sendable {
    public var frames: [ReplayFrame] = []
    /// Aus dem Protokoll rekonstruierte 1-Minuten-Kerzen (je Eintrag die zuletzt abgeschlossene Kerze).
    public var candles: [PriceCandle] = []
    public var filesRead = 0
    public var badLines = 0

    public init() {}

    public var firstTime: Double? { frames.first?.t }
    public var lastTime: Double? { frames.last?.t }
    /// Zeitraum zwischen erstem und letztem Eintrag in Tagen.
    public var spanDays: Double { max(0, ((lastTime ?? 0) - (firstTime ?? 0)) / 86_400) }

    /// Abgedeckte Zeit: Summe der Abstaende zwischen Eintraegen, die hoechstens 2 Minuten auseinanderliegen.
    public var coveredHours: Double {
        guard frames.count >= 2 else { return 0 }
        var sum = 0.0
        for i in 1..<frames.count {
            let gap = frames[i].t - frames[i - 1].t
            if gap > 0, gap <= 120 { sum += gap }
        }
        return sum / 3_600
    }

    /// Typische Marktwerte (Median) fuer den Kerzen-Backtest.
    public var calibration: MarketCalibration? { MarketCalibration(frames: frames) }
}

/// Gemessene typische Spreads und Orderbuchtiefen.
public struct MarketCalibration: Sendable, Equatable {
    public var medianSpreadBps: Double
    /// 90 % der Zeit war der Spread hoechstens so gross.
    public var p90SpreadBps: Double
    public var medianDepthUSDT: Double
    public var samples: Int

    public init?(frames: [ReplayFrame]) {
        let valid = frames.filter(\.isValid)
        guard valid.count >= 10 else { return nil }
        let spreads = valid.map(\.spreadBps).sorted()
        let depths = valid.map(\.depthUSDT).sorted()
        func quantile(_ sorted: [Double], _ q: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))]
        }
        medianSpreadBps = quantile(spreads, 0.5)
        p90SpreadBps = quantile(spreads, 0.9)
        medianDepthUSDT = quantile(depths, 0.5)
        samples = valid.count
    }
}

public enum JournalReader {
    /// Liest die Tagesdateien (`yyyy-MM-dd.jsonl`) im Zeitraum `from...to`.
    public static func load(directory: URL, from: Double, to: Double, shouldCancel: (() -> Bool)? = nil) -> ReplayData {
        var data = ReplayData()
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (Int, URL)? in
                guard let day = BotEngine.dayIndex(fromDay: url.deletingPathExtension().lastPathComponent) else { return nil }
                return (day, url)
            }
            .filter { Double($0.0 + 1) * 86_400 > from && Double($0.0) * 86_400 <= to }
            .sorted { $0.0 < $1.0 }
        var candles: [Double: PriceCandle] = [:]
        for (_, url) in urls {
            if shouldCancel?() == true { break }
            guard let raw = try? Data(contentsOf: url) else { continue }
            data.filesRead += 1
            let parsed = parse(raw)
            data.badLines += parsed.badLines
            for (frame, candle) in parsed.rows where frame.t >= from && frame.t <= to {
                data.frames.append(frame)
                if let candle { candles[candle.openedAt] = candle }
            }
        }
        data.frames.sort { $0.t < $1.t }
        data.candles = candles.values.sorted { $0.openedAt < $1.openedAt }
        return data
    }

    /// Zerlegt den Inhalt einer Tagesdatei (eine JSON-Zeile pro Eintrag). Kaputte Zeilen werden uebersprungen.
    public static func parse(_ raw: Data) -> (rows: [(ReplayFrame, PriceCandle?)], badLines: Int) {
        var rows: [(ReplayFrame, PriceCandle?)] = []
        var bad = 0
        // Schnellweg: alle Zeilen als ein JSON-Array lesen.
        if let all = try? JSONSerialization.jsonObject(with: wrapAsArray(raw)) as? [Any] {
            for item in all {
                if let row = row(item) { rows.append(row) } else { bad += 1 }
            }
            return (rows, bad)
        }
        // Eine Zeile ist beschaedigt (z. B. Absturz beim Schreiben): einzeln lesen.
        for line in raw.split(separator: 0x0a) where !line.isEmpty {
            if let item = try? JSONSerialization.jsonObject(with: Data(line)), let row = row(item) {
                rows.append(row)
            } else {
                bad += 1
            }
        }
        return (rows, bad)
    }

    static func wrapAsArray(_ raw: Data) -> Data {
        var out = Data(capacity: raw.count + 2)
        out.append(0x5b)                                   // [
        var first = true
        for line in raw.split(separator: 0x0a) where !line.isEmpty {
            if !first { out.append(0x2c) }                 // ,
            out.append(contentsOf: line)
            first = false
        }
        out.append(0x5d)                                   // ]
        return out
    }

    static func row(_ item: Any) -> (ReplayFrame, PriceCandle?)? {
        guard let dict = item as? [String: Any], let t = number(dict["t"]) else { return nil }
        let bids = levels(dict["bids"])
        let asks = levels(dict["asks"])
        guard !bids.isEmpty, !asks.isEmpty else { return nil }
        var candle: PriceCandle?
        if let c = dict["candle"] as? [Any], c.count >= 6 {
            let v = c.compactMap { number($0) }
            if v.count >= 6, v[4] > 0 {
                candle = PriceCandle(openedAt: v[0], open: v[1], high: v[2], low: v[3], close: v[4], volume: v[5])
            }
        }
        let share = number(dict["share"]).flatMap { (0...1).contains($0) ? $0 : nil }
        return (ReplayFrame(t: t, bids: bids, asks: asks, share: share), candle)
    }

    static func levels(_ any: Any?) -> [PriceLevel] {
        guard let list = any as? [Any] else { return [] }
        var out: [PriceLevel] = []
        out.reserveCapacity(list.count)
        for entry in list {
            guard let pair = entry as? [Any], pair.count >= 2, let p = number(pair[0]), let q = number(pair[1]),
                  p > 0, q > 0 else { continue }
            out.append(PriceLevel(price: p, quantity: q))
        }
        return out
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        if let s = any as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }
}

extension Backtester {
    /// Spielt die Strategie ueber echte Marktmomente aus dem eigenen Protokoll ab: echte Spreads, echte
    /// Orderbuchtiefen (beste zehn Stufen) und der gemessene Kaeuferanteil statt Annahmen.
    /// `candles` liefert den Kerzenverlauf (Protokoll und gespeicherter Verlauf zusammen).
    public static func replay(frames rawFrames: [ReplayFrame], candles: [PriceCandle], settings rawSettings: BotSettings,
                              config: BacktestConfig, collect: Bool = true,
                              shouldCancel: (() -> Bool)? = nil) -> BacktestResult {
        let settings = rawSettings.clamped()
        var result = BacktestResult()
        result.startingUSDT = settings.startingUSDT
        result.finalEquity = settings.startingUSDT
        let frames = rawFrames.filter(\.isValid)
        result.frameCount = frames.count
        guard let first = frames.first, let last = frames.last, frames.count >= 2 else { return result }
        result.firstTime = first.t
        result.lastTime = last.t

        var state = BotState.fresh(settings, at: first.t)
        let windowSize = max(windowCandles, settings.requiredCandles)
        var closedCount = 0
        var windowFor = -1
        var window: [PriceCandle] = []
        var seeded = !config.seedStartPosition
        var peak = settings.startingUSDT
        let curveStride = collect ? max(1, frames.count / 600) : Int.max
        var usedCandles = 0

        for (n, f) in frames.enumerated() {
            if let cancel = shouldCancel, n % 512 == 0, cancel() { result.cancelled = true; break }
            while closedCount < candles.count, candles[closedCount].openedAt + 60 <= f.t { closedCount += 1 }
            if closedCount != windowFor {
                window = Array(candles[max(0, closedCount - windowSize)..<closedCount])
                windowFor = closedCount
                usedCandles = max(usedCandles, closedCount)
            }
            let snap = MarketSnapshot(receivedAt: f.t, bookAt: f.t, candles: window, asks: f.asks, bids: f.bids,
                                      rules: config.rules, trades: [], tradeDataAvailable: false,
                                      pressureHint: f.share ?? pressureHint(window))
            if !seeded {
                seeded = true
                if let e = BotEngine.seedReferencePosition(snap, state: &state, settings: settings,
                                                           budgetUSDT: settings.startingUSDT, now: f.t) {
                    result.buys += 1
                    if collect { result.events.append(e) }
                }
            }
            let r = BotEngine.step(snap, state: &state, settings: settings, fastMoveBps: 0, now: f.t, verbose: false)
            tally(r, into: &result, collect: collect)

            let equity = state.equity(atBid: f.bid)
            if equity > peak { peak = equity }
            let dd = peak - equity
            if dd > result.maxDrawdownUSDT {
                result.maxDrawdownUSDT = dd
                result.maxDrawdownFraction = peak > 0 ? dd / peak : 0
            }
            if collect, n % curveStride == 0 || n == frames.count - 1 {
                result.equityCurve.append(EquityPoint(t: f.t, equity: equity))
            }
        }
        result.candleCount = usedCandles
        finish(&result, state: state, settings: settings, firstAsk: first.ask, finalBid: last.bid)
        return result
    }
}
