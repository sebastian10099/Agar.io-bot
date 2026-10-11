import Foundation

/// Erkennt Anstiege ("von unten nach oben") und Faelle in den letzten 6/8/20/60 Minuten.
///
/// BingX Spot kann nicht shorten. Darum gibt es zwei Handlungen:
///  - nach einem Anstieg: `.sell`  (Bestand abbauen, nicht in den Pump hinein kaufen)
///  - nach einem Fall:    `.buy`   (nachkaufen)
/// Beides erst nach Bestaetigung durch die erste Gegen-Kerze (rot nach Pump, gruen nach Dump).
public enum MoveDirection: String, Codable, Sendable { case up, down }

public enum MoveAction: String, Codable, Sendable { case buy, sell }

public struct Move: Hashable, Sendable {
    public var windowMinutes: Int
    public var direction: MoveDirection
    /// Tief->Hoch (Anstieg) bzw. Hoch->Tief (Fall) in Prozent.
    public var movePercent: Double
    public var thresholdPercent: Double
    /// Wie viel der Bewegung der Kurs schon zurueckgegeben hat (0-100).
    public var retracePercent: Double
    public var startPrice: Double
    public var extremePrice: Double

    public var triggered: Bool { movePercent >= thresholdPercent }
    public var strength: Double { thresholdPercent > 0 ? movePercent / thresholdPercent : 0 }
}

public struct MoveSignal: Hashable, Sendable {
    public var action: MoveAction
    public var move: Move
    public var price: Double
    public var reason: String
}

public struct MoveDetector: Sendable {
    /// Fenster 6/8/20/60 Minuten mit steigenden Schwellen (laengere Fenster = groessere Bewegung).
    public static let defaultWindows: [MoveWindow] = [
        MoveWindow(minutes: 6, thresholdPercent: 1.5),
        MoveWindow(minutes: 8, thresholdPercent: 2.0),
        MoveWindow(minutes: 20, thresholdPercent: 3.0),
        MoveWindow(minutes: 60, thresholdPercent: 5.0),
    ]

    public var windows: [MoveWindow]
    public var candleMinutes: Int
    /// Erst handeln, wenn die letzte Kerze gegen die Bewegung schliesst.
    public var requireConfirmation: Bool
    /// Nicht mehr einsteigen, wenn die Gegenbewegung schon so weit gelaufen ist (%).
    public var maxRetracePercent: Double

    public init(windows: [MoveWindow] = MoveDetector.defaultWindows, candleMinutes: Int = 1,
                requireConfirmation: Bool = true, maxRetracePercent: Double = 60) {
        self.windows = windows
        self.candleMinutes = candleMinutes
        self.requireConfirmation = requireConfirmation
        self.maxRetracePercent = maxRetracePercent
    }

    public init(settings: BotSettings) {
        self.init(windows: settings.moveWindows, candleMinutes: 1,
                  requireConfirmation: settings.moveRequireConfirmation,
                  maxRetracePercent: settings.moveMaxRetracePercent)
    }

    // MARK: Messung

    /// Misst die dominante Bewegung in den letzten `windowCandles` Kerzen (ohne Speicherzuweisung).
    public static func measure(_ candles: [PriceCandle], windowCandles: Int, window: MoveWindow) -> Move? {
        let count = candles.count
        guard windowCandles >= 2, count >= 2 else { return nil }
        let n = min(windowCandles, count)
        let start = count - n

        var lowIndex = start
        var highIndex = start
        var low = candles[start].low
        var high = candles[start].high
        var i = start + 1
        while i < count {
            if candles[i].low < low { low = candles[i].low; lowIndex = i }
            if candles[i].high > high { high = candles[i].high; highIndex = i }
            i += 1
        }
        guard low > 0, high > low else { return nil }
        let close = candles[count - 1].close

        let up: Bool
        if lowIndex != highIndex {
            up = lowIndex < highIndex                  // Tief zuerst, dann Hoch = Anstieg
        } else {
            up = candles[highIndex].isGreen            // beides in einer Kerze: Farbe entscheidet
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
    public func analyze(_ candles: [PriceCandle]) -> [Move] {
        var result: [Move] = []
        result.reserveCapacity(windows.count)
        for window in windows {
            let n = max(2, Int((Double(window.minutes) / Double(max(1, candleMinutes))).rounded(.up)))
            if let m = MoveDetector.measure(candles, windowCandles: n, window: window) { result.append(m) }
        }
        return result
    }

    // MARK: Signal

    /// Staerkstes ausgeloestes und bestaetigtes Fenster, sonst `nil`.
    public func signal(_ candles: [PriceCandle]) -> MoveSignal? {
        signal(candles, moves: analyze(candles))
    }

    public func signal(_ candles: [PriceCandle], moves: [Move]) -> MoveSignal? {
        guard let last = candles.last, candles.count >= 2 else { return nil }
        var best: MoveSignal?
        for move in moves where move.triggered {
            let action: MoveAction = move.direction == .up ? .sell : .buy
            if requireConfirmation {
                if action == .sell && last.isGreen { continue }   // nicht in den laufenden Pump
                if action == .buy && !last.isGreen { continue }   // nicht ins fallende Messer
            }
            if move.retracePercent > maxRetracePercent { continue }
            if let b = best, b.move.strength >= move.strength { continue }
            let label = move.direction == .up ? "Anstieg +" : "Fall -"
            let reason = String(format: "%@%.2f%% in %ld min", label, move.movePercent, move.windowMinutes)
            best = MoveSignal(action: action, move: move, price: last.close, reason: reason)
        }
        return best
    }
}
