import Foundation

/// Erkennt Anstiege ("von unten nach oben") und Faelle in den letzten 6/8/20/60 Minuten.
/// Gleiche Logik wie gecko_mining/strategy.py und gecko_mining/js/movement.js.
///
/// BingX Spot kann nicht shorten. Darum gibt es zwei Handlungen:
///  - nach einem Anstieg:  `.sell`  (Bestand abbauen, nicht in den Pump hinein kaufen)
///  - nach einem Fall:     `.buy`   (nachkaufen)
/// Beides erst nach Bestaetigung durch die erste Gegen-Kerze (rot nach Pump, gruen nach Dump).
enum MoveDirection: String, Codable { case up, down }

enum MoveAction: String, Codable { case buy, sell }

struct MoveWindow: Hashable {
    var minutes: Int
    var thresholdPercent: Double
}

struct Move: Hashable {
    var windowMinutes: Int
    var direction: MoveDirection
    var movePercent: Double      // Tief->Hoch (Anstieg) bzw. Hoch->Tief (Fall) in %
    var thresholdPercent: Double
    var retracePercent: Double   // wie viel der Bewegung der Kurs schon zurueckgegeben hat
    var startPrice: Double
    var extremePrice: Double

    var triggered: Bool { movePercent >= thresholdPercent }
    var strength: Double { thresholdPercent > 0 ? movePercent / thresholdPercent : 0 }
}

struct MoveSignal: Hashable {
    var action: MoveAction
    var move: Move
    var price: Double
    var reason: String
}

struct MoveDetector {
    /// Fenster 6/8/20/60 Minuten mit steigenden Schwellen (laengere Fenster = groessere Bewegung).
    static let defaultWindows: [MoveWindow] = [
        MoveWindow(minutes: 6, thresholdPercent: 1.5),
        MoveWindow(minutes: 8, thresholdPercent: 2.0),
        MoveWindow(minutes: 20, thresholdPercent: 3.0),
        MoveWindow(minutes: 60, thresholdPercent: 5.0),
    ]

    var windows: [MoveWindow] = MoveDetector.defaultWindows
    var candleMinutes: Int = 1
    /// Erst handeln, wenn die letzte Kerze gegen die Bewegung schliesst.
    var requireConfirmation = true
    /// Nicht mehr einsteigen, wenn die Gegenbewegung schon so weit gelaufen ist (%).
    var maxRetracePercent = 60.0

    // MARK: - Messung

    /// Misst die Bewegung in den letzten `windowCandles` Kerzen.
    static func measure(_ candles: [PriceCandle], windowCandles: Int, window: MoveWindow) -> Move? {
        guard windowCandles >= 2, candles.count >= 2 else { return nil }
        let recent = Array(candles.suffix(windowCandles))
        guard let lowIndex = recent.indices.min(by: { recent[$0].low < recent[$1].low }),
              let highIndex = recent.indices.max(by: { recent[$0].high < recent[$1].high }),
              let close = recent.last?.close
        else { return nil }
        let low = recent[lowIndex].low
        let high = recent[highIndex].high
        guard low > 0, high > low else { return nil }

        let up: Bool
        if lowIndex != highIndex {
            up = lowIndex < highIndex                 // Tief zuerst, dann Hoch = Anstieg
        } else {
            up = recent[highIndex].isGreen            // beides in einer Kerze: Farbe entscheidet
        }
        if up {
            return Move(windowMinutes: window.minutes, direction: .up,
                        movePercent: (high - low) / low * 100,
                        thresholdPercent: window.thresholdPercent,
                        retracePercent: (high - close) / (high - low) * 100,
                        startPrice: low, extremePrice: high)
        }
        return Move(windowMinutes: window.minutes, direction: .down,
                    movePercent: (high - low) / high * 100,
                    thresholdPercent: window.thresholdPercent,
                    retracePercent: (close - low) / (high - low) * 100,
                    startPrice: high, extremePrice: low)
    }

    /// Alle Fenster (auch die ohne Signal) - fuer Anzeige und Chart-Schattierung.
    func analyze(_ candles: [PriceCandle]) -> [Move] {
        windows.compactMap { window in
            let n = max(2, Int((Double(window.minutes) / Double(max(1, candleMinutes))).rounded(.up)))
            return MoveDetector.measure(candles, windowCandles: n, window: window)
        }
    }

    // MARK: - Signal

    /// Staerkstes ausgeloestes und bestaetigtes Fenster, sonst `nil`.
    func signal(_ candles: [PriceCandle]) -> MoveSignal? {
        guard let last = candles.last, candles.count >= 2 else { return nil }
        var best: MoveSignal?
        for move in analyze(candles) where move.triggered {
            let action: MoveAction = move.direction == .up ? .sell : .buy
            if requireConfirmation {
                if action == .sell && last.isGreen { continue }   // nicht in den laufenden Pump
                if action == .buy && !last.isGreen { continue }   // nicht ins fallende Messer
            }
            if move.retracePercent > maxRetracePercent { continue }
            if let b = best, b.move.strength >= move.strength { continue }
            let label = move.direction == .up ? "Anstieg +" : "Fall -"
            let reason = String(format: "%@%.2f%% in %d min", label, move.movePercent, move.windowMinutes)
            best = MoveSignal(action: action, move: move, price: last.close, reason: reason)
        }
        return best
    }
}
