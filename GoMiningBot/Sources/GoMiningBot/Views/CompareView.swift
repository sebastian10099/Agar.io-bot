import SwiftUI
import GoMiningCore

/// Schattenkonten: mehrere Einstellungen handeln parallel auf denselben Live-Daten.
@MainActor
struct CompareView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var market: MarketStore
    @EnvironmentObject var bot: BotStore
    @EnvironmentObject var shadows: ShadowStore

    @State private var preset = ShadowPreset.cautious
    @State private var name = ""
    @State private var confirmRemove: ShadowAccount?

    private var bid: Double { market.bid }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                introCard
                tableCard
                addCard
            }
            .padding(16)
        }
        .confirmationDialog("Schattenkonto entfernen?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            titleVisibility: .visible, presenting: confirmRemove) { account in
            Button("„\(account.name)“ entfernen", role: .destructive) { controller.removeShadow(account.id) }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    // MARK: Einleitung

    private var introCard: some View {
        Card("Einstellungen live vergleichen", systemImage: "square.split.2x1") {
            Text("Schattenkonten handeln mit eigenen Einstellungen und eigenem Papierkonto auf genau denselben Live-Daten wie das Hauptkonto – Kurs für Kurs, Orderbuch für Orderbuch. So zeigt sich unter echten Bedingungen, welche Einstellung besser läuft, ohne das Hauptkonto anzufassen.")
            Text("Fair ist der Vergleich zwischen Konten, die zur selben Zeit starten: „Alle zurücksetzen“ startet alle Schattenkonten gleichzeitig neu. Ein paar Stunden sind Zufall – aussagekräftig wird es nach Tagen.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Tabelle

    private var tableCard: some View {
        Card("Konten", systemImage: "list.number",
             trailing: shadows.accounts.isEmpty ? nil : AnyView(Button("Alle zurücksetzen") { controller.resetAllShadows() }.controlSize(.small))) {
            header
            Divider()
            mainRow
            ForEach(sortedAccounts) { account in
                Divider()
                shadowRow(account)
            }
            if shadows.accounts.isEmpty {
                EmptyHint(text: "Noch keine Schattenkonten. Unten eine Vorlage wählen und anlegen.", systemImage: "square.split.2x1")
            }
        }
    }

    private var sortedAccounts: [ShadowAccount] {
        shadows.accounts.sorted { $0.returnFraction(bid: bid) > $1.returnFraction(bid: bid) }
    }

    private var header: some View {
        HStack {
            Text("Konto").frame(maxWidth: .infinity, alignment: .leading)
            Text("Ergebnis").frame(width: 130, alignment: .trailing)
            Text("Halten").frame(width: 70, alignment: .trailing)
            Text("Käufe / Verk.").frame(width: 90, alignment: .trailing)
            Text("Gewinnquote").frame(width: 80, alignment: .trailing)
            Text("Positionen").frame(width: 70, alignment: .trailing)
            Color.clear.frame(width: 30)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var mainRow: some View {
        let s = bot.stored.settings
        let state = bot.stored.state
        let result = state.equity(atBid: bid) - s.startingUSDT
        let stats = bot.stats
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hauptkonto").font(.callout.weight(.semibold))
                    Text("seit \(Fmt.dateTime(bot.stored.events.first?.at ?? state.lastTradeAt))").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                resultText(result, start: s.startingUSDT)
                Text("—").frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                Text("\(stats.buyCount) / \(stats.closedTrades)").frame(width: 90, alignment: .trailing)
                Text(stats.closedTrades > 0 ? Fmt.percent(stats.winRate, digits: 0) : "—").frame(width: 80, alignment: .trailing)
                Text("\(positions(state, s))").frame(width: 70, alignment: .trailing)
                Color.clear.frame(width: 30)
            }
            Text(settingsSummary(s)).font(.caption2).foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
        .padding(.vertical, 2)
    }

    private func shadowRow(_ a: ShadowAccount) -> some View {
        let result = a.result(bid: bid)
        let diff = differences(a.settings, from: bot.stored.settings)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name).font(.callout.weight(.semibold))
                    Text("seit \(Fmt.dateTime(a.createdAt))").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                resultText(result, start: a.settings.startingUSDT)
                Text(a.holdReturnFraction(bid: bid).map { Fmt.percent($0, digits: 1, signed: true) } ?? "—")
                    .foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    .help("Kursveränderung seit dem Anlegen")
                Text("\(a.buys) / \(a.sells)").frame(width: 90, alignment: .trailing)
                Text(a.winRate.map { Fmt.percent($0, digits: 0) } ?? "—").frame(width: 80, alignment: .trailing)
                Text("\(positions(a.state, a.settings))").frame(width: 70, alignment: .trailing)
                Menu {
                    Button("Einstellungen ins Hauptkonto übernehmen") { controller.applyShadowSettings(a.id) }
                    Button("Zurücksetzen") { controller.resetShadow(a.id) }
                    Divider()
                    Button("Entfernen", role: .destructive) { confirmRemove = a }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
            Text(diff.isEmpty ? "Gleiche Einstellungen wie das Hauptkonto" : "Anders als das Hauptkonto: " + diff.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
            if let order = a.state.pendingBuy {
                Text("Wartender Limit-Kauf: \(Fmt.quantity(order.quantity)) zu \(Fmt.price(order.price))")
                    .font(.caption2).foregroundStyle(.orange)
            } else if !a.lastReason.isEmpty {
                Text(a.lastReason).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.vertical, 2)
    }

    private func resultText(_ value: Double, start: Double) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(Fmt.signedUSDT(value)).foregroundStyle(Color.pnl(value))
            Text(Fmt.percent(start > 0 ? value / start : 0, digits: 2, signed: true)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 130, alignment: .trailing)
    }

    private func positions(_ state: BotState, _ s: BotSettings) -> Int {
        BotEngine.openPositionCount(state.lots, bid: bid, settings: s, minNotional: market.snapshot?.rules.minNotional ?? 0)
    }

    // MARK: Neues Konto

    private var addCard: some View {
        let full = shadows.accounts.count >= ShadowAccount.maxAccounts
        return Card("Schattenkonto anlegen", systemImage: "plus.square.on.square") {
            Picker("Vorlage", selection: $preset) {
                ForEach(ShadowPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 420)
            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
            let preview = differences(preset.settings(from: bot.stored.settings), from: bot.stored.settings)
            if !preview.isEmpty {
                Text("Unterschiede zum Hauptkonto: " + preview.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Name (optional)", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button {
                    controller.addShadow(preset, name: name)
                    name = ""
                } label: { Label("Anlegen", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(full)
                if full { Text("Höchstens \(ShadowAccount.maxAccounts) Schattenkonten").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Startkapital, Gebühren und Slippage übernimmt jedes Schattenkonto vom Hauptkonto. Schattenkonten kaufen keinen Startbestand – sie beginnen mit Bargeld.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Hilfen

    private func settingsSummary(_ s: BotSettings) -> String {
        var parts = ["Ziel \(Fmt.bps(s.minNetProfitBps))", "Stop \(Fmt.percent(s.stopLossFraction, digits: 1))",
                     "Einsatz \(Fmt.usdt(s.maxTradeUSDT, digits: 0))", "\(s.openPositionLimit) Pos."]
        parts.append(s.trendFilterEnabled ? "Trendfilter an" : "Trendfilter aus")
        if s.makerEntries { parts.append("Limit-Kauf am Bid") }
        return parts.joined(separator: " · ")
    }

    /// Kurze Liste der wichtigsten Unterschiede.
    private func differences(_ a: BotSettings, from b: BotSettings) -> [String] {
        var out: [String] = []
        if a.minNetProfitBps != b.minNetProfitBps { out.append("Ziel \(Fmt.bps(a.minNetProfitBps))") }
        if a.stopLossFraction != b.stopLossFraction { out.append("Stop \(Fmt.percent(a.stopLossFraction, digits: 1))") }
        if a.maxTradeUSDT != b.maxTradeUSDT { out.append("Einsatz \(Fmt.usdt(a.maxTradeUSDT, digits: 0)) USDT") }
        if a.openPositionLimit != b.openPositionLimit { out.append("\(a.openPositionLimit) Positionen") }
        if a.minLotDistanceFactor != b.minLotDistanceFactor { out.append("Abstand \(Fmt.usdt(a.minLotDistanceFactor, digits: 1))×") }
        if a.minBuyStepBps != b.minBuyStepBps { out.append(a.minBuyStepBps > 0 ? "Mindest-Kaufabstand \(Fmt.bps(a.minBuyStepBps))" : "ohne Mindest-Kaufabstand") }
        if a.trailingStopBps != b.trailingStopBps { out.append(a.trailingStopBps > 0 ? "Trailing \(Fmt.bps(a.trailingStopBps))" : "ohne Trailing") }
        if a.trendFilterEnabled != b.trendFilterEnabled { out.append(a.trendFilterEnabled ? "Trendfilter an" : "Trendfilter aus") }
        if a.makerEntries != b.makerEntries { out.append(a.makerEntries ? "Limit-Kauf am Bid" : "Kauf zum Ask") }
        if a.maxDailyLossFraction != b.maxDailyLossFraction { out.append("Tagesgrenze \(Fmt.percent(a.maxDailyLossFraction, digits: 1))") }
        if a.minSecondsBetweenTrades != b.minSecondsBetweenTrades { out.append("\(Int(a.minSecondsBetweenTrades)) s zwischen Trades") }
        return out
    }
}
