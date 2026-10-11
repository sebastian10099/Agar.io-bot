import Foundation

/// 1-Minuten-Kerze von BingX - jetzt mit Eroeffnung, Hoch und Tief.
///
/// ERSETZT die bisherige `PriceCandle` (die nur `openedAt`, `close`, `volume` hatte).
/// - Der alte Initialisierer `PriceCandle(openedAt:close:volume:)` funktioniert weiter.
/// - Alte gespeicherte Daten ohne open/high/low werden weiterhin geladen
///   (open/high/low = close), es geht also nichts verloren.
struct PriceCandle: Codable, Hashable {
    var openedAt: Double
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var volume: Double

    /// Gruene Kerze: Schluss >= Eroeffnung.
    var isGreen: Bool { close >= open }

    /// `true`, wenn die Kerze nur einen Schlusskurs kennt (alte Daten).
    var isCloseOnly: Bool { open == close && high == close && low == close }

    init(openedAt: Double, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.openedAt = openedAt
        self.open = open
        self.high = max(high, open, close)
        self.low = min(low, open, close)
        self.close = close
        self.volume = volume
    }

    /// Kompatibel zum bisherigen Aufruf ohne OHLC.
    init(openedAt: Double, close: Double, volume: Double) {
        self.init(openedAt: openedAt, open: close, high: close, low: close, close: close, volume: volume)
    }

    /// Eine Zeile aus `/openApi/spot/v2/market/kline`:
    /// `[openTime, open, high, low, close, volume, closeTime, quoteVolume]`.
    /// Werte duerfen Zahlen oder Strings sein. `openedAt` wird wie `openTime`
    /// uebernommen geteilt durch `openedAtDivisor` - Standard 1000 (ms -> Sekunden).
    /// Speichert deine App `openedAt` bisher in Millisekunden, `openedAtDivisor: 1` uebergeben.
    init?(bingXRow row: [Any], openedAtDivisor: Double = 1000) {
        guard row.count >= 6,
              let time = PriceCandle.number(row[0]),
              let open = PriceCandle.number(row[1]),
              let high = PriceCandle.number(row[2]),
              let low = PriceCandle.number(row[3]),
              let close = PriceCandle.number(row[4]),
              let volume = PriceCandle.number(row[5]),
              open > 0, high > 0, low > 0, close > 0
        else { return nil }
        self.init(openedAt: time / openedAtDivisor, open: open, high: high, low: low, close: close, volume: volume)
    }

    private static func number(_ value: Any) -> Double? {
        if let d = value as? Double { return d.isFinite ? d : nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d.isFinite ? d : nil }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case openedAt, open, high, low, close, volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let openedAt = try c.decode(Double.self, forKey: .openedAt)
        let close = try c.decode(Double.self, forKey: .close)
        let volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0
        let open = try c.decodeIfPresent(Double.self, forKey: .open) ?? close
        let high = try c.decodeIfPresent(Double.self, forKey: .high) ?? max(open, close)
        let low = try c.decodeIfPresent(Double.self, forKey: .low) ?? min(open, close)
        self.init(openedAt: openedAt, open: open, high: high, low: low, close: close, volume: volume)
    }
}
