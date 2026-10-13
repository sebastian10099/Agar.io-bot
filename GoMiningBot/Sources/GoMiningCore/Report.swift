import Foundation

// MARK: - Tages- und Wochenberichte

/// Auswertung eines Zeitraums (z. B. gestern oder die letzten 7 Tage).
public struct PeriodReport: Sendable {
    public var title: String
    public var from: Double
    public var to: Double
    /// Trades im Zeitraum (aelteste zuerst).
    public var trades: [BotEvent] = []
    public var buys = 0
    public var sells = 0
    public var wins = 0
    public var realizedPnL = 0.0
    public var fees = 0.0
    public var bestTrade: Double?
    public var worstTrade: Double?
    /// Vermoegen zu Beginn und am Ende (aus dem Verlauf, am Ende ggf. der aktuelle Wert).
    public var equityStart: Double?
    public var equityEnd: Double?
    public var holdStart: Double?
    public var holdEnd: Double?
    /// Vermoegensverlauf im Zeitraum.
    public var equity: [EquityPoint] = []

    public var winRate: Double? { sells > 0 ? Double(wins) / Double(sells) : nil }

    public var equityChange: Double? {
        guard let a = equityStart, let b = equityEnd else { return nil }
        return b - a
    }

    public var equityChangeFraction: Double? {
        guard let a = equityStart, let b = equityEnd, a > 0 else { return nil }
        return b / a - 1
    }

    /// Veraenderung bei reinem Halten des Startbestands (nur mit Startkauf).
    public var holdChangeFraction: Double? {
        guard let a = holdStart, let b = holdEnd, a > 0 else { return nil }
        return b / a - 1
    }

    public var isEmpty: Bool { trades.isEmpty && equity.count < 2 }
}

public enum ReportBuilder {
    /// Wertet Trades und Vermoegensverlauf zwischen `from` (inklusive) und `to` (exklusive) aus.
    /// `currentEquity` ersetzt das Ende, wenn der Zeitraum bis jetzt reicht.
    public static func period(title: String, events: [BotEvent], equity: [EquityPoint], from: Double, to: Double,
                              currentEquity: Double? = nil, currentHold: Double? = nil) -> PeriodReport {
        var r = PeriodReport(title: title, from: from, to: to)
        for e in events where e.isTrade && e.at >= from && e.at < to {
            r.trades.append(e)
            r.fees += e.feeUSDT
            if e.isSell {
                r.sells += 1
                r.realizedPnL += e.realizedPnLUSDT
                if e.realizedPnLUSDT > 0 { r.wins += 1 }
                r.bestTrade = max(r.bestTrade ?? -.infinity, e.realizedPnLUSDT)
                r.worstTrade = min(r.worstTrade ?? .infinity, e.realizedPnLUSDT)
            } else {
                r.buys += 1
            }
        }
        r.trades.sort { $0.at < $1.at }
        r.equity = equity.filter { $0.t >= from && $0.t < to }
        // Startwert: letzter Punkt vor dem Zeitraum, sonst der erste darin.
        let before = equity.last { $0.t < from }
        let startPoint = before ?? r.equity.first
        r.equityStart = startPoint?.equity
        r.holdStart = startPoint?.hold
        r.equityEnd = currentEquity ?? r.equity.last?.equity
        r.holdEnd = currentHold ?? r.equity.last?.hold
        if let current = currentEquity, let last = r.equity.last, current != last.equity, to > last.t {
            r.equity.append(EquityPoint(t: min(to - 1, Date().timeIntervalSince1970), equity: current, hold: currentHold))
        }
        return r
    }

    /// Kurztext fuer die Tageszusammenfassung als Mitteilung.
    public static func summaryText(_ r: PeriodReport) -> String {
        var parts: [String] = []
        if r.trades.isEmpty {
            parts.append("Keine Trades")
        } else {
            parts.append("\(r.buys) Käufe, \(r.sells) Verkäufe")
            parts.append("realisiert \(signed(r.realizedPnL)) USDT")
            if let rate = r.winRate { parts.append("Gewinnquote \(number(rate * 100, 0)) %") }
        }
        if let change = r.equityChange, let fraction = r.equityChangeFraction {
            parts.append("Vermögen \(signed(change)) USDT (\(signed(fraction * 100)) %)")
        }
        if let hold = r.holdChangeFraction { parts.append("Halten \(signed(hold * 100)) %") }
        return parts.joined(separator: " · ")
    }

    // MARK: HTML

