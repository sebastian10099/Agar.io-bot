import Foundation

/// Annahmen fuer den Kerzen-Backtest. Echte Orderbuecher liegen fuer die Vergangenheit nicht vor;
/// darum wird pro Kerze ein synthetisches Buch mit konstantem Spread und konstanter Tiefe erzeugt.
public struct BacktestConfig: Sendable, Equatable {
    public var spreadBps: Double = 40
    /// Sichtbare Tiefe pro Seite in USDT (ueber alle Stufen).
    public var depthUSDT: Double = 3_000
    public var levelCount: Int = 10
    /// Abstand der Orderbuchstufen in bp.
    public var levelStepBps: Double = 15
    public var seedStartPosition: Bool = false
    public var rules: SymbolRules = SymbolRules(minQuantity: 0, minNotional: 5, stepSize: 0.0001, verified: false)

    public init() {}
}

public struct BacktestResult: Sendable {
    public var startingUSDT: Double = 0
    public var finalEquity: Double = 0
    public var netPnL: Double { finalEquity - startingUSDT }
    public var returnFraction: Double { startingUSDT > 0 ? netPnL / startingUSDT : 0 }
    /// Wertentwicklung bei reinem Halten (nach Kaufkosten), als Anteil.
    public var holdReturnFraction: Double = 0
    public var buys = 0
    public var sells = 0
    public var wins = 0
    public var grossProfit: Double = 0
    public var grossLoss: Double = 0
    public var winRate: Double { sells > 0 ? Double(wins) / Double(sells) : 0 }
    public var profitFactor: Double? { grossLoss > 0 ? grossProfit / grossLoss : nil }
    public var maxDrawdownUSDT: Double = 0
    public var maxDrawdownFraction: Double = 0
    public var feesPaid: Double = 0
    public var openLotsAtEnd = 0
    public var candleCount = 0
    public var firstTime: Double = 0
    public var lastTime: Double = 0
    public var equityCurve: [EquityPoint] = []
    public var events: [BotEvent] = []
    public var cancelled = false

    public init() {}

    public var durationDays: Double { max(0, (lastTime - firstTime) / 86_400) }

    /// Vergleichszahl fuer die Optimierung.
    public func score(_ objective: BacktestObjective) -> Double {
        switch objective {
        case .netProfit:
            return netPnL
        case .riskAdjusted:
            // Gewinn im Verhaeltnis zum schlimmsten Rueckgang (mindestens 0,5 % des Startkapitals).
            return netPnL / max(startingUSDT * 0.005, maxDrawdownUSDT)
        }
    }
}

public enum BacktestObjective: String, CaseIterable, Sendable, Identifiable {
    case netProfit = "Nettogewinn"
    case riskAdjusted = "Risikobereinigt"
    public var id: String { rawValue }
}

public enum Backtester {
    /// Kerzen, die der Engine vor dem ersten Handel als Vorlauf dienen.
    public static let warmupCandles = 30
    /// Laenge des Kerzenfensters, das die Engine sieht (deckt das 60-Minuten-Fenster ab).
    public static let windowCandles = 130
    static let ticksPerCandle = 4

