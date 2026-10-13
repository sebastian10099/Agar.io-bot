import Foundation
import GoMiningCore

/// Ab 4.1.1 hat die App eine eigene Identitaet ("GoMining Bot Pro", eigene Bundle-ID, eigener Datenordner).
/// Bis 4.1 teilte sie Name und Bundle-ID mit der alten App 3.9 – macOS hat die beiden deshalb verwechselt und beim
/// Oeffnen oft die alte App gestartet. Beim ersten Start werden Papierkonto und Einstellungen einmalig uebernommen.
enum AppMigration {
    static let legacyBundleIdentifier = "com.sebastian.gominingbot"
    private static let doneKey = "importedFromGoMiningBot"
    /// Einstellungen, die aus der bisherigen Bundle-ID uebernommen werden.
    private static let preferenceKeys = ["notifyTrades", "notifyStops", "notifyLimits", "soundEnabled", "showMenuBar",
                                         "chartMinutes", "journalDays", "autoCheckUpdates", "priceAlerts", "dailySummary"]

    /// Muss vor dem ersten Lesen von Einstellungen und Datenordner laufen. Mehrfacher Aufruf ist harmlos.
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        if Bundle.main.bundleIdentifier != legacyBundleIdentifier,
           let old = defaults.persistentDomain(forName: legacyBundleIdentifier) {
            for key in preferenceKeys where defaults.object(forKey: key) == nil {
                if let value = old[key] { defaults.set(value, forKey: key) }
            }
        }
        if AppPaths.overrideRoot == nil {
            AppPaths.importLegacyData(from: AppPaths.legacyRoot, to: AppPaths.standard().root)
        }
    }
}