    /// Eigenstaendiger HTML-Bericht (ohne externe Dateien, druckbar als PDF ueber den Browser).
    public static func html(_ r: PeriodReport, appName: String, appVersion: String, settings: BotSettings,
                            generatedAt: Double, timeZone: TimeZone = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "de_DE")
        fmt.timeZone = timeZone
        fmt.dateFormat = "dd.MM.yyyy HH:mm"
        func date(_ t: Double) -> String { fmt.string(from: Date(timeIntervalSince1970: t)) }

        var kpis: [(String, String, String)] = []                 // Titel, Wert, CSS-Klasse
        if let change = r.equityChange {
            let pct = r.equityChangeFraction.map { " (\(signed($0 * 100)) %)" } ?? ""
            kpis.append(("Vermögen", "\(signed(change)) USDT\(pct)", cls(change)))
        }
        if let a = r.equityStart, let b = r.equityEnd {
            kpis.append(("Vermögen Anfang → Ende", "\(number(a, 2)) → \(number(b, 2)) USDT", ""))
        }
        if let hold = r.holdChangeFraction { kpis.append(("Zum Vergleich: Halten", "\(signed(hold * 100)) %", cls(hold))) }
        kpis.append(("Realisiert", "\(signed(r.realizedPnL)) USDT", cls(r.realizedPnL)))
        kpis.append(("Käufe / Verkäufe", "\(r.buys) / \(r.sells)", ""))
        kpis.append(("Gewinnquote", r.winRate.map { "\(number($0 * 100, 0)) %" } ?? "—", ""))
        kpis.append(("Gebühren", "\(number(r.fees, 2)) USDT", ""))
        if let best = r.bestTrade, let worst = r.worstTrade {
            kpis.append(("Bester / schlechtester Verkauf", "\(signed(best)) / \(signed(worst)) USDT", ""))
        }

        var html = """
        <!doctype html>
        <html lang="de"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(appName)) – \(escape(r.title))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;margin:32px auto;max-width:960px;color:#1d1d1f;padding:0 16px}
        h1{font-size:24px;margin:0 0 4px} h2{font-size:17px;margin:28px 0 8px}
        .sub{color:#6e6e73;font-size:13px}
        .kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px;margin-top:16px}
        .kpi{border:1px solid #e5e5ea;border-radius:10px;padding:10px 12px}
        .kpi .t{font-size:12px;color:#6e6e73} .kpi .v{font-size:17px;font-weight:600;margin-top:2px}
        .pos{color:#1a8f3c} .neg{color:#c62828}
        table{border-collapse:collapse;width:100%;font-size:12.5px} th,td{text-align:left;padding:5px 6px;border-bottom:1px solid #eee}
        th{color:#6e6e73;font-weight:600} td.n{text-align:right;font-variant-numeric:tabular-nums}
        .note{font-size:12px;color:#6e6e73;margin-top:24px}
        svg{width:100%;height:auto;border:1px solid #e5e5ea;border-radius:10px}
        </style></head><body>
        <h1>\(escape(r.title))</h1>
        <div class="sub">\(escape(appName)) \(escape(appVersion)) · Papierhandel GOMINING/USDT (BingX Spot) · \(date(r.from)) bis \(date(r.to)) · erstellt \(date(generatedAt))</div>
        <div class="kpis">
        """
        for (title, value, klass) in kpis {
            html += "<div class=\"kpi\"><div class=\"t\">\(escape(title))</div><div class=\"v \(klass)\">\(escape(value))</div></div>\n"
        }
        html += "</div>\n"

        if r.equity.count >= 2 {
            html += "<h2>Vermögensverlauf</h2>\n" + svgChart(r.equity) + "\n"
            html += "<div class=\"sub\">Blau: Bot · Orange gestrichelt: unverändert halten (nur mit Startkauf)</div>\n"
        }

        html += "<h2>Trades (\(r.trades.count))</h2>\n"
        if r.trades.isEmpty {
            html += "<p class=\"sub\">Keine Trades in diesem Zeitraum.</p>\n"
        } else {
            html += "<table><tr><th>Zeit</th><th>Aktion</th><th class=\"n\">Menge</th><th class=\"n\">Preis</th><th class=\"n\">Gebühr</th><th class=\"n\">Ergebnis</th><th>Grund</th></tr>\n"
            for e in r.trades.suffix(500) {
                let result = e.isSell ? "<span class=\"\(cls(e.realizedPnLUSDT))\">\(signed(e.realizedPnLUSDT, 4))</span>" : ""
                html += "<tr><td>\(date(e.at))</td><td>\(escape(e.action))</td><td class=\"n\">\(number(e.quantity, 2))</td>"
                    + "<td class=\"n\">\(number(e.priceUSDT, 6))</td><td class=\"n\">\(number(e.feeUSDT, 4))</td>"
                    + "<td class=\"n\">\(result)</td><td>\(escape(e.reason))</td></tr>\n"
            }
            html += "</table>\n"
        }

