import SwiftUI
import AppKit
import GoMiningCore

/// Beschriftung in der Menueleiste: Kurs und Symbol.
@MainActor
struct MenuBarLabel: View {
    @EnvironmentObject var market: MarketStore
    @EnvironmentObject var bot: BotStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: bot.state.running ? "chart.line.uptrend.xyaxis" : "pause.circle")
            Text(market.price > 0 ? Fmt.price(market.price) : "GOMINING")
        }
    }
}

/// Inhalt des Menueleisten-Fensters: Kurs, Ergebnis, Start/Pause.
@MainActor
struct MenuBarView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var market: MarketStore
    @EnvironmentObject var bot: BotStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let equity = bot.state.equity(atBid: market.bid)
        let total = equity - bot.settings.startingUSDT
        let today = equity - bot.state.dayStartEquityUSDT
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GOMINING").font(.headline)
                Spacer()
                Text(Fmt.price(market.price)).font(.headline.monospacedDigit())
            }
            Divider()
            KeyValueRow(title: "Vermögen", value: "\(Fmt.usdt(equity)) USDT")
            KeyValueRow(title: "Gesamtergebnis", value: "\(Fmt.signedUSDT(total)) USDT", color: .pnl(total))
            KeyValueRow(title: "Heute", value: "\(Fmt.signedUSDT(today)) USDT", color: .pnl(today))
            KeyValueRow(title: "Positionen", value: "\(bot.state.lots.count) · \(Fmt.quantity(bot.state.tokens)) Token")
            Text(bot.state.running ? "Automatik läuft" : "Automatik pausiert").font(.caption).foregroundStyle(.secondary)
            if let d = bot.decisions.first {
                Text("\(d.kind): \(d.reason)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            Button(bot.state.running ? "Pausieren" : "Starten") { controller.toggleRunning() }
            Button("Fenster öffnen") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Beenden") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
    }
}
