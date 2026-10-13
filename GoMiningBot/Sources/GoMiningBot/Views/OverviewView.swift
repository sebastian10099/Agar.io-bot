import SwiftUI
import GoMiningCore

@MainActor
struct OverviewView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var market: MarketStore
    @EnvironmentObject var bot: BotStore
    @EnvironmentObject var status: StatusStore
    @EnvironmentObject var prefs: Preferences

    @State private var calculatorBudget = 50.0

    private var settings: BotSettings { bot.stored.settings }
    private var state: BotState { bot.stored.state }
    private var bid: Double { market.bid }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                kpiGrid
                chartCard
                HStack(alignment: .top, spacing: 14) {
                    positionsCard
                    rulesCard
                }
                HStack(alignment: .top, spacing: 14) {
                    fastTradesCard
                    calculatorCard
                }
                simulationRulesCard
            }
            .padding(16)
        }
    }

    // MARK: Kopf

    private var minuteMoveBps: Double? {
        let c = market.chartCandles
        guard c.count >= 2, c[c.count - 2].close > 0 else { return nil }
        return (c[c.count - 1].close / c[c.count - 2].close - 1) * 10_000
    }

    private var priceColor: Color {
        guard let move = minuteMoveBps else { return .primary }
        return move > 0 ? .candleUp : (move < 0 ? .candleDown : .primary)
    }

    private var subline: String {
        guard let snap = market.snapshot else { return "Marktdaten laden …" }
        var parts = ["Bid \(Fmt.price(snap.bid))", "Ask \(Fmt.price(snap.ask))",
                     "Spread \(Fmt.usdt(snap.spreadBps, digits: 1)) bp",
                     "Gebühr \(Fmt.usdt(settings.feeBps, digits: 0)) bp/Seite"]
        if let m = minuteMoveBps { parts.append("1-Min.-Bewegung \(Fmt.signedUSDT(m, digits: 1)) bp") }
        parts.append(market.snapshot?.trades.isEmpty == false ? "3-Sek.-Bewegung \(Fmt.signedUSDT(market.fastMoveBps, digits: 1)) bp" : "3-Sek.-Bewegung —")
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Pill(text: "LIVE DATEN · PAPIERHANDEL")
                        if !state.running { Pill(text: "AUTOMATIK PAUSIERT", color: .orange) }
                        if !status.rulesVerified { Pill(text: "MINDESTORDER GESCHÄTZT", color: .yellow) }
                    }
                    Text("GOMINING / USDT").font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.price(market.price))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(priceColor)
                    Text(subline).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        controller.toggleRunning()
                    } label: {
                        Label(state.running ? "Pausieren" : "Starten", systemImage: state.running ? "pause.fill" : "play.fill")
                            .frame(minWidth: 110)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(state.running ? .orange : .green)
                    Text(state.running ? "Automatik läuft" : "Automatik pausiert").font(.caption).foregroundStyle(.secondary)
                    decisionText
                }
                .frame(maxWidth: 320, alignment: .trailing)
            }
        }
    }

    private var decisionText: some View {
        Group {
            if let d = bot.decisions.first {
                Text("\(d.kind): \(d.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
            }
        }
    }

    // MARK: Kennzahlen

    private var kpiGrid: some View {
        let equity = state.equity(atBid: bid)
        let total = equity - settings.startingUSDT
        let unrealized = state.tokens * bid - state.costBasisUSDT
        let today = equity - state.dayStartEquityUSDT
        let positions = BotEngine.openPositionCount(state.lots, bid: bid, settings: settings, minNotional: market.snapshot?.rules.minNotional ?? 0)
        let versusHold = bot.stored.performanceVsHoldingUSDT(bid: bid)
        return Card {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 14) {
                Metric(title: "Virtuelles Guthaben", value: Fmt.usdt(state.cashUSDT), subtitle: "USDT")
                Metric(title: "Positionen", value: "\(positions) / \(settings.openPositionLimit)",
                       subtitle: "Einsatz je Position \(Fmt.usdt(settings.maxTradeUSDT, digits: 0)) USDT")
                Metric(title: "GOMINING-Bestand", value: Fmt.quantity(state.tokens), subtitle: "Token · simuliert")
                Metric(title: "Virtuelles Vermögen", value: Fmt.usdt(equity), subtitle: "USDT · vor Verkaufskosten")
                Metric(title: "Gesamtergebnis", value: Fmt.signedUSDT(total), subtitle: Fmt.percent(total / max(1, settings.startingUSDT), digits: 2, signed: true),
                       color: .pnl(total))
                Metric(title: "Gegenüber Halten", value: versusHold.map { Fmt.signedUSDT($0) } ?? "—", subtitle: "USDT · zum Bid",
                       color: versusHold.map { Color.pnl($0) } ?? Color.secondary)
                Metric(title: "Realisiert", value: Fmt.signedUSDT(state.realizedPnLUSDT, digits: 2), subtitle: "nach Gebühren", color: .pnl(state.realizedPnLUSDT))
                Metric(title: "Nicht realisiert", value: Fmt.signedUSDT(unrealized), subtitle: "offene Positionen", color: .pnl(unrealized))
                Metric(title: "Heute (UTC)", value: Fmt.signedUSDT(today),
                       subtitle: "Grenze −\(Fmt.usdt(state.dayStartEquityUSDT * settings.maxDailyLossFraction)) USDT", color: .pnl(today))
                Metric(title: "Gebühren gesamt", value: Fmt.usdt(state.totalFeesUSDT, digits: 2), subtitle: "USDT · simuliert")
            }
        }
    }

    // MARK: Diagramm

    private var chartCandles: [PriceCandle] {
        prefs.chartMinutes == 1 ? market.chartCandles : (market.longMinutes == prefs.chartMinutes ? market.longCandles : [])
    }

    private var markers: [ChartMarker] {
        bot.stored.events.suffix(400).filter { $0.isTrade && $0.priceUSDT > 0 }
            .map { e in
                var label = "\(Fmt.shortTime(e.at)) \(e.action) \(Fmt.quantity(e.quantity)) zu \(Fmt.price(e.priceUSDT))"
                if e.isSell { label += " · \(Fmt.signedUSDT(e.realizedPnLUSDT, digits: 3)) USDT" }
                return ChartMarker(time: e.at, price: e.priceUSDT, isBuy: e.isBuy, label: label)
            }
    }

    private var chartCard: some View {
        Card("Kursverlauf", systemImage: "chart.xyaxis.line", trailing: AnyView(timeframePicker)) {
            CandleChartView(candles: chartCandles,
                            moves: prefs.chartMinutes == 1 ? (market.metrics?.moves ?? []) : [],
                            entryPrices: state.lots.map(\.buyPriceUSDT),
                            markers: markers,
                            targetPrice: market.metrics?.nextSellPrice,
                            buyPrice: market.metrics?.nextBuyPrice,
                            candleMinutes: prefs.chartMinutes,
                            defaultVisible: prefs.chartMinutes == 1 ? 180 : 240)
                .frame(height: 340)
            Text(chartCaption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chartCaption: String {
        var text = prefs.chartMinutes == 1
            ? "Abgeschlossene 1-Minuten-Kerzen und die laufende Minute · grün = steigend, rot = fallend"
            : "Aus 1-Minuten-Kerzen zusammengesetzt (\(prefs.chartMinutes) min je Kerze)"
        text += " · blaue Linien = Einstiege · ▲ Kauf ▼ Verkauf · Zoomen mit zwei Fingern oder der Lupe, Verschieben durch Ziehen"
        return text
    }

    private var timeframePicker: some View {
        Picker("Zeitraum", selection: Binding(get: { prefs.chartMinutes }, set: { controller.setChartMinutes($0) })) {
            Text("1 Min").tag(1)
            Text("5 Min").tag(5)
            Text("15 Min").tag(15)
            Text("1 Std").tag(60)
            Text("4 Std").tag(240)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280)
    }

    // MARK: Positionen

    private func netValue(_ lot: PositionLot) -> Double {
        lot.quantity * bid * (1 - settings.feeBps / 10_000) * (1 - settings.slippageBps / 10_000)
    }

    private var positionsCard: some View {
        Card("Virtueller Bestand", systemImage: "square.stack.3d.up") {
            if state.lots.isEmpty {
                EmptyHint(text: "Derzeit keine offenen virtuellen Positionen")
            } else {
                ForEach(state.lots.sorted { $0.boughtAt > $1.boughtAt }) { lot in
                    lotRow(lot)
                    Divider()
                }
            }
            Text("Alle Bot-Trades hier sind simuliert. Echte Bot-Orders: 0 · Echtgeldhandel deaktiviert.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func lotRow(_ lot: PositionLot) -> some View {
        let value = netValue(lot)
        let pnl = value - lot.costBasisUSDT
        let pct = lot.costBasisUSDT > 0 ? pnl / lot.costBasisUSDT : 0
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Einstieg \(Fmt.price(lot.buyPriceUSDT))").fontWeight(.medium)
                    if lot.isSeed { Pill(text: "STARTKAUF", color: .purple) }
                }
                Text("\(Fmt.quantity(lot.quantity)) GOMINING · seit \(Fmt.duration(Date().timeIntervalSince1970 - lot.boughtAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Fmt.signedUSDT(pnl)) USDT").foregroundStyle(Color.pnl(pnl)).monospacedDigit()
                Text("\(Fmt.percent(pct, digits: 2, signed: true)) · Wert \(Fmt.usdt(value))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    // MARK: Schwellen

    private var rulesCard: some View {
        let m = market.metrics
        return Card("Regeln & Schwellen", systemImage: "slider.horizontal.3") {
            KeyValueRow(title: "Preisanker", value: state.anchorUSDT > 0 ? Fmt.price(state.anchorUSDT) : "—",
                        help: "Preis des letzten simulierten Trades")
            KeyValueRow(title: "Dynamischer Kauf ab", value: m?.nextBuyPrice.map(Fmt.price) ?? "—", color: .candleDown,
                        help: "Unter diesem Preis löst ein Rückgang den nächsten Kauf aus")
            KeyValueRow(title: "Dynamischer Verkauf ab", value: m?.nextSellPrice.map(Fmt.price) ?? "—", color: .candleUp,
                        help: "Bid, ab dem das günstigste Los sein Nettoziel erreicht")
            if let order = state.pendingBuy {
                KeyValueRow(title: "Wartender Limit-Kauf",
                            value: "\(Fmt.quantity(order.quantity)) zu \(Fmt.price(order.price)) · \(Int(max(0, Date().timeIntervalSince1970 - order.placedAt))) s",
                            color: .orange,
                            help: "Virtuelle Kauforder am Bid; ausgeführt, wenn echte Verkäufe sie erreichen (Einstellungen → Limit-Kauf am Bid)")
            }
            Divider()
            KeyValueRow(title: "Rückgang / Anstieg", value: "\(Fmt.usdt(m?.dropBps ?? 0, digits: 0)) / \(Fmt.usdt(m?.riseBps ?? 0, digits: 0)) bp")
            KeyValueRow(title: "Kaufschwelle", value: Fmt.bps(m?.stepBps ?? 0), help: "Aus Spread, Gebühren und Volatilität berechnet")
            KeyValueRow(title: "Nettoziel je Verkauf", value: Fmt.bps(m?.exitBps ?? 0))
            KeyValueRow(title: "Volatilität (1 Min.)", value: Fmt.bps(m?.volatilityBps ?? 0, digits: 1))
            KeyValueRow(title: "Käuferanteil (60 s)", value: m?.pressure.map { Fmt.percent($0, digits: 0) } ?? "—")
            if let fast = m?.trendFast, let slow = m?.trendSlow {
                KeyValueRow(title: "Trend (EMA \(settings.trendFastMinutes)/\(settings.trendSlowMinutes))",
                            value: (m?.downtrend ?? false) ? "fallend" : (fast > slow ? "steigend" : "seitwärts"),
                            color: (m?.downtrend ?? false) ? .candleDown : (fast > slow ? .candleUp : .secondary),
                            help: settings.trendFilterEnabled ? "Trendfilter aktiv: im Abwärtstrend keine Neukäufe" : "Trendfilter aus (Einstellungen)")
            }
            KeyValueRow(title: "Kosten Hin- und Rückweg", value: Fmt.bps(m?.roundTripCostBps ?? 0, digits: 1),
                        help: "Sofort kaufen und zurückverkaufen: so viel Kursanstieg braucht es bis zur Kostendeckung")
            if !(m?.moves.isEmpty ?? true) {
                Divider()
                ForEach(m?.moves ?? [], id: \.windowMinutes) { move in
                    moveRow(move)
                }
                if let signal = m?.moveSignal {
                    Text("Signal: \(signal.action == .buy ? "Kauf nach Fall" : "Abbau nach Anstieg") (\(signal.reason))")
                        .font(.caption).foregroundStyle(signal.action == .buy ? Color.candleUp : Color.candleDown)
                }
            }
            Text(minerWarsText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func moveRow(_ move: Move) -> some View {
        let arrow = move.direction == .up ? "arrow.up.right" : "arrow.down.right"
        let color: Color = move.triggered ? (move.direction == .up ? .candleUp : .candleDown) : .secondary
        return HStack {
            Label("\(move.windowMinutes) min", systemImage: arrow).foregroundStyle(color)
            Spacer()
            Text("\(move.direction == .up ? "+" : "−")\(Fmt.usdt(move.movePercent, digits: 2)) % · Schwelle \(Fmt.usdt(move.thresholdPercent, digits: 1)) %")
                .foregroundStyle(color).monospacedDigit()
        }
        .font(.callout)
    }

    private var minerWarsText: String {
        let active = market.metrics?.minerWars ?? false
        var text = "Miner Wars: Dienstag 00:00–18:00 UTC mögliches Auszahlungsfenster. "
        text += "Mining-Modus: tägliche BTC-Auszahlung, keine bestätigte feste 11-Uhr-Token-Auszahlung. Zeitfenster lösen allein keinen Kauf aus."
        if active { text += " Miner-Wars-Fenster aktiv: strengere Einstiegsschwelle und frischer Kaufdruck erforderlich." }
        return text
    }

    // MARK: Schnelle Trades

    private var buyerShareText: String {
        guard let p = market.metrics?.pressure else { return "Andere Marktteilnehmer · anonym" }
        return "Andere Marktteilnehmer · Käuferanteil \(Fmt.percent(p, digits: 0)) · anonym"
    }

    private var fastTradesCard: some View {
        Card("Schnelle Trades · letzte 60 Sekunden", systemImage: "bolt") {
            Text(buyerShareText).font(.caption).foregroundStyle(.secondary)
            if market.recentTrades.isEmpty {
                EmptyHint(text: "Warte auf einzelne Live-Trades …", systemImage: "hourglass")
            } else {
                ForEach(market.recentTrades.prefix(14), id: \.id) { t in
                    HStack {
                        Text(Fmt.time(t.at)).foregroundStyle(.secondary).monospacedDigit()
                        Text(t.buyerInitiated ? "KAUF" : "VERKAUF")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(t.buyerInitiated ? Color.candleUp : Color.candleDown)
                            .frame(width: 64, alignment: .leading)
                        Spacer()
                        Text("\(Fmt.quantity(t.quantity)) × \(Fmt.price(t.price))").monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: Regeln der Simulation

    private var simulationRulesCard: some View {
        Card("Regeln der Simulation", systemImage: "info.circle") {
            Text("Der Bot berechnet Kaufabstand und Verkaufsziel bei jedem Marktdurchlauf aus Spread, Kursbewegung und angenommenen Kosten neu. Er handelt nur bei einem Signal und innerhalb der Grenzen.")
            Text("Gebühren lassen sich nicht abschaffen. Normale Verkäufe benötigen einen Überschuss nach Kauf- und Verkaufsgebühr; ein Stop-Loss kann trotzdem Verlust auslösen. Live-Orders sind deaktiviert.")
            Text("Der einmalige virtuelle Startkauf kann über dem Bestandslimit für automatische Neukäufe liegen. „Gegenüber Halten“ vergleicht den Bot mit dem unveränderten virtuellen Startbestand zum aktuellen Bid; die vollständige Ausführung dieser Menge im Orderbuch ist nicht garantiert.")
            Text("Echte BingX-Marktdaten · anonyme Trades · Käufe und Verkäufe des Bots bleiben simuliert · echte Gebühren können anfallen.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: Handelsrechner

    private var calculatorCard: some View {
        Card("Handelsrechner", systemImage: "function") {
            Picker("Betrag", selection: $calculatorBudget) {
                ForEach([10.0, 25, 50, 100, 150], id: \.self) { Text("\(Int($0)) USDT").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            calculatorResult
            Text("Aktuelle Kauf-Schätzung · keine Order").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var calculatorResult: some View {
        if let snap = market.snapshot {
            switch Book.buyQuote(snap, budgetUSDT: calculatorBudget, settings: settings) {
            case .success(let q):
                VStack(alignment: .leading, spacing: 4) {
                    Text("USDT → GOMINING").font(.caption).foregroundStyle(.secondary)
                    Text("\(Fmt.usdt(calculatorBudget, digits: 0)) USDT → \(Fmt.quantity(q.quantity)) GOMINING")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                    Text("Ask \(Fmt.price(snap.ask)) · Buchpreis \(Fmt.price(q.priceUSDT)) · Kosten \(Fmt.usdt(q.totalUSDT)) · Rest \(Fmt.usdt(q.unspentUSDT)) USDT")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text("Gebühr \(Fmt.usdt(q.feeUSDT, digits: 4)) USDT").font(.caption).foregroundStyle(.secondary)
                }
            case .failure:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keine ausführbare Menge").font(.title3.weight(.semibold))
                    Text("Mindestmenge oder sichtbare Orderbuchtiefe reicht nicht").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Marktdaten laden …").foregroundStyle(.secondary)
        }
    }
}