        html += "<h2>Einstellungen</h2>\n<table>\n"
        let rows: [(String, String)] = [
            ("Startkapital", "\(number(settings.startingUSDT, 0)) USDT"),
            ("Einsatz je Position / Positionen", "\(number(settings.maxTradeUSDT, 0)) USDT / \(settings.openPositionLimit)"),
            ("Mindest-Nettoziel", "\(number(settings.minNetProfitBps, 0)) bp"),
            ("Stop-Loss", "\(number(settings.stopLossFraction * 100, 1)) %"),
            ("Mindest-Kaufabstand", settings.minBuyStepBps > 0 ? "\(number(settings.minBuyStepBps, 0)) bp" : "aus"),
            ("Trendfilter", settings.trendFilterEnabled ? "an (EMA \(settings.trendFastMinutes)/\(settings.trendSlowMinutes))" : "aus"),
            ("Limit-Kauf am Bid", settings.makerEntries ? "an" : "aus"),
            ("Gebühr je Seite", "\(number(settings.feeBps, 1)) bp"),
        ]
        for (k, v) in rows { html += "<tr><th>\(escape(k))</th><td>\(escape(v))</td></tr>\n" }
        html += "</table>\n"
        html += "<p class=\"note\">Alle Zahlen stammen aus dem Papierhandel mit echten Marktdaten; es wurden keine echten Orders ausgeführt. Keine Anlageberatung.</p>\n"
        html += "</body></html>\n"
        return html
    }

    /// Einfaches Liniendiagramm als SVG (Bot und – falls vorhanden – Halten).
    static func svgChart(_ points: [EquityPoint], width: Double = 900, height: Double = 260) -> String {
        let pts = points.count > 800 ? stride(from: 0, to: points.count, by: points.count / 800 + 1).map { points[$0] } + [points[points.count - 1]] : points
        guard let t0 = pts.first?.t, let t1 = pts.last?.t, t1 > t0 else { return "" }
        var values = pts.map(\.equity)
        values += pts.compactMap(\.hold)
        guard var lo = values.min(), var hi = values.max() else { return "" }
        if hi - lo < 1e-9 { lo -= 1; hi += 1 }
        let pad = (hi - lo) * 0.08
        lo -= pad
        hi += pad
        let left = 8.0, right = 70.0, top = 10.0, bottom = 22.0
        func x(_ t: Double) -> Double { left + (t - t0) / (t1 - t0) * (width - left - right) }
        func y(_ v: Double) -> Double { top + (hi - v) / (hi - lo) * (height - top - bottom) }
        func path(_ list: [(Double, Double)]) -> String {
            list.enumerated().map { i, p in (i == 0 ? "M" : "L") + String(format: "%.1f,%.1f", x(p.0), y(p.1)) }.joined()
        }
        var svg = "<svg viewBox=\"0 0 \(Int(width)) \(Int(height))\" xmlns=\"http://www.w3.org/2000/svg\">"
        for k in 0...4 {
            let v = lo + (hi - lo) * Double(k) / 4
            svg += String(format: "<line x1=\"%.0f\" y1=\"%.1f\" x2=\"%.0f\" y2=\"%.1f\" stroke=\"#eee\"/>", left, y(v), width - right, y(v))
            svg += String(format: "<text x=\"%.0f\" y=\"%.1f\" font-size=\"11\" fill=\"#888\">%@</text>", width - right + 6, y(v) + 4, number(v, 2))
        }
        let holdPoints = pts.compactMap { p in p.hold.map { (p.t, $0) } }
        if holdPoints.count >= 2 {
            svg += "<path d=\"\(path(holdPoints))\" fill=\"none\" stroke=\"#f39c12\" stroke-width=\"1.4\" stroke-dasharray=\"5 4\"/>"
        }
        svg += "<path d=\"\(path(pts.map { ($0.t, $0.equity) }))\" fill=\"none\" stroke=\"#0a84ff\" stroke-width=\"2\"/>"
        svg += "</svg>"
        return svg
    }

    // MARK: Hilfen

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Zahl im deutschen Format (Komma).
    static func number(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    static func signed(_ v: Double, _ digits: Int = 2) -> String {
        (v > 0 ? "+" : (v < 0 ? "−" : "±")) + number(abs(v), digits)
    }

    static func cls(_ v: Double) -> String { v > 0 ? "pos" : (v < 0 ? "neg" : "") }
}
