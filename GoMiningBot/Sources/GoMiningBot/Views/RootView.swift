import SwiftUI
import GoMiningCore

enum AppTab: String, CaseIterable, Identifiable {
    case overview = "Übersicht"
    case trades = "Handel"
    case stats = "Statistik"
    case backtest = "Backtest"
    case settings = "Einstellungen"

    var id: String { rawValue }

    /// ASCII-Name fuer Dateinamen (Rauchtest-Bilder).
    var slug: String {
        switch self {
        case .overview: return "uebersicht"
        case .trades: return "handel"
        case .stats: return "statistik"
        case .backtest: return "backtest"
        case .settings: return "einstellungen"
        }
    }

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
            if let update = status.availableUpdate, !status.updateBannerHidden { updateBanner(update) }
            if let notice = status.notice { noticeBanner(notice) }
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 980, minHeight: 720)
        .navigationTitle(AppController.appName)
        .navigationSubtitle("BingX Spot · GOMINING / USDT")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Ansicht", selection: $tab) {
                    ForEach(AppTab.allCases) { t in
                        Text(t.rawValue).tag(t)
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
        .sheet(isPresented: Binding(get: { status.whatsNew != nil }, set: { if !$0 { status.whatsNew = nil } })) {
            WhatsNewView(text: status.whatsNew ?? "") { status.whatsNew = nil }
        }
        .onChange(of: controller.forcedTab) { _, newValue in
            if let newValue, let forced = AppTab(rawValue: newValue) { tab = forced }
        }
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

    private func updateBanner(_ update: ReleaseInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(AppController.appName) \(update.version.description) ist verfügbar").font(.callout.weight(.semibold))
                Text(status.updateBusy ? status.updateStatus : "Installiert: \(AppController.version) · Dein Papierkonto bleibt erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status.updateBusy {
                ProgressView().controlSize(.small)
            } else {
                Button("Neuerungen") { status.whatsNew = update.notes.isEmpty ? "Siehe Download-Seite." : update.notes }
                Button("Jetzt aktualisieren") { controller.installUpdate() }.buttonStyle(.borderedProminent)
                Button { status.updateBannerHidden = true } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.1))
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

/// Neuerungen einer Version (aus CHANGELOG.md bzw. den Release-Notizen).
struct WhatsNewView: View {
    let text: String
    let close: () -> Void

    private var attributed: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Was ist neu in \(AppController.appName) \(AppController.version)", systemImage: "sparkles").font(.title2.weight(.semibold))
            ScrollView {
                Text(attributed).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Weiter", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }
}
