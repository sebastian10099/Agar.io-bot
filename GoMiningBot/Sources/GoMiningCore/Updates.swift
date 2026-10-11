import Foundation

/// Versionsnummer wie "4.1" oder "4.10.2" (numerischer Vergleich je Teil).
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "gomining-bot-v4.1" oder "v4.1" -> "4.1"
        if let range = trimmed.range(of: "v", options: .backwards), trimmed[range.upperBound...].first?.isNumber == true {
            trimmed = String(trimmed[range.upperBound...])
        }
        let parts = trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let n = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<n {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// Veroeffentlichte Version auf GitHub.
public struct ReleaseInfo: Sendable, Equatable {
    public var version: AppVersion
    public var tag: String
    public var pageURL: URL
    public var downloadURL: URL?
    public var notes: String
    public var publishedAt: String

    public static func == (lhs: ReleaseInfo, rhs: ReleaseInfo) -> Bool { lhs.tag == rhs.tag }
}

public enum ReleaseParser {
    public static let assetName = "GoMining-Bot.zip"

    /// Liest die Antwort von `GET /repos/{owner}/{repo}/releases/latest`.
    public static func parseLatest(_ data: Data) -> ReleaseInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let version = AppVersion(tag),
              let page = (root["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        if (root["draft"] as? Bool) == true { return nil }
        var download: URL?
        for asset in (root["assets"] as? [[String: Any]]) ?? [] where (asset["name"] as? String) == assetName {
            download = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        return ReleaseInfo(version: version, tag: tag, pageURL: page, downloadURL: download,
                           notes: (root["body"] as? String) ?? "", publishedAt: (root["published_at"] as? String) ?? "")
    }

    /// Abschnitt einer Version aus CHANGELOG.md ("## 4.1 ..." bis zur naechsten "## "-Zeile).
    public static func changelogSection(_ markdown: String, version: String) -> String? {
        var collecting = false
        var lines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if collecting { break }
                let heading = line.dropFirst(3)
                if heading == Substring(version) || heading.hasPrefix(version + " ") { collecting = true; continue }
            } else if collecting {
                lines.append(line)
            }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Tauscht die laufende App gegen die heruntergeladene aus, nachdem sie beendet wurde.
/// Bei einem Fehler bleibt die alte App erhalten.
public enum UpdateInstaller {
    /// Argumente: PID der laufenden App, Pfad der neuen App, Pfad der zu ersetzenden App, "open" oder "noopen".
    public static let script = """
    #!/bin/sh
    PID="$1"; NEW="$2"; TARGET="$3"; MODE="$4"
    case "$TARGET" in *.app) ;; *) exit 1 ;; esac
    case "$NEW" in *.app) ;; *) exit 1 ;; esac
    [ -d "$NEW" ] || exit 1
    i=0
    while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
    BACKUP="$TARGET.vor-update"
    /bin/rm -rf "$BACKUP"
    if /bin/mv "$TARGET" "$BACKUP" && /usr/bin/ditto "$NEW" "$TARGET"; then
      /bin/rm -rf "$BACKUP"
    else
      /bin/rm -rf "$TARGET"
      /bin/mv "$BACKUP" "$TARGET"
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    [ "$MODE" = "open" ] && /usr/bin/open "$TARGET"
    exit 0
    """

    /// Prueft, ob ein automatischer Austausch an diesem Ort moeglich ist.
    public static func canReplace(appAt url: URL) -> Bool {
        let path = url.path
        guard url.pathExtension == "app", !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/") else { return false }
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: path)
    }
}
