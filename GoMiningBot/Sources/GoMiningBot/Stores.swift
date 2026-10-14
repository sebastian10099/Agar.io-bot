import Foundation
import SwiftUI
import GoMiningCore

/// Live-Marktdaten fuer die Oberflaeche. Wird hoechstens ~4x pro Sekunde aktualisiert.
@MainActor
final class MarketStore: ObservableObject {
    @Published var snapshot: MarketSnapshot?
    @Published var metrics: EngineMetrics?
    /// Abgeschlossene Kerzen plus die laufende Minute.
    @Published var chartCandles: [PriceCandle] = []
    /// Aggregierte Kerzen fuer laengere Zeitraeume (5 Min, 15 Min, 1 Std, 4 Std).
    @Published var longCandles: [PriceCandle] = []
    @Published var longMinutes: Int = 0
    @Published var recentTrades: [PublicTrade] = []
    @Published var fastMoveBps: Double = 0
    @Published var lastUpdate: Date?

    var price: Double { snapshot?.displayPrice ?? 0 }
    var bid: Double { snapshot?.bid ?? 0 }
    var ask: Double { snapshot?.ask ?? 0 }
}

struct DecisionEntry: Identifiable, Hashable {
    let id = UUID()
    /// Gleichartige Entscheidungen werden zusammengefasst (gleicher Schluessel).
    var key: String
    var at: Double
    var kind: String
    var reason: String
    var count: Int = 1
}

/// Zustand des Papierkontos, Verlauf und Auswertung.
@MainActor
final class BotStore: ObservableObject {
    @Published var stored: StoredBot
    @Published var decisions: [DecisionEntry] = []
    @Published var equityHistory: [EquityPoint] = []
    @Published var stats = PerformanceStats()
    /// Zeitstempel des letzten Trades (fuer kurzes Aufleuchten in der Oberflaeche).
    @Published var lastTradeAt: Date?

    init(stored: StoredBot) { self.stored = stored }

    var state: BotState { stored.state }
    var settings: BotSettings { stored.settings }
    var tradeEvents: [BotEvent] { stored.events.filter { $0.isTrade } }

    func equity(bid: Double) -> Double { stored.state.equity(atBid: bid) }
    func totalResult(bid: Double) -> Double { equity(bid: bid) - stored.settings.startingUSDT }

    func recomputeStats() {
        stats = PerformanceStats.compute(events: stored.events, equity: equityHistory)
    }
}

/// Verbindungs- und Statusmeldungen.
@MainActor
final class StatusStore: ObservableObject {
    @Published var connection = "Verbinde mit BingX …"
    @Published var stream = "BingX-Livestream verbindet …"
    @Published var journal = "Marktprotokoll bereit"
    @Published var account = "Kein BingX-Konto verbunden"
    @Published var accountConnected = false
    @Published var balances: [BingXParser.SpotBalance] = []
    @Published var commission: BingXParser.SpotCommission?
    @Published var rulesVerified = true
    @Published var historyStatus = ""
    @Published var notice: String?
    @Published var busy = false
    @Published var dataFolderBytes: Int64 = 0
    /// Letzte Fehler (neueste zuerst) fuer die Diagnose.
    @Published var errors: [String] = []
    // Updates
    @Published var availableUpdate: ReleaseInfo?
    @Published var updateStatus = ""
    @Published var updateBusy = false
    @Published var updateBannerHidden = false
    /// Text fuer "Was ist neu" nach einem Update (nil = nicht anzeigen).
    @Published var whatsNew: String?

    /// Selbstdiagnose (wird alle paar Sekunden neu bewertet).
    @Published var health = HealthReport(level: .ok, issues: [])
    /// Zeitpunkte der letzten Fehler (fuer "viele Fehler in 10 Minuten").
    var errorTimes: [Double] = []

    func note(_ context: String, _ error: Error) {
        let now = Date().timeIntervalSince1970
        let line = "\(Fmt.time(now)) \(context): \(error.localizedDescription)"
        errors.insert(line, at: 0)
        if errors.count > 12 { errors.removeLast(errors.count - 12) }
        errorTimes.append(now)
        errorTimes.removeAll { now - $0 > 600 }
    }
}

