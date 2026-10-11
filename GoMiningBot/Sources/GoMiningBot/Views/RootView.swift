import SwiftUI
import GoMiningCore

enum AppTab: String, CaseIterable, Identifiable {
    case overview = "Übersicht"
    case trades = "Handel"
    case stats = "Statistik"
    case backtest = "Backtest"
    case settings = "Einstellungen"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .trades: return "arrow.left.arrow.right"
        case .stats: return "chart.bar.xaxis"
        case .backtest: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var market: MarketStore
    @EnvironmentObject var bot: BotStore
    @EnvironmentObject var status: StatusStore

    @State private var tab = AppTab.overview

    var body: some View {
        VStack(spacing: 0) {
            if let notice = status.notice { noticeBanner(notice) }
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 980, minHeight: 720)
        .navigationTitle("GoMining Bot")
        .navigationSubtitle("BingX Spot · GOMINING / USDT · adaptive Simulation")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Ansicht", selection: $tab) {
                    ForEach(AppTab.allCases) { t in
                        Label(t.rawValue, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 560)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { controller.toggleRunning() } label: {
                    Label(bot.state.running ? "Pausieren" : "Starten", systemImage: bot.state.running ? "pause.fill" : "play.fill")
                }
                .help(bot.state.running ? "Automatik pausieren" : "Automatik starten")
                Button { controller.evaluate() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                    .help("Marktbild neu bewerten")
            }
        }
        .task { controller.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: OverviewView()
        case .trades: TradesView()
        case .stats: StatsView()
        case .backtest: BacktestView()
        case .settings: SettingsView()
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(text).font(.callout)
            Spacer()
            Button("OK") { status.notice = nil }.controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Label(status.connection, systemImage: "network").lineLimit(1)
            Label(status.stream, systemImage: "dot.radiowaves.left.and.right").lineLimit(1)
            Label(status.journal, systemImage: "externaldrive").lineLimit(1)
            Spacer()
            if let t = market.lastUpdate { Text("Aktualisiert \(Fmt.time(t.timeIntervalSince1970))") } else { Text("Noch keine Daten") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
