import Foundation
import SwiftUI
import GoMiningCore

/// Zahlen- und Zeitformate fuer die deutsche Oberflaeche.
enum Fmt {
    static func price(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        if v == 0 { return "—" }
        let digits = v >= 1_000 ? 2 : v >= 10 ? 3 : v >= 1 ? 4 : v >= 0.1 ? 5 : 6
        return v.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
    }

    static func usdt(_ v: Double, digits: Int = 2) -> String {
        guard v.isFinite else { return "—" }
        return v.formatted(.number.precision(.fractionLength(digits)))
    }

    static func signedUSDT(_ v: Double, digits: Int = 2) -> String {
        guard v.isFinite else { return "—" }
        return v.formatted(.number.precision(.fractionLength(digits)).sign(strategy: .always(includingZero: false)))
    }

    static func quantity(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        let digits = v >= 1_000 ? 2 : 4
        return v.formatted(.number.precision(.fractionLength(digits...digits)))
    }

    static func bps(_ v: Double, digits: Int = 0) -> String {
        guard v.isFinite else { return "—" }
        return v.formatted(.number.precision(.fractionLength(digits))) + " bp"
    }

    static func percent(_ fraction: Double, digits: Int = 1, signed: Bool = false) -> String {
        guard fraction.isFinite else { return "—" }
        let style = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(digits))
        return signed ? fraction.formatted(style.sign(strategy: .always(includingZero: false))) : fraction.formatted(style)
    }

    static func time(_ t: Double) -> String {
        Date(timeIntervalSince1970: t).formatted(.dateTime.hour().minute().second())
    }

    static func dateTime(_ t: Double) -> String {
        Date(timeIntervalSince1970: t).formatted(.dateTime.day().month().hour().minute().second())
    }

    static func shortTime(_ t: Double) -> String {
        Date(timeIntervalSince1970: t).formatted(.dateTime.hour().minute())
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3_600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3_600) h \((s % 3_600) / 60) min" }
        return "\(s / 86_400) d \((s % 86_400) / 3_600) h"
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Kurzbeschreibung der wichtigsten Strategie-Einstellungen.
    static func settingsSummary(_ s: BotSettings) -> String {
        var parts = ["Ziel \(bps(s.minNetProfitBps))", "Stop \(percent(s.stopLossFraction, digits: 1))",
                     "Einsatz \(usdt(s.maxTradeUSDT, digits: 0))", "\(s.openPositionLimit) Pos."]
        parts.append(s.minBuyStepBps > 0 ? "Kaufabstand ≥ \(bps(s.minBuyStepBps))" : "Kaufabstand nur adaptiv")
        parts.append(s.trendFilterEnabled ? "Trendfilter an" : "Trendfilter aus")
        if s.makerEntries { parts.append("Limit-Kauf am Bid") }
        return parts.joined(separator: " · ")
    }
}

extension Color {
    /// Gewinn gruen, Verlust rot, sonst neutral.
    static func pnl(_ v: Double) -> Color {
        if v > 0 { return .green }
        if v < 0 { return .red }
        return .secondary
    }

    static let candleUp = Color(red: 0.13, green: 0.77, blue: 0.37)
    static let candleDown = Color(red: 0.94, green: 0.27, blue: 0.27)
}
