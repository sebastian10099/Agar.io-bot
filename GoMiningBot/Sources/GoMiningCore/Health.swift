import Foundation

// MARK: - Selbstdiagnose

/// Was die App ueber ihre Datenquellen weiss (alle Zeiten Unix-Sekunden, 0 = noch nie).
public struct HealthInput: Sendable {
    public var now: Double
    /// Start der App (in den ersten Sekunden fehlen Daten noch ganz normal).
    public var startedAt: Double
    /// Letzte Nachricht mit Marktdaten aus dem Livestream.
    public var lastStreamAt: Double
    /// Letztes Orderbuch (Livestream oder REST).
    public var lastBookAt: Double
    /// Letzter erfolgreicher Kerzenabruf.
    public var candlesFetchedAt: Double
    /// Zeitpunkt des juengsten oeffentlichen Trades (Markt-Aktivitaet).
    public var lastTradeAt: Double
    /// Meldet macOS eine Netzwerkverbindung?
    public var networkAvailable: Bool
    /// Fehler bei BingX-Abfragen in den letzten 10 Minuten.
    public var recentErrors: Int
    /// Abweichung der Mac-Uhr von der Boersenzeit in Sekunden (Boerse minus Mac).
    public var clockOffset: Double?

    public init(now: Double, startedAt: Double, lastStreamAt: Double, lastBookAt: Double, candlesFetchedAt: Double,
                lastTradeAt: Double, networkAvailable: Bool, recentErrors: Int, clockOffset: Double?) {
        self.now = now
        self.startedAt = startedAt
        self.lastStreamAt = lastStreamAt
        self.lastBookAt = lastBookAt
        self.candlesFetchedAt = candlesFetchedAt
        self.lastTradeAt = lastTradeAt
        self.networkAvailable = networkAvailable
        self.recentErrors = recentErrors
        self.clockOffset = clockOffset
    }
}

public enum HealthLevel: Int, Comparable, Sendable {
    case ok, info, warning, offline

    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct HealthIssue: Hashable, Sendable, Identifiable {
    public var level: HealthLevel
    public var title: String
    public var detail: String
    /// Was man tun kann (leer = nichts noetig).
    public var fix: String
    public var id: String { title }

    public init(level: HealthLevel, title: String, detail: String, fix: String) {
        self.level = level
        self.title = title
        self.detail = detail
        self.fix = fix
    }
}

public struct HealthReport: Sendable {
    public var level: HealthLevel
    public var issues: [HealthIssue]

    public init(level: HealthLevel, issues: [HealthIssue]) {
        self.level = level
        self.issues = issues
    }

    /// Kurzer Satz fuer die Statusleiste.
    public var summary: String {
        switch level {
        case .ok, .info: return "Alles in Ordnung"
        case .warning: return "Eingeschränkt: " + (issues.first { $0.level == .warning }?.title ?? "")
        case .offline: return "Offline: " + (issues.first { $0.level == .offline }?.title ?? "")
        }
    }

    public var isOffline: Bool { level == .offline }
}

public enum HealthMonitor {
    /// Bis hierhin gelten fehlende Daten nach dem Start noch als normal.
    public static let startupGrace = 30.0
    public static let bookWarning = 15.0
    public static let bookOffline = 60.0
    public static let streamWarning = 30.0
    public static let candleWarning = 180.0
    public static let quietMarket = 15.0 * 60

    public static func evaluate(_ i: HealthInput) -> HealthReport {
        var issues: [HealthIssue] = []
        let starting = i.now - i.startedAt < startupGrace
        func age(_ t: Double) -> Double { t > 0 ? max(0, i.now - t) : .infinity }
        func duration(_ s: Double) -> String {
            guard s.isFinite else { return "noch nie" }
            if s < 120 { return "\(Int(s)) s" }
            if s < 7_200 { return "\(Int(s / 60)) min" }
            return "\(Int(s / 3_600)) h"
        }

        if !i.networkAvailable {
            issues.append(HealthIssue(level: .offline, title: "Keine Internetverbindung",
                                      detail: "macOS meldet kein Netzwerk. Ohne Marktdaten handelt der Bot nicht.",
                                      fix: "Netzwerk prüfen. Die App verbindet sich automatisch neu, sobald es wieder da ist."))
        }

        let bookAge = age(i.lastBookAt)
        if bookAge > bookOffline, !starting {
            issues.append(HealthIssue(level: .offline, title: "Keine Marktdaten seit \(duration(bookAge))",
                                      detail: "Weder Livestream noch Abfragen liefern ein Orderbuch. Der Bot kauft und verkauft erst wieder, wenn frische Daten da sind.",
                                      fix: i.networkAvailable ? "„Jetzt neu verbinden“ versuchen; hilft das nicht, ist BingX vermutlich gestört." : ""))
        } else if bookAge > bookWarning, !starting {
            issues.append(HealthIssue(level: .warning, title: "Orderbuch veraltet (\(duration(bookAge)))",
                                      detail: "Das letzte Orderbuch ist älter als \(Int(bookWarning)) Sekunden; der Bot wartet mit Trades.",
                                      fix: "Meist erholt sich das von selbst innerhalb einer Minute."))
        }

        let streamAge = age(i.lastStreamAt)
        if streamAge > streamWarning, bookAge <= bookWarning, !starting {
            issues.append(HealthIssue(level: .warning, title: "Livestream hängt",
                                      detail: "Seit \(duration(streamAge)) kommt nichts über den Livestream; die Daten laufen über langsamere Abfragen weiter.",
                                      fix: "Die App verbindet den Livestream automatisch neu."))
        }

        let candleAge = age(i.candlesFetchedAt)
        if candleAge > candleWarning, !starting {
            issues.append(HealthIssue(level: .warning, title: "Kurskerzen veraltet (\(duration(candleAge)))",
                                      detail: "Ohne aktuelle Kerzen löst der Bot keine Käufe aus.",
                                      fix: "Die App fragt die Kerzen jede Minute neu ab."))
        }

        if i.recentErrors >= 5 {
            issues.append(HealthIssue(level: .warning, title: "Viele Fehler bei BingX (\(i.recentErrors) in 10 min)",
                                      detail: "Einzelne Abfragen schlagen fehl; Details unter Einstellungen → Diagnose kopieren.",
                                      fix: "Abwarten; bei Dauerfehlern Diagnose kopieren und mitschicken."))
        }

        if let offset = i.clockOffset, abs(offset) > 5 {
            issues.append(HealthIssue(level: .warning, title: "Mac-Uhr weicht um \(Int(abs(offset))) s ab",
                                      detail: "Die Zeiten von Trades und Kerzen werden ausgeglichen, Altersprüfungen können aber zu streng oder zu locker sein.",
                                      fix: "Systemeinstellungen → Allgemein → Datum & Uhrzeit → „Automatisch einstellen“ einschalten."))
        }

        let tradeAge = age(i.lastTradeAt)
        if tradeAge > quietMarket, bookAge <= bookWarning, !starting {
            issues.append(HealthIssue(level: .info, title: "Sehr ruhiger Markt",
                                      detail: "Seit \(duration(tradeAge)) gab es keinen Trade bei GOMINING/USDT. Das ist kein Fehler; Käufe brauchen aber etwas Handel.",
                                      fix: ""))
        }

        let level = issues.map(\.level).max() ?? .ok
        return HealthReport(level: level, issues: issues.sorted { $0.level > $1.level })
    }
}
