import Foundation

/// Annahmen fuer den Kerzen-Backtest. Echte Orderbuecher liegen fuer die Vergangenheit nicht vor;
/// darum wird pro Kerze ein synthetisches Buch mit konstantem Spread und konstanter Tiefe erzeugt.
public struct BacktestConfig: Sendable, Equatable {
    public var spreadBps: Double = 20
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
    /// Replay: Zahl der abgespielten Marktmomente aus dem Protokoll (0 im Kerzen-Backtest).
    public var frameCount = 0

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
    /// `startIndex`/`endIndex` begrenzen den gehandelten Abschnitt; Kerzen davor dienen als Vorlauf.
    public static func run(candles: [PriceCandle], settings rawSettings: BotSettings, config: BacktestConfig,
                           startIndex: Int? = nil, endIndex: Int? = nil, collect: Bool = true,
                           shouldCancel: (() -> Bool)? = nil) -> BacktestResult {
        let settings = rawSettings.clamped()
        var result = BacktestResult()
        result.startingUSDT = settings.startingUSDT
        result.finalEquity = settings.startingUSDT
        let end = min(candles.count, max(0, endIndex ?? candles.count))
        result.candleCount = end
        let start = max(startIndex ?? warmupCandles, 3)
        guard end > start + 1 else { return result }

        result.firstTime = candles[start].openedAt
        result.lastTime = candles[end - 1].openedAt + 60

        var state = BotState.fresh(settings, at: candles[start].openedAt)
        let windowSize = max(windowCandles, settings.requiredCandles)
        var window = Array(candles[max(0, start - windowSize)..<start])
        var seeded = !config.seedStartPosition

        let half = config.spreadBps / 2 / 10_000
        let levelStep = config.levelStepBps / 10_000
        let levels = max(2, config.levelCount)
        var bids = [PriceLevel](repeating: PriceLevel(price: 0, quantity: 0), count: levels)
        var asks = bids

        var peak = settings.startingUSDT
        var curveStride = 1
        if collect { curveStride = max(1, (end - start) / 600) }
        var firstAsk = 0.0
        var lastBid = 0.0
        var seedEvent: BotEvent?

        for i in start..<end {
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
                tally(r, into: &result, collect: collect)
            }
            // Kerze abgeschlossen.
            window.append(c)
            if window.count > windowSize { window.removeFirst(window.count - windowSize) }
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

        let finalBid = lastBid > 0 ? lastBid : candles[end - 1].close
        finish(&result, state: state, settings: settings, firstAsk: firstAsk, finalBid: finalBid)
        return result
    }

    /// Endvermoegen, Gebuehren und Vergleich mit reinem Halten (Kauf zum ersten Ask, Verkauf zum letzten Bid).
    static func finish(_ result: inout BacktestResult, state: BotState, settings: BotSettings, firstAsk: Double, finalBid: Double) {
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
    }

