import SwiftUI
import GoMiningCore

enum TradesSection: String, CaseIterable, Identifiable {
    case trades = "Trades"
    case holdings = "Bestand"
    case decisions = "Entscheidungen"
    var id: String { rawValue }
}

@MainActor
struct TradesView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var market: MarketStore
    @EnvironmentObject var bot: BotStore

    @State private var section = TradesSection.trades

    private var trades: [BotEvent] { bot.stored.events.filter { $0.isTrade }.reversed() }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch section {
            case .trades: tradeList
            case .holdings: holdings
            case .decisions: decisions
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("Bereich", selection: $section) {
                ForEach(TradesSection.allCases) { s in
                    Text(s == .trades ? "Trades (\(trades.count))" : s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
            Spacer()
            Text("Handelshistorie & Bestand").font(.headline).foregroundStyle(.secondary)
            Button { controller.exportTradesCSV() } label: { Label("CSV exportieren", systemImage: "square.and.arrow.up") }
                .disabled(trades.isEmpty)
            Button { controller.exportBackup() } label: { Label("Sicherung", systemImage: "externaldrive") }
        }
        .padding(12)
    }

    // MARK: Trades

    private var tradeList: some View {
        Group {
            if trades.isEmpty {
                EmptyHint(text: "Noch keine simulierten Käufe oder Verkäufe", systemImage: "arrow.left.arrow.right")
                    .frame(maxHeight: .infinity)
            } else {
                List(trades) { e in
                    tradeRow(e)
                }
                .listStyle(.inset)
            }
        }
    }

    private func tradeRow(_ e: BotEvent) -> some View {
        let color: Color = e.isSell ? .orange : .blue
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.action.uppercased()).font(.caption.weight(.bold)).foregroundStyle(color)
                Text(Fmt.dateTime(e.at)).font(.caption).foregroundStyle(.secondary)
                Pill(text: "SIMULIERT", color: .secondary)
            }
            .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Fmt.quantity(e.quantity)) GOMINING").fontWeight(.medium)
                Text("Preis \(Fmt.price(e.priceUSDT)) · Wert \(Fmt.usdt(e.quantity * e.priceUSDT)) USDT")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(e.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if e.isSell {
                    Text("\(Fmt.signedUSDT(e.realizedPnLUSDT, digits: 4)) USDT").foregroundStyle(Color.pnl(e.realizedPnLUSDT)).monospacedDigit()
                    if let bps = e.netBps {
                        Text("\(Fmt.signedUSDT(bps, digits: 0)) bp netto").font(.caption).foregroundStyle(.secondary)
                    }
                    if let held = e.heldSeconds {
                        Text("gehalten \(Fmt.duration(held))").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Einsatz inkl. Gebühr").font(.caption).foregroundStyle(.secondary)
                    Text("\(Fmt.usdt(e.quantity * e.priceUSDT + e.feeUSDT)) USDT").monospacedDigit()
                }
                Text("Gebühr \(Fmt.usdt(e.feeUSDT, digits: 4)) USDT").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Bestand

    private var holdings: some View {
        let bid = market.bid
        let fee = bot.stored.settings.feeBps / 10_000
        return Group {
            if bot.stored.state.lots.isEmpty {
                EmptyHint(text: "Derzeit keine offenen virtuellen Positionen", systemImage: "square.stack.3d.up")
                    .frame(maxHeight: .infinity)
            } else {
                List(bot.stored.state.lots.sorted { $0.boughtAt > $1.boughtAt }) { lot in
                    let value = lot.quantity * bid * (1 - fee)
                    let pnl = value - lot.costBasisUSDT
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("\(Fmt.quantity(lot.quantity)) GOMINING").fontWeight(.medium)
                                if lot.isSeed { Pill(text: "STARTKAUF", color: .purple) }
                            }
                            Text("Einstieg \(Fmt.price(lot.buyPriceUSDT)) · Einstand \(Fmt.usdt(lot.costBasisUSDT)) USDT · \(Fmt.dateTime(lot.boughtAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Fmt.signedUSDT(pnl)) USDT").foregroundStyle(Color.pnl(pnl)).monospacedDigit()
                            Text("Wert \(Fmt.usdt(value)) USDT").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Entscheidungen

    private var decisions: some View {
        Group {
            if bot.decisions.isEmpty {
                EmptyHint(text: "Noch keine Entscheidungen", systemImage: "list.bullet").frame(maxHeight: .infinity)
            } else {
                List(bot.decisions) { d in
                    HStack(alignment: .top, spacing: 10) {
                        Text(Fmt.time(d.at)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 70, alignment: .leading)
                        Text(d.kind).font(.caption.weight(.semibold)).frame(width: 90, alignment: .leading)
                        Text(d.reason).font(.callout)
                        Spacer()
                        if d.count > 1 { Text("×\(d.count)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}