    /// Spielt die Strategie ueber die Kerzen ab. Pro Kerze werden vier Kurspunkte durchlaufen
    /// (bei gruenen Kerzen Open-Low-High-Close, bei roten Open-High-Low-Close), damit Stop-Loss
    /// und Ziele innerhalb einer Kerze realistisch in der unguenstigeren Reihenfolge ausgeloest werden.
    public static func run(candles: [PriceCandle], settings rawSettings: BotSettings, config: BacktestConfig,
                           startIndex: Int? = nil, collect: Bool = true,
                           shouldCancel: (() -> Bool)? = nil) -> BacktestResult {
        let settings = rawSettings.clamped()
        var result = BacktestResult()
        result.startingUSDT = settings.startingUSDT
        result.finalEquity = settings.startingUSDT
        result.candleCount = candles.count
        let start = max(startIndex ?? warmupCandles, 3)
        guard candles.count > start + 1 else { return result }

        result.firstTime = candles[start].openedAt
        result.lastTime = candles[candles.count - 1].openedAt + 60

        var state = BotState.fresh(settings, at: candles[start].openedAt)
        var window = Array(candles[max(0, start - windowCandles)..<start])
        var seeded = !config.seedStartPosition

        let half = config.spreadBps / 2 / 10_000
        let levelStep = config.levelStepBps / 10_000
        let levels = max(2, config.levelCount)
        var bids = [PriceLevel](repeating: PriceLevel(price: 0, quantity: 0), count: levels)
        var asks = bids

        var peak = settings.startingUSDT
        var curveStride = 1
        if collect { curveStride = max(1, (candles.count - start) / 600) }
        var firstAsk = 0.0
        var lastBid = 0.0
        var seedEvent: BotEvent?

        for i in start..<candles.count {
            if let cancel = shouldCancel, i % 256 == 0, cancel() { result.cancelled = true; break }
            let c = candles[i]
            for k in 0..<ticksPerCandle {
                let price: Double
                switch k {
                case 0: price = c.open
                case 1: price = c.isGreen ? c.low : c.high
                case 2: price = c.isGreen ? c.high : c.low
                default: price = c.close
                }
                let t = c.openedAt + 60 * Double(k + 1) / Double(ticksPerCandle + 1)
                for l in 0..<levels {
                    let offset = half + levelStep * Double(l)
                    let bp = price * (1 - offset)
                    let ap = price * (1 + offset)
                    let perLevel = config.depthUSDT / Double(levels)
                    bids[l] = PriceLevel(price: bp, quantity: perLevel / bp)
                    asks[l] = PriceLevel(price: ap, quantity: perLevel / ap)
                }
                let snap = MarketSnapshot(receivedAt: t, bookAt: t, candles: window, asks: asks, bids: bids,
                                          rules: config.rules, trades: [], tradeDataAvailable: false,
                                          pressureHint: pressureHint(window))
                if firstAsk == 0 { firstAsk = asks[0].price }
                lastBid = bids[0].price

                if !seeded {
                    seedEvent = BotEngine.seedReferencePosition(snap, state: &state, settings: settings,
                                                                budgetUSDT: settings.startingUSDT, now: t)
                    seeded = true
                    if let e = seedEvent {
                        result.buys += 1
                        if collect { result.events.append(e) }
                    }
                }

                let r = BotEngine.step(snap, state: &state, settings: settings, fastMoveBps: 0, now: t, verbose: false)
                if let e = r.event {
                    if e.isSell {
                        result.sells += 1
                        if e.realizedPnLUSDT > 0 { result.wins += 1; result.grossProfit += e.realizedPnLUSDT }
                        else { result.grossLoss += -e.realizedPnLUSDT }
                    } else {
                        result.buys += 1
                    }
                    if collect { result.events.append(e) }
                }
            }
            // Kerze abgeschlossen.
            window.append(c)
            if window.count > windowCandles { window.removeFirst(window.count - windowCandles) }
            let closeBid = c.close * (1 - half)
            let equity = state.equity(atBid: closeBid)
            if equity > peak { peak = equity }
            let dd = peak - equity
            if dd > result.maxDrawdownUSDT {
                result.maxDrawdownUSDT = dd
                result.maxDrawdownFraction = peak > 0 ? dd / peak : 0
            }
            if collect, (i - start) % curveStride == 0 {
                result.equityCurve.append(EquityPoint(t: c.openedAt + 60, equity: equity))
            }
        }

        let finalBid = lastBid > 0 ? lastBid : candles[candles.count - 1].close
        result.finalEquity = state.equity(atBid: finalBid)
        result.feesPaid = state.totalFeesUSDT
        result.openLotsAtEnd = state.lots.count
        if firstAsk > 0 {
            let feeRate = settings.feeBps / 10_000
            let slip = settings.slippageBps / 10_000
            let bought = settings.startingUSDT / (firstAsk * (1 + slip) * (1 + feeRate))
            let heldValue = bought * finalBid * (1 - slip) * (1 - feeRate)
            result.holdReturnFraction = (heldValue - settings.startingUSDT) / settings.startingUSDT
        }
        return result
    }

    /// Ersatz fuer den Kaeuferanteil: wo schliessen die letzten drei Kerzen in ihrer Spanne?
    static func pressureHint(_ window: [PriceCandle]) -> Double? {
        guard window.count >= 3 else { return nil }
        var sum = 0.0
        for c in window.suffix(3) {
            let range = c.high - c.low
            sum += range > 0 ? (c.close - c.low) / range : 0.5
        }
        return sum / 3
    }
}

// MARK: - Parameteroptimierung

