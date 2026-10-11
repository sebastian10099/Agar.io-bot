import Foundation

/// 10 statt 4 gleichzeitig offene Positionen.
///
/// `BotSettings.maxOpenPositions` ist in deiner App ein `Int?` (Optional). Bisher stand
/// dort bei neuen Einstellungen vermutlich 4 oder der Wert fehlte und es galt ein fester Wert im Engine-Code.
/// Ab jetzt gilt: gespeicherter Wert, sonst 10 - und die Engine fragt NUR noch `openPositionLimit` ab.
extension BotSettings {
    static let defaultMaxOpenPositions = 10

    /// Wirksames Limit (mindestens 1).
    var openPositionLimit: Int { max(1, maxOpenPositions ?? BotSettings.defaultMaxOpenPositions) }
}

enum PositionLimit {
    /// Kleine Hilfe, damit die Regel testbar bleibt, ohne die ganze Engine zu brauchen.
    static func canOpenAnother(openCount: Int, limit: Int) -> Bool { openCount < max(1, limit) }

    /// Gespeicherte Altwerte (4) einmalig anheben, ohne eine bewusst niedrigere Einstellung zu ueberschreiben:
    /// nur der alte Standard 4 wird zu 10.
    static func migrated(_ stored: Int?, oldDefault: Int = 4, newDefault: Int = 10) -> Int {
        guard let stored else { return newDefault }
        return stored == oldDefault ? newDefault : max(1, stored)
    }
}