    /// Wertet ein Engine-Ergebnis fuer die Statistik aus.
    static func tally(_ r: StepResult, into result: inout BacktestResult, collect: Bool) {
        guard let e = r.event else { return }
        if e.isSell {
            result.sells += 1
            if e.realizedPnLUSDT > 0 { result.wins += 1; result.grossProfit += e.realizedPnLUSDT }
            else { result.grossLoss += -e.realizedPnLUSDT }
        } else {
            result.buys += 1
        }
        if collect { result.events.append(e) }
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
        guard value.isFinite else { return }
        switch self {
        case .minNetProfitBps: s.minNetProfitBps = value
        case .stopLossFraction: s.stopLossFraction = value
        case .maxTradeUSDT: s.maxTradeUSDT = value
        case .gridDropBps: s.gridDropBps = value
        case .maxOpenPositions: s.maxOpenPositions = Int(min(50, max(1, value.rounded())))
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
    /// Ergebnisse in aufeinanderfolgenden Zeitabschnitten, jeweils mit frischem Konto (Walk-forward).
    public var segments: [BacktestResult] = []

    /// Zahl der Abschnitte mit Gewinn.
    public var positiveSegments: Int { segments.reduce(0) { $0 + ($1.netPnL > 0 ? 1 : 0) } }

    /// Robustheit 0...1: Anteil der Abschnitte im Plus.
    public var robustness: Double { segments.isEmpty ? 0 : Double(positiveSegments) / Double(segments.count) }

    /// Durchschnittliche Rendite je Abschnitt.
    public var meanSegmentReturn: Double {
        segments.isEmpty ? 0 : segments.reduce(0) { $0 + $1.returnFraction } / Double(segments.count)
    }

    /// Schlechtester Abschnitt (Rendite).
    public var worstSegmentReturn: Double? { segments.map(\.returnFraction).min() }

    /// Uebernehmen ist nur erlaubt, wenn die Kombination auf den nicht zur Auswahl benutzten Testdaten im Plus liegt.
    public var passesTest: Bool { (test?.netPnL ?? 0) > 0 }
}

/// Wie die Ergebnisliste sortiert wird.
public enum OptimizerRanking: String, CaseIterable, Sendable, Identifiable {
    case training = "Training"
    case robustness = "Robustheit"
    public var id: String { rawValue }
}

/// Ein Schritt der Walk-forward-Pruefung: Auswahl nur mit den Abschnitten davor, Bewertung im naechsten.
public struct WalkForwardStep: Sendable {
    /// Index des bewerteten Abschnitts (ab 1; Abschnitt 0 dient nur der ersten Auswahl).
    public var segment: Int
    public var entryID: Int
    public var values: [Double]
    public var result: BacktestResult
}

public struct WalkForwardSummary: Sendable {
    public var segmentCount: Int
    public var steps: [WalkForwardStep]
    /// Beginn und Ende der Abschnitte (Unix-Zeit).
    public var segmentStarts: [Double]
    public var segmentEnds: [Double]

    /// Ergebnis ausserhalb der Stichprobe: Summe der Abschnitte, die jeweils mit der vorher besten Kombination
    /// gehandelt wurden. Die ehrlichste Schaetzung dafuer, was der Optimierer wirklich bringt.
    public var outOfSamplePnL: Double { steps.reduce(0) { $0 + $1.result.netPnL } }
    public var positiveSteps: Int { steps.reduce(0) { $0 + ($1.result.netPnL > 0 ? 1 : 0) } }
}

public struct OptimizerReport: Sendable {
    public var entries: [OptimizerEntry]
    public var walkForward: WalkForwardSummary?
}

public enum Optimizer {
    public static let maxCombinations = 600
    /// Standardzahl der Zeitabschnitte fuer Robustheit und Walk-forward.
    public static let defaultSegments = 4
    /// Jeder Abschnitt braucht mindestens so viele Kerzen (3 Stunden).
    static let minSegmentCandles = 180

    public static func combinations(_ axes: [OptimizerAxis]) -> [[Double]] {
        var combos: [[Double]] = [[]]
        for axis in axes where !axis.values.isEmpty {
            var next: [[Double]] = []
            for c in combos { for v in axis.values { next.append(c + [v]) } }
            combos = next
        }
        return combos
    }

    /// Teilt die gehandelten Kerzen (nach dem Vorlauf) in `count` gleich lange, aufeinanderfolgende Abschnitte.
    public static func segmentRanges(candleCount n: Int, count: Int) -> [Range<Int>] {
        let first = Backtester.warmupCandles
        guard count >= 2, n - first >= count * minSegmentCandles else { return [] }
        let size = (n - first) / count
        return (0..<count).map { i in
            let lo = first + i * size
            return lo..<(i == count - 1 ? n : lo + size)
        }
    }

    /// Sortiert nach Trainings-Score oder nach Robustheit (Abschnitte im Plus, dann Durchschnittsrendite).
    public static func ranked(_ entries: [OptimizerEntry], by ranking: OptimizerRanking, objective: BacktestObjective) -> [OptimizerEntry] {
        switch ranking {
        case .training:
            return entries.sorted { $0.train.score(objective) > $1.train.score(objective) }
        case .robustness:
            return entries.sorted { a, b in
                if a.positiveSegments != b.positiveSegments { return a.positiveSegments > b.positiveSegments }
                if a.passesTest != b.passesTest { return a.passesTest }
                return a.meanSegmentReturn > b.meanSegmentReturn
            }
        }
    }

    /// Walk-forward: Fuer jeden Abschnitt ab dem zweiten wird die Kombination gewaehlt, die in allen Abschnitten
    /// davor im Mittel am besten war, und ihr Ergebnis im Abschnitt selbst gezaehlt.
    public static func walkForward(_ entries: [OptimizerEntry], objective: BacktestObjective, segmentStarts: [Double],
                                   segmentEnds: [Double]) -> WalkForwardSummary? {
        guard let count = entries.first?.segments.count, count >= 2,
              entries.allSatisfy({ $0.segments.count == count }) else { return nil }
        var steps: [WalkForwardStep] = []
        for f in 1..<count {
            var best: OptimizerEntry?
            var bestScore = -Double.infinity
            for e in entries {
                var sum = 0.0
                for j in 0..<f { sum += e.segments[j].score(objective) }
                let score = sum / Double(f)
                if score > bestScore || (score == bestScore && (best.map { e.id < $0.id } ?? true)) {
                    bestScore = score
                    best = e
                }
            }
            if let best {
                steps.append(WalkForwardStep(segment: f, entryID: best.id, values: best.values, result: best.segments[f]))
            }
        }
        return WalkForwardSummary(segmentCount: count, steps: steps, segmentStarts: segmentStarts, segmentEnds: segmentEnds)
    }

    /// Rastersuche mit Trainings-/Testaufteilung: Die Kennzahl wird auf den ersten `trainFraction`
    /// der Kerzen optimiert und auf dem Rest gegengeprueft (Schutz vor Ueberanpassung).
    /// Ergebnis: absteigend nach Trainings-Score sortiert.
    public static func run(candles: [PriceCandle], base: BotSettings, config: BacktestConfig, axes: [OptimizerAxis],
                           objective: BacktestObjective, trainFraction: Double,
                           progress: @escaping @Sendable (Int, Int) -> Void) async -> [OptimizerEntry] {
        await runReport(candles: candles, base: base, config: config, axes: axes, objective: objective,
                        trainFraction: trainFraction, segments: 0, progress: progress).entries
    }

    /// Wie `run`, zusaetzlich mit Ergebnissen je Zeitabschnitt (Robustheit) und Walk-forward-Pruefung.
    public static func runReport(candles: [PriceCandle], base: BotSettings, config: BacktestConfig, axes: [OptimizerAxis],
                                 objective: BacktestObjective, trainFraction: Double, segments segmentCount: Int = defaultSegments,
                                 progress: @escaping @Sendable (Int, Int) -> Void) async -> OptimizerReport {
        let activeAxes = axes.filter { !$0.values.isEmpty }
        let combos = Array(combinations(activeAxes).prefix(maxCombinations))
        let total = combos.count
        guard total > 0, candles.count > Backtester.warmupCandles + 20 else { return OptimizerReport(entries: [], walkForward: nil) }

        let split = trainFraction >= 0.99 ? candles.count : max(Backtester.warmupCandles + 10, Int(Double(candles.count) * trainFraction))
        let hasTest = split < candles.count - 30
        let ranges = segmentRanges(candleCount: candles.count, count: segmentCount)

        @Sendable func evaluate(_ index: Int) -> OptimizerEntry {
            var settings = base
            for (axis, value) in zip(activeAxes, combos[index]) { axis.parameter.apply(value, to: &settings) }
            settings = settings.clamped()
            let train = Backtester.run(candles: candles, settings: settings, config: config,
                                       endIndex: hasTest ? split : nil, collect: false, shouldCancel: { Task.isCancelled })
            var test: BacktestResult?
            if hasTest {
                test = Backtester.run(candles: candles, settings: settings, config: config, startIndex: split,
                                      collect: false, shouldCancel: { Task.isCancelled })
            }
            var parts: [BacktestResult] = []
            for range in ranges {
                parts.append(Backtester.run(candles: candles, settings: settings, config: config, startIndex: range.lowerBound,
                                            endIndex: range.upperBound, collect: false, shouldCancel: { Task.isCancelled }))
            }
            return OptimizerEntry(id: index, values: combos[index], settings: settings, train: train, test: test, segments: parts)
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
        let sorted = ranked(entries, by: .training, objective: objective)
        let starts = ranges.map { candles[$0.lowerBound].openedAt }
        let ends = ranges.map { candles[$0.upperBound - 1].openedAt + 60 }
        let summary = Task.isCancelled ? nil : walkForward(sorted, objective: objective, segmentStarts: starts, segmentEnds: ends)
        return OptimizerReport(entries: sorted, walkForward: summary)
    }
}
