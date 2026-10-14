import Foundation

// MARK: - Einstellungs-Profile

extension BotSettings {
    /// Uebernimmt die Strategie-Werte von `other`; kontobezogene Werte (Startkapital, Gebuehren, Slippage) bleiben.
    /// So veraendert das Laden eines Profils weder das Papierkonto noch die Kostenannahmen des eigenen Kontos.
    public func adoptingStrategy(from other: BotSettings) -> BotSettings {
        var s = other
        s.startingUSDT = startingUSDT
        s.feeBps = feeBps
        s.makerFeeBps = makerFeeBps
        s.slippageBps = slippageBps
        return s.clamped()
    }
}

/// Gespeicherte Einstellungen unter einem Namen.
public struct SettingsProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: BotSettings
    public var createdAt: Double
    public var note: String

    public init(id: UUID = UUID(), name: String, settings: BotSettings, createdAt: Double, note: String = "") {
        self.id = id
        self.name = name
        self.settings = settings.clamped()
        self.createdAt = createdAt
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case id, name, settings, createdAt, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "Profil")
        settings = c.value(.settings, BotSettings()).clamped()
        createdAt = c.value(.createdAt, 0.0)
        note = c.value(.note, "")
    }
}

/// Alle gespeicherten Profile (Datei `profiles.json`).
public struct ProfileBook: Codable, Equatable, Sendable {
    public static let maxProfiles = 50

    public var version = 1
    public var profiles: [SettingsProfile] = []

    public init(profiles: [SettingsProfile] = []) { self.profiles = profiles }

    private enum CodingKeys: String, CodingKey { case version, profiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, 1)
        profiles = Array(c.value(.profiles, [SettingsProfile]()).prefix(Self.maxProfiles))
    }

    /// Speichert unter `name`. Ein Profil mit gleichem Namen (ohne Gross-/Kleinschreibung) wird ersetzt.
    @discardableResult
    public mutating func save(name rawName: String, settings: BotSettings, at now: Double, note: String = "") -> SettingsProfile {
        let name = Self.cleanName(rawName)
        if let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            profiles[i].settings = settings.clamped()
            profiles[i].createdAt = now
            if !note.isEmpty { profiles[i].note = note }
            return profiles[i]
        }
        let profile = SettingsProfile(name: name, settings: settings, createdAt: now, note: note)
        profiles.append(profile)
        if profiles.count > Self.maxProfiles { profiles.removeFirst(profiles.count - Self.maxProfiles) }
        return profile
    }

    /// Fuegt ein importiertes Profil hinzu; bei Namensgleichheit wird " (2)", " (3)" … angehaengt.
    @discardableResult
    public mutating func add(imported profile: SettingsProfile) -> SettingsProfile {
        var p = profile
        p.id = UUID()
        let base = Self.cleanName(p.name)
        var name = base
        var n = 2
        while profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) (\(n))"
            n += 1
        }
        p.name = name
        profiles.append(p)
        if profiles.count > Self.maxProfiles { profiles.removeFirst(profiles.count - Self.maxProfiles) }
        return p
    }

    public mutating func remove(_ id: UUID) { profiles.removeAll { $0.id == id } }

    static func cleanName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Profil" : trimmed
        return String(name.prefix(60))
    }
}

/// Austauschformat fuer eine einzelne Profildatei (zum Weitergeben).
public enum ProfileFile {
    public static let format = "gomining-bot-profile"
    public static let fileExtension = "json"

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var appVersion: String
        var profile: SettingsProfile
    }

    public static func encode(_ profile: SettingsProfile, appVersion: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(format: format, version: 1, appVersion: appVersion, profile: profile))
    }

    /// Liest eine Profildatei. Akzeptiert auch ein nacktes Profil oder nackte Einstellungen (z. B. aus einer Sicherung).
    public static func decode(_ data: Data, fallbackName: String = "Importiert", now: Double = Date().timeIntervalSince1970) -> SettingsProfile? {
        let decoder = JSONDecoder()
        guard SafeJSON.isWellFormed(data),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if root["profile"] != nil, let envelope = try? SafeJSON.decode(Envelope.self, from: data, decoder: decoder) {
            return envelope.profile
        }
        if root["settings"] is [String: Any], root["name"] != nil, let profile = try? SafeJSON.decode(SettingsProfile.self, from: data, decoder: decoder) {
            return profile
        }
        // Gesamte simulation.json oder nackte Einstellungen.
        if let settings = root["settings"] as? [String: Any],
           let raw = try? JSONSerialization.data(withJSONObject: settings),
           let s = try? SafeJSON.decode(BotSettings.self, from: raw, decoder: decoder) {
            return SettingsProfile(name: fallbackName, settings: s, createdAt: now)
        }
        let known = Set(["minNetProfitBps", "stopLossFraction", "maxTradeUSDT", "gridDropBps", "feeBps"])
        if !known.isDisjoint(with: root.keys), let s = try? SafeJSON.decode(BotSettings.self, from: data, decoder: decoder) {
            return SettingsProfile(name: fallbackName, settings: s, createdAt: now)
        }
        return nil
    }
}