public enum OptimizerParameter: String, CaseIterable, Sendable, Identifiable, Hashable {
    case minNetProfitBps, stopLossFraction, maxTradeUSDT, gridDropBps, maxOpenPositions, minLotDistanceFactor, trailingStopBps

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .minNetProfitBps: return "Mindest-Nettoziel (bp)"
        case .stopLossFraction: return "Stop-Loss (Anteil)"
        case .maxTradeUSDT: return "Einsatz je Position (USDT)"
        case .gridDropBps: return "Max. Kaufabstand (bp)"
        case .maxOpenPositions: return "Gleichzeitige Positionen"
        case .minLotDistanceFactor: return "Abstand zwischen Käufen (Faktor)"
        case .trailingStopBps: return "Trailing-Stop (bp, 0 = aus)"
        }
    }

    /// Vorschlagswerte fuer die Rastersuche.
    public var suggestedValues: [Double] {
        switch self {
        case .minNetProfitBps: return [30, 50, 80, 120]
        case .stopLossFraction: return [0.02, 0.03, 0.05]
        case .maxTradeUSDT: return [25, 50, 100]
        case .gridDropBps: return [100, 160, 250]
        case .maxOpenPositions: return [4, 6, 10]
        case .minLotDistanceFactor: return [0, 0.5, 1]
        case .trailingStopBps: return [0, 60, 120]
        }
    }

    public func apply(_ value: Double, to s: inout BotSettings) {
        switch self {
        case .minNetProfitBps: s.minNetProfitBps = value
        case .stopLossFraction: s.stopLossFraction = value
        case .maxTradeUSDT: s.maxTradeUSDT = value
        case .gridDropBps: s.gridDropBps = value
        case .maxOpenPositions: s.maxOpenPositions = Int(value.rounded())
        case .minLotDistanceFactor: s.minLotDistanceFactor = value
        case .trailingStopBps: s.trailingStopBps = value
        }
    }

    public func current(in s: BotSettings) -> Double {
        switch self {
        case .minNetProfitBps: return s.minNetProfitBps
        case .stopLossFraction: return s.stopLossFraction
        case .maxTradeUSDT: return s.maxTradeUSDT
        case .gridDropBps: return s.gridDropBps
        case .maxOpenPositions: return Double(s.openPositionLimit)
        case .minLotDistanceFactor: return s.minLotDistanceFactor
        case .trailingStopBps: return s.trailingStopBps
        }
    }
}

public struct OptimizerAxis: Sendable, Hashable {
    public var parameter: OptimizerParameter
    public var values: [Double]

    public init(parameter: OptimizerParameter, values: [Double]) {
        self.parameter = parameter
        self.values = values
    }
}

public struct OptimizerEntry: Sendable, Identifiable {
    public var id: Int
    public var values: [Double]
    public var settings: BotSettings
    public var train: BacktestResult
    public var test: BacktestResult?
}

public enum Optimizer {
    public static let maxCombinations = 600

    public static func combinations(_ axes: [OptimizerAxis]) -> [[Double]] {
        var combos: [[Double]] = [[]]
        for axis in axes where !axis.values.isEmpty {
            var next: [[Double]] = []
            for c in combos { for v in axis.values { next.append(c + [v]) } }
            combos = next
        }
        return combos
    }

    /// Rastersuche mit Trainings-/Testaufteilung: Die Kennzahl wird auf den ersten `trainFraction`
    /// der Kerzen optimiert und auf dem Rest gegengeprueft (Schutz vor Ueberanpassung).
    /// Ergebnis: absteigend nach Trainings-Score sortiert.
    public static func run(candles: [PriceCandle], base: BotSettings, config: BacktestConfig, axes: [OptimizerAxis],
                           objective: BacktestObjective, trainFraction: Double,
                           progress: @escaping @Sendable (Int, Int) -> Void) async -> [OptimizerEntry] {
        let activeAxes = axes.filter { !$0.values.isEmpty }
        let combos = Array(combinations(activeAxes).prefix(maxCombinations))
        let total = combos.count
        guard total > 0, candles.count > Backtester.warmupCandles + 20 else { return [] }

        let split = trainFraction >= 0.99 ? candles.count : max(Backtester.warmupCandles + 10, Int(Double(candles.count) * trainFraction))
        let hasTest = split < candles.count - 30
        let trainCandles = hasTest ? Array(candles[0..<split]) : candles

        func evaluate(_ index: Int) -> OptimizerEntry {
            var settings = base
            for (axis, value) in zip(activeAxes, combos[index]) { axis.parameter.apply(value, to: &settings) }
            settings = settings.clamped()
            let train = Backtester.run(candles: trainCandles, settings: settings, config: config, collect: false,
                                       shouldCancel: { Task.isCancelled })
            var test: BacktestResult?
            if hasTest {
                test = Backtester.run(candles: candles, settings: settings, config: config, startIndex: split,
                                      collect: false, shouldCancel: { Task.isCancelled })
            }
            return OptimizerEntry(id: index, values: combos[index], settings: settings, train: train, test: test)
        }

        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        var entries: [OptimizerEntry] = []
        entries.reserveCapacity(total)
        await withTaskGroup(of: OptimizerEntry?.self) { group in
            var next = 0
            var done = 0
            func submit() {
                guard next < total else { return }
                let index = next
                next += 1
                group.addTask {
                    if Task.isCancelled { return nil }
                    return evaluate(index)
                }
            }
            for _ in 0..<min(workers, total) { submit() }
            while let finished = await group.next() {
                done += 1
                if let entry = finished, !entry.train.cancelled { entries.append(entry) }
                progress(done, total)
                if Task.isCancelled { group.cancelAll() } else { submit() }
            }
        }
        return entries.sorted { $0.train.score(objective) > $1.train.score(objective) }
    }
}
