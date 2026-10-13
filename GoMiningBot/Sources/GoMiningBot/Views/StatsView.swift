import SwiftUI
import Charts
import GoMiningCore

@MainActor
struct StatsView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var bot: BotStore
    @EnvironmentObject var market: MarketStore
    @State private var reportKind = ReportKind.today

    private var stats: PerformanceStats { bot.stats }

    /// Hoechstens ~600 Punkte zeichnen.
    private var curve: [EquityPoint] {
        let all = bot.equityHistory
        guard all.count > 600 else { return all }
        let stride = all.count / 600 + 1
        var thinned: [EquityPoint] = []
        for (i, p) in all.enumerated() where i % stride == 0 { thinned.append(p) }
        if let last = all.last, thinned.last != last { thinned.append(last) }
        return thinned
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summary
                reportCard
                equityCard
                dailyCard
            }
            .padding(16)
        }
    }

    private var summary: some View {
        Card("Auswertung", systemImage: "chart.bar.doc.horizontal") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 14) {
                Metric(title: "Abgeschlossene Trades", value: "\(stats.closedTrades)", subtitle: "\(stats.wins) Gewinne · \(stats.losses) Verluste")
                Metric(title: "Gewinnquote", value: stats.closedTrades > 0 ? Fmt.percent(stats.winRate, digits: 0) : "—")
                Metric(title: "Profit-Faktor", value: stats.profitFactor.map { Fmt.usdt($0) } ?? "—",
                       subtitle: "Gewinne ÷ Verluste", color: (stats.profitFactor ?? 0) >= 1 ? .green : .secondary)
                Metric(title: "Erwartung je Trade", value: Fmt.signedUSDT(stats.expectancy, digits: 4), subtitle: "USDT", color: .pnl(stats.expectancy))
                Metric(title: "Ø Gewinn", value: Fmt.signedUSDT(stats.averageWin, digits: 4), subtitle: "USDT", color: .pnl(stats.averageWin))
                Metric(title: "Ø Verlust", value: stats.averageLoss > 0 ? Fmt.signedUSDT(-stats.averageLoss, digits: 4) : "—", subtitle: "USDT",
                       color: stats.averageLoss > 0 ? .red : .secondary)
                Metric(title: "Bester / schlechtester Trade", value: "\(Fmt.signedUSDT(stats.bestTrade, digits: 2)) / \(Fmt.signedUSDT(stats.worstTrade, digits: 2))")
                Metric(title: "Ø Haltedauer", value: stats.averageHoldSeconds.map { Fmt.duration($0) } ?? "—")
                Metric(title: "Max. Rückgang (Drawdown)", value: "\(Fmt.usdt(stats.maxDrawdownUSDT)) USDT",
                       subtitle: Fmt.percent(stats.maxDrawdownFraction, digits: 2), color: stats.maxDrawdownUSDT > 0 ? .orange : .secondary)
                Metric(title: "Gebühren gesamt", value: "\(Fmt.usdt(bot.stored.state.totalFeesUSDT)) USDT")
                Metric(title: "Käufe", value: "\(stats.buyCount)")
                Metric(title: "Aktuelle Serie", value: stats.currentStreak == 0 ? "—" : (stats.currentStreak > 0 ? "\(stats.currentStreak) Gewinne" : "\(-stats.currentStreak) Verluste"),
                       color: .pnl(Double(stats.currentStreak)))
            }
        }
    }

    private var reportCard: some View {
        let r = controller.report(reportKind)
        return Card("Bericht", systemImage: "doc.richtext",
                    trailing: AnyView(Picker("Zeitraum", selection: $reportKind) {
                        ForEach(ReportKind.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 300))) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 14) {
                Metric(title: "Vermögen", value: r.equityChange.map { Fmt.signedUSDT($0) } ?? "—",
                       subtitle: r.equityChangeFraction.map { Fmt.percent($0, digits: 2, signed: true) } ?? "noch kein Verlauf",
                       color: Color.pnl(r.equityChange ?? 0))
                Metric(title: "Zum Vergleich: Halten", value: r.holdChangeFraction.map { Fmt.percent($0, digits: 2, signed: true) } ?? "—",
                       subtitle: "nur mit Startkauf", color: Color.pnl(r.holdChangeFraction ?? 0))
                Metric(title: "Realisiert", value: Fmt.signedUSDT(r.realizedPnL), subtitle: "USDT", color: .pnl(r.realizedPnL))
                Metric(title: "Käufe / Verkäufe", value: "\(r.buys) / \(r.sells)",
                       subtitle: r.winRate.map { "Gewinnquote \(Fmt.percent($0, digits: 0))" } ?? "")
                Metric(title: "Gebühren", value: "\(Fmt.usdt(r.fees)) USDT")
            }
            HStack {
                Button { controller.exportReport(reportKind) } label: { Label("Als HTML-Bericht speichern …", systemImage: "square.and.arrow.down") }
                Text("Mit Vermögensverlauf, allen Trades und den Einstellungen; im Browser auch als PDF druckbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var equityCard: some View {
        Card("Vermögensverlauf", systemImage: "chart.line.uptrend.xyaxis") {
            if curve.count < 2 {
                EmptyHint(text: "Der Verlauf füllt sich, sobald die App eine Weile läuft (ein Punkt pro Minute).", systemImage: "chart.line.uptrend.xyaxis")
            } else {
                Chart {
                    ForEach(curve) { p in
                        LineMark(x: .value("Zeit", Date(timeIntervalSince1970: p.t)), y: .value("Vermögen", p.equity), series: .value("Reihe", "Bot"))
                            .foregroundStyle(Color.accentColor)
                    }
                    ForEach(curve.filter { $0.hold != nil }) { p in
                        LineMark(x: .value("Zeit", Date(timeIntervalSince1970: p.t)), y: .value("Vermögen", p.hold ?? 0), series: .value("Reihe", "Halten"))
                            .foregroundStyle(Color.orange.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    }
                    RuleMark(y: .value("Start", bot.stored.settings.startingUSDT))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 260)
                Text("Blau = Bot · orange gestrichelt = unverändert halten (nur mit Startkauf) · grau = Startkapital")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dailyCard: some View {
        Card("Ergebnis je Tag (realisiert)", systemImage: "calendar") {
            if stats.days.isEmpty {
                EmptyHint(text: "Noch keine abgeschlossenen Verkäufe", systemImage: "calendar")
            } else {
                Chart(stats.days) { day in
                    BarMark(x: .value("Tag", day.date, unit: .day), y: .value("Ergebnis", day.pnl))
                        .foregroundStyle(day.pnl >= 0 ? Color.green : Color.red)
                }
                .frame(height: 200)
            }
        }
    }
}