/// Vorlieben (UserDefaults): Benachrichtigungen, Preisalarme, Chart.
struct PriceAlert: Codable, Identifiable, Hashable {
    var id = UUID()
    var price: Double
    var above: Bool
    var enabled = true
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var notifyTrades: Bool { didSet { defaults.set(notifyTrades, forKey: "notifyTrades") } }
    @Published var notifyStops: Bool { didSet { defaults.set(notifyStops, forKey: "notifyStops") } }
    @Published var notifyLimits: Bool { didSet { defaults.set(notifyLimits, forKey: "notifyLimits") } }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: "showMenuBar") } }
    @Published var chartMinutes: Int { didSet { defaults.set(chartMinutes, forKey: "chartMinutes") } }
    @Published var journalDays: Int { didSet { defaults.set(journalDays, forKey: "journalDays") } }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    /// Tageszusammenfassung als Mitteilung nach Mitternacht.
    @Published var dailySummary: Bool { didSet { defaults.set(dailySummary, forKey: "dailySummary") } }
    /// Lokaler Tag (yyyy-MM-dd) der letzten Zusammenfassung.
    @Published var lastSummaryDay: String { didSet { defaults.set(lastSummaryDay, forKey: "lastSummaryDay") } }
    /// Zuletzt gestartete Version (fuer "Was ist neu").
    @Published var lastSeenVersion: String { didSet { defaults.set(lastSeenVersion, forKey: "lastSeenVersion") } }
    @Published var alerts: [PriceAlert] {
        didSet {
            if let data = try? JSONEncoder().encode(alerts) { defaults.set(data, forKey: "priceAlerts") }
        }
    }

    init() {
        func flag(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }
        notifyTrades = flag("notifyTrades", true)
        notifyStops = flag("notifyStops", true)
        notifyLimits = flag("notifyLimits", true)
        soundEnabled = flag("soundEnabled", false)
        showMenuBar = flag("showMenuBar", true)
        let minutes = UserDefaults.standard.integer(forKey: "chartMinutes")
        chartMinutes = minutes == 0 ? 1 : minutes
        let days = UserDefaults.standard.integer(forKey: "journalDays")
        journalDays = days == 0 ? 7 : days
        autoCheckUpdates = flag("autoCheckUpdates", true)
        dailySummary = flag("dailySummary", true)
        lastSummaryDay = UserDefaults.standard.string(forKey: "lastSummaryDay") ?? ""
        lastSeenVersion = UserDefaults.standard.string(forKey: "lastSeenVersion") ?? ""
        if let data = UserDefaults.standard.data(forKey: "priceAlerts"),
           let list = try? JSONDecoder().decode([PriceAlert].self, from: data) {
            alerts = list
        } else {
            alerts = []
        }
    }
}

/// Datenquelle des Backtests.
enum BacktestSource: String, CaseIterable, Identifiable {
    case candles = "Kerzen von BingX"
    case journal = "Marktprotokoll (echte Orderbücher)"
    var id: String { rawValue }
}

/// Gespeicherte Einstellungs-Profile.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var book = ProfileBook()
}

/// Zeitraum eines Berichts.
enum ReportKind: String, CaseIterable, Identifiable {
    case today = "Heute"
    case yesterday = "Gestern"
    case week = "Letzte 7 Tage"
    var id: String { rawValue }
}

/// Schattenkonten fuer die Vergleichsseite.
@MainActor
final class ShadowStore: ObservableObject {
    @Published var book = ShadowBook()
    var accounts: [ShadowAccount] { book.accounts }
}

/// Zustand der Backtest-Seite.
@MainActor
final class BacktestStore: ObservableObject {
    // Eingaben
    @Published var days = 7
    @Published var source = BacktestSource.candles
    @Published var spreadBps = 20.0
    @Published var depthUSDT = 3_000.0
    /// Spread und Tiefe vor jedem Lauf aus dem Live-Markt nehmen (ehrlicher als feste Annahmen).
    @Published var autoMarket = true
    @Published var seedStartPosition = false
    /// Gemessene Marktwerte aus dem Protokoll (nach "Aus Marktprotokoll messen" oder einem Replay).
    @Published var calibration: MarketCalibration?
    @Published var journalInfo = ""
    // Ausgaben
    @Published var running = false
    @Published var progress = 0.0
    @Published var message = ""
    @Published var result: BacktestResult?
    // Optimierung
    @Published var objective = BacktestObjective.riskAdjusted
    @Published var trainFraction = 0.7
    @Published var axes: [OptimizerParameter: String] = [
        .minNetProfitBps: "30, 50, 80, 120",
        .stopLossFraction: "0.02, 0.03, 0.05",
    ]
    @Published var optimizing = false
    @Published var entries: [OptimizerEntry] = []
    @Published var optimizerAxesUsed: [OptimizerParameter] = []
    @Published var ranking = OptimizerRanking.robustness
    @Published var walkForward: WalkForwardSummary?

    var task: Task<Void, Never>?

    func config(rules: SymbolRules) -> BacktestConfig {
        var c = BacktestConfig()
        c.spreadBps = spreadBps
        c.depthUSDT = depthUSDT
        c.seedStartPosition = seedStartPosition
        c.rules = rules
        return c
    }

    /// Wandelt "30, 50; 80" in Zahlen (Komma oder Semikolon, Punkt oder Komma als Dezimalzeichen nur mit Semikolon).
    static func parseValues(_ text: String) -> [Double] {
        let separators: CharacterSet = text.contains(";") ? CharacterSet(charactersIn: ";") : CharacterSet(charactersIn: ",")
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".") }
            .compactMap { Double($0) }
            .filter { $0.isFinite && abs($0) < 1e9 }
    }
}
