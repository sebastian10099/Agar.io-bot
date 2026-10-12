import SwiftUI
import Charts
import GoMiningCore

@MainActor
struct BacktestView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var backtest: BacktestStore
    @EnvironmentObject var bot: BotStore
    @EnvironmentObject var status: StatusStore

    @State private var showTrades = false

    private var busy: Bool { backtest.running || backtest.optimizing }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                introCard
                inputsCard
                if let result = backtest.result { resultCard(result) }
                optimizerCard
            }
            .padding(16)
        }
    }

    // MARK: Einleitung und Eingaben

    private var introCard: some View {
        Card("Backtest", systemImage: "clock.arrow.circlepath") {
            Text("Spielt die aktuellen Einstellungen über die Vergangenheit ab – so siehst du in Sekunden, wie sich die Strategie in den letzten Tagen geschlagen hätte.")
            Text("**Kerzen von BingX:** bis zu 7 Tage 1-Minuten-Kerzen, mit angenommenem Spread und angenommener Orderbuchtiefe (Orderbücher der Vergangenheit gibt es bei BingX nicht). **Marktprotokoll:** die echten Orderbücher und Käuferanteile, die die App selbst alle 5 Sekunden aufgezeichnet hat – realistischer, aber nur für Zeiten, in denen die App lief. Beides ist eine Orientierung, keine Prognose.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var inputsCard: some View {
        Card("Zeitraum & Marktannahmen", systemImage: "slider.horizontal.3") {
            Picker("Datenquelle", selection: $backtest.source) {
                ForEach(BacktestSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 560)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Zeitraum", selection: $backtest.days) {
                        Text("3 Tage").tag(3)
                        Text("7 Tage").tag(7)
                        Text("14 Tage").tag(14)
                        Text("30 Tage").tag(30)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Mit virtuellem Startkauf beginnen", isOn: $backtest.seedStartPosition)
                    Text(sourceHint)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 360, alignment: .leading)
                if backtest.source == .candles {
                    VStack(alignment: .leading, spacing: 6) {
                        SliderRow(title: "Spread", value: $backtest.spreadBps, range: 5...300, step: 5, format: { Fmt.bps($0) },
                                  help: "Abstand zwischen Bid und Ask")
                        SliderRow(title: "Sichtbare Tiefe je Seite", value: $backtest.depthUSDT, range: 200...20_000, step: 100,
                                  format: { "\(Fmt.usdt($0, digits: 0)) USDT" }, help: "Bestimmt, wie große Orders ohne Teilverkauf passen")
                        HStack {
                            Button("Aus Live-Markt übernehmen") { controller.useLiveMarketForBacktest() }
                                .disabled(controller.market.snapshot == nil)
                            Button("Aus Marktprotokoll messen") { controller.measureMarketFromJournal() }
                                .disabled(busy)
                                .help("Typischen Spread und typische Tiefe aus den letzten 7 Tagen des eigenen Protokolls übernehmen")
                        }
                        if let c = backtest.calibration {
                            Text("Gemessen über \(c.samples) Protokolleinträge: Spread typisch \(Fmt.bps(c.medianSpreadBps, digits: 1)), in 90 % der Zeit höchstens \(Fmt.bps(c.p90SpreadBps, digits: 1)); Tiefe typisch \(Fmt.usdt(c.medianDepthUSDT, digits: 0)) USDT je Seite.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Spread, Tiefe und Käuferanteil kommen aus dem Protokoll", systemImage: "checkmark.seal")
                            .font(.callout)
                        Text("Gefüllt wird gegen die zehn besten aufgezeichneten Orderbuchstufen; Lücken (App aus) werden übersprungen. Die Kerzen für die Auslöser stammen aus Protokoll und gespeichertem Verlauf.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !backtest.journalInfo.isEmpty {
                            Text(backtest.journalInfo).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                if backtest.running {
                    Button(role: .cancel) { controller.cancelBacktest() } label: { Label("Abbrechen", systemImage: "stop.fill") }
                } else {
                    Button { controller.runBacktest() } label: { Label("Backtest starten", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
                if backtest.running { ProgressView(value: backtest.progress).frame(width: 160) }
                Text(backtest.message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var sourceHint: String {
        switch backtest.source {
        case .candles:
            return status.historyStatus.isEmpty
                ? "BingX liefert höchstens 7 Tage 1-Minuten-Kerzen; längeren Verlauf sammelt die App selbst, solange sie läuft (bis 45 Tage)."
                : status.historyStatus
        case .journal:
            return "Das Protokoll reicht so weit zurück, wie die App gelaufen ist (Aufbewahrung: Einstellungen → Daten & Wartung)."
        }
    }

    // MARK: Ergebnis

    private func resultCard(_ r: BacktestResult) -> some View {
        Card("Ergebnis", systemImage: "chart.line.uptrend.xyaxis") {
            Text(r.frameCount > 0
                 ? "\(Fmt.dateTime(r.firstTime)) bis \(Fmt.dateTime(r.lastTime)) · \(r.frameCount) Marktmomente aus dem Protokoll · \(Fmt.usdt(r.durationDays, digits: 1)) Tage"
                 : "\(Fmt.dateTime(r.firstTime)) bis \(Fmt.dateTime(r.lastTime)) · \(r.candleCount) Kerzen · \(Fmt.usdt(r.durationDays, digits: 1)) Tage")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 14) {
                Metric(title: "Endvermögen", value: "\(Fmt.usdt(r.finalEquity)) USDT", subtitle: "Start \(Fmt.usdt(r.startingUSDT, digits: 0)) USDT")
                Metric(title: "Ergebnis", value: Fmt.signedUSDT(r.netPnL), subtitle: Fmt.percent(r.returnFraction, digits: 2, signed: true), color: .pnl(r.netPnL))
                Metric(title: "Zum Vergleich: Halten", value: Fmt.percent(r.holdReturnFraction, digits: 2, signed: true),
                       subtitle: r.returnFraction > r.holdReturnFraction ? "Bot besser" : "Halten besser", color: .pnl(r.holdReturnFraction))
                Metric(title: "Käufe / Verkäufe", value: "\(r.buys) / \(r.sells)")
                Metric(title: "Gewinnquote", value: r.sells > 0 ? Fmt.percent(r.winRate, digits: 0) : "—")
                Metric(title: "Profit-Faktor", value: r.profitFactor.map { Fmt.usdt($0) } ?? "—")
                Metric(title: "Max. Rückgang", value: "\(Fmt.usdt(r.maxDrawdownUSDT)) USDT", subtitle: Fmt.percent(r.maxDrawdownFraction, digits: 2),
                       color: r.maxDrawdownUSDT > 0 ? .orange : .secondary)
                Metric(title: "Gebühren", value: "\(Fmt.usdt(r.feesPaid)) USDT")
                Metric(title: "Offene Lose am Ende", value: "\(r.openLotsAtEnd)")
            }
            if r.equityCurve.count > 1 {
                Chart(r.equityCurve) { p in
                    LineMark(x: .value("Zeit", Date(timeIntervalSince1970: p.t)), y: .value("Vermögen", p.equity))
                        .foregroundStyle(Color.accentColor)
                    RuleMark(y: .value("Start", r.startingUSDT))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 220)
            }
            DisclosureGroup("Trades im Backtest (\(r.events.count))", isExpanded: $showTrades) {
                VStack(spacing: 4) {
                    ForEach(r.events.suffix(120).reversed()) { e in
                        HStack {
                            Text(Fmt.dateTime(e.at)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            Text(e.action).frame(width: 80, alignment: .leading)
                            Text("\(Fmt.quantity(e.quantity)) × \(Fmt.price(e.priceUSDT))").monospacedDigit()
                            Spacer()
                            if e.isSell { Text(Fmt.signedUSDT(e.realizedPnLUSDT, digits: 3)).foregroundStyle(Color.pnl(e.realizedPnLUSDT)).monospacedDigit() }
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Optimierer

    private func parameterRow(_ p: OptimizerParameter) -> some View {
        let enabled = backtest.axes[p] != nil
        return HStack {
            Toggle(isOn: Binding(get: { enabled },
                                 set: { on in
                                     if on { backtest.axes[p] = p.suggestedValues.map { String(format: "%g", $0) }.joined(separator: ", ") }
                                     else { backtest.axes[p] = nil }
                                 })) {
                Text(p.title)
            }
            .frame(width: 280, alignment: .leading)
            TextField("Werte, durch Komma getrennt", text: Binding(get: { backtest.axes[p] ?? "" }, set: { backtest.axes[p] = $0 }))
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled)
            Text("jetzt: \(valueText(p, p.current(in: bot.stored.settings)))").font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
        }
    }

    private func valueText(_ p: OptimizerParameter, _ v: Double) -> String {
        switch p {
        case .stopLossFraction: return Fmt.percent(v, digits: 1)
        case .maxOpenPositions: return "\(Int(v))"
        case .minLotDistanceFactor: return Fmt.usdt(v, digits: 1)
        default: return Fmt.usdt(v, digits: 0)
        }
    }

    private var combinationCount: Int {
        let axes = backtest.axes.compactMap { (p, text) -> OptimizerAxis? in
            let values = BacktestStore.parseValues(text)
            return values.isEmpty ? nil : OptimizerAxis(parameter: p, values: values)
        }
        return axes.isEmpty ? 0 : Optimizer.combinations(axes).count
    }

    private var optimizerCard: some View {
        Card("Parameter testen (Optimierer)", systemImage: "wand.and.stars") {
            Text("Probiert Kombinationen auf den Kerzen von BingX durch. **Training** ist der erste Teil der Daten, **Test** der Rest, der nicht zum Auswählen benutzt wurde. **Abschnitte** teilt den Zeitraum in vier Stücke und zählt, in wie vielen die Kombination im Plus war – eine robuste Einstellung gewinnt nicht nur in einem Glücksabschnitt. Übernehmen geht nur, wenn der Test im Plus liegt.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(OptimizerParameter.allCases) { parameterRow($0) }
            }
            HStack(spacing: 20) {
                Picker("Ziel", selection: $backtest.objective) {
                    ForEach(BacktestObjective.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 240)
                Picker("Sortieren", selection: $backtest.ranking) {
                    ForEach(OptimizerRanking.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 220)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Training: \(Fmt.percent(backtest.trainFraction, digits: 0)) · Test: \(Fmt.percent(1 - backtest.trainFraction, digits: 0))").font(.caption)
                    Slider(value: $backtest.trainFraction, in: 0.5...0.9, step: 0.05).frame(width: 200)
                }
                Spacer()
                Text("\(combinationCount) Kombinationen").font(.caption).foregroundStyle(combinationCount > Optimizer.maxCombinations ? Color.red : Color.secondary)
            }
            HStack {
                if backtest.optimizing {
                    Button(role: .cancel) { controller.cancelBacktest() } label: { Label("Abbrechen", systemImage: "stop.fill") }
                    ProgressView(value: backtest.progress).frame(width: 200)
                } else {
                    Button { controller.runOptimizer() } label: { Label("Optimierung starten", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || combinationCount == 0 || combinationCount > Optimizer.maxCombinations)
                }
                if !backtest.running { Text(backtest.message).font(.callout).foregroundStyle(.secondary) }
            }
            if let wf = backtest.walkForward { walkForwardSummary(wf) }
            if !backtest.entries.isEmpty { optimizerTable }
        }
    }

    private func walkForwardSummary(_ wf: WalkForwardSummary) -> some View {
        let pnl = wf.outOfSamplePnL
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Walk-forward-Prüfung", systemImage: "arrow.right.circle").font(.callout.weight(.semibold))
                Spacer()
                Text("außerhalb der Stichprobe: \(Fmt.signedUSDT(pnl))").foregroundStyle(Color.pnl(pnl)).monospacedDigit()
            }
            Text("Für jeden Abschnitt ab dem zweiten wurde die Kombination gewählt, die in den Abschnitten davor am besten war – und dann nur ihr Ergebnis im neuen Abschnitt gezählt. So hätte der Optimierer in Echtzeit abgeschnitten. \(wf.positiveSteps) von \(wf.steps.count) Schritten im Plus.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(wf.steps, id: \.segment) { step in
                HStack {
                    Text("Abschnitt \(step.segment + 1)").frame(width: 90, alignment: .leading)
                    if step.segment < wf.segmentStarts.count {
                        Text("\(Fmt.dateTime(wf.segmentStarts[step.segment])) – \(Fmt.dateTime(wf.segmentEnds[step.segment]))")
                            .foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
                    }
                    Text(labels(step.values)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.signedUSDT(step.result.netPnL)).foregroundStyle(Color.pnl(step.result.netPnL)).monospacedDigit()
                }
                .font(.caption)
            }
            if pnl <= 0 {
                Text("Ergebnis außerhalb der Stichprobe nicht positiv: Auf diesen Daten findet der Optimierer nichts, das hält. Lieber die Standardwerte behalten.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func labels(_ values: [Double]) -> String {
        zip(backtest.optimizerAxesUsed, values).map { "\($0.0.shortTitle) \(valueText($0.0, $0.1))" }.joined(separator: " · ")
    }

    private var optimizerTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#").frame(width: 26, alignment: .leading)
                Text("Parameter").frame(maxWidth: .infinity, alignment: .leading)
                Text("Training").frame(width: 150, alignment: .trailing)
                Text("Test").frame(width: 100, alignment: .trailing)
                Text("Abschnitte").frame(width: 90, alignment: .trailing)
                Text("Trades").frame(width: 56, alignment: .trailing)
                Color.clear.frame(width: 90)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider()
            ForEach(Array(rankedEntries.prefix(15).enumerated()), id: \.element.id) { index, entry in
                optimizerRow(index: index, entry: entry)
            }
        }
    }

    private var rankedEntries: [OptimizerEntry] {
        Optimizer.ranked(backtest.entries, by: backtest.ranking, objective: backtest.objective)
    }

    private func optimizerRow(index: Int, entry: OptimizerEntry) -> some View {
        let test = entry.test
        let segmentColor: Color = entry.segments.isEmpty ? .secondary : (entry.robustness >= 0.75 ? .green : (entry.robustness >= 0.5 ? .orange : .red))
        return HStack {
            Text("\(index + 1)").frame(width: 26, alignment: .leading)
            Text(labels(entry.values)).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(Fmt.signedUSDT(entry.train.netPnL)) (\(Fmt.percent(entry.train.maxDrawdownFraction, digits: 1)) DD)")
                .foregroundStyle(Color.pnl(entry.train.netPnL)).frame(width: 150, alignment: .trailing)
            Group {
                if let test { Text(Fmt.signedUSDT(test.netPnL)).foregroundStyle(Color.pnl(test.netPnL)) } else { Text("—") }
            }
            .frame(width: 100, alignment: .trailing)
            Text(entry.segments.isEmpty ? "—" : "\(entry.positiveSegments)/\(entry.segments.count) im Plus")
                .foregroundStyle(segmentColor)
                .frame(width: 90, alignment: .trailing)
                .help(entry.worstSegmentReturn.map { "Schlechtester Abschnitt: \(Fmt.percent($0, digits: 2, signed: true))" } ?? "")
            Text("\(entry.train.sells)").frame(width: 56, alignment: .trailing)
            Button("Übernehmen") { controller.apply(entry) }
                .controlSize(.small)
                .disabled(!entry.passesTest)
                .help(entry.passesTest ? "Diese Werte in die Einstellungen übernehmen" : "Gesperrt: im Testabschnitt nicht im Plus")
                .frame(width: 90)
        }
        .font(.callout.monospacedDigit())
    }
}

extension OptimizerParameter {
    /// Kurzname fuer die Ergebnistabelle.
    var shortTitle: String {
        switch self {
        case .minNetProfitBps: return "Ziel"
        case .stopLossFraction: return "Stop"
        case .maxTradeUSDT: return "Einsatz"
        case .gridDropBps: return "Abstand"
        case .maxOpenPositions: return "Pos."
        case .minLotDistanceFactor: return "Käufe"
        case .trailingStopBps: return "Trail"
        }
    }
}
