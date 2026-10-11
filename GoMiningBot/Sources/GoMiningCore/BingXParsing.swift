import Foundation
import CryptoKit

public enum BingXError: Error, LocalizedError, Equatable {
    case invalidResponse
    case api(code: Int, message: String)
    case missing(String)
    case inactive(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "BingX meldet einen Datenfehler"
        case .api(let code, let message): return "BingX-Fehler \(code): \(message)"
        case .missing(let what): return what
        case .inactive(let symbol): return "\(symbol) ist bei BingX nicht aktiv"
        }
    }
}

public enum StreamEvent: Sendable {
    case ping
    case ack
    case trades([PublicTrade])
    case depth(bids: [PriceLevel], asks: [PriceLevel], sequence: Int64?)
    case error(String)
    case unknown
}

/// Liest die JSON-Antworten von BingX. Die Parser sind bewusst tolerant: Zahlen duerfen Strings sein,
/// Kerzen duerfen als Listen oder Objekte kommen, Zeitstempel in Millisekunden oder Sekunden.
public enum BingXParser {
    // MARK: Helfer

    public static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d.isFinite ? d : nil
        case let i as Int: return Double(i)
        case let i as Int64: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            guard let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
            return d
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Millisekunden werden zu Sekunden.
    static func seconds(_ raw: Double) -> Double { raw > 1e11 ? raw / 1000 : raw }

    public static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any] else { throw BingXError.invalidResponse }
        return root
    }

    /// Prueft `code` und liefert `data`.
    public static func dataField(_ root: [String: Any]) throws -> Any? {
        if let code = number(root["code"]), Int(code) != 0 {
            throw BingXError.api(code: Int(code), message: (root["msg"] as? String) ?? "unbekannt")
        }
        return root["data"]
    }

    // MARK: Symbol-Regeln

    public static func parseSymbolRules(_ data: Data, symbol: String) throws -> SymbolRules {
        let root = try object(data)
        let payload = try dataField(root)
        var entries: [[String: Any]] = []
        if let dict = payload as? [String: Any], let list = dict["symbols"] as? [[String: Any]] { entries = list }
        else if let list = payload as? [[String: Any]] { entries = list }
        guard let entry = entries.first(where: { ($0["symbol"] as? String)?.uppercased() == symbol.uppercased() }) ?? entries.first else {
            throw BingXError.inactive(symbol)
        }
        if let status = entry["status"] {
            let active: Bool
            if let n = number(status) { active = Int(n) == 1 }
            else if let s = status as? String { active = ["online", "trading", "active"].contains(s.lowercased()) }
            else { active = true }
            if !active { throw BingXError.inactive(symbol) }
        }
        let buy = bool(entry["apiStateBuy"]) ?? true
        let sell = bool(entry["apiStateSell"]) ?? true
        let minQty = number(entry["minQty"])
        let minNotional = number(entry["minNotional"])
        var step = number(entry["stepSize"]) ?? 0
        if step <= 0, let q = minQty, q > 0 { step = q }
        if step <= 0 { step = 0.0001 }
        let verified = (minQty != nil || minNotional != nil)
        return SymbolRules(minQuantity: minQty ?? 0, minNotional: minNotional ?? SymbolRules.fallback.minNotional,
                           stepSize: step, buyEnabled: buy, sellEnabled: sell, verified: verified)
    }

    // MARK: Kerzen

    public static func parseKlines(_ data: Data) throws -> [PriceCandle] {
        let root = try object(data)
        guard let rows = try dataField(root) as? [Any], !rows.isEmpty else { throw BingXError.missing("Kurskerzen fehlen") }
        var arrays: [[Double]] = []
        var candles: [PriceCandle] = []
        for row in rows {
            if let list = row as? [Any] {
                let nums = list.map { number($0) }
                guard nums.count >= 6, let t = nums[0] else { continue }
                var values = [t]
                var ok = true
                for k in 1...5 { if let v = nums[k] { values.append(v) } else { ok = false } }
                if ok { arrays.append(values) }
            } else if let dict = row as? [String: Any] {
                let t = number(dict["time"] ?? dict["openTime"] ?? dict["t"] ?? dict["T"])
                guard let time = t,
                      let o = number(dict["open"] ?? dict["o"]), let h = number(dict["high"] ?? dict["h"]),
                      let l = number(dict["low"] ?? dict["l"]), let c = number(dict["close"] ?? dict["c"]) else { continue }
                let v = number(dict["volume"] ?? dict["v"]) ?? 0
                if o > 0, h > 0, l > 0, c > 0 {
                    candles.append(PriceCandle(openedAt: seconds(time), open: o, high: h, low: l, close: c, volume: v))
                }
            }
        }
        if !arrays.isEmpty {
            // Spaltenreihenfolge pruefen: Standard [t, open, high, low, close, volume]; manche Schnittstellen
            // liefern [t, open, close, high, low, volume]. Die Variante mit den wenigsten Widerspruechen gewinnt.
            func violations(_ o: Int, _ h: Int, _ l: Int, _ c: Int) -> Int {
                arrays.reduce(0) { acc, r in
                    acc + ((r[h] < max(r[o], r[c]) - 1e-12 || r[l] > min(r[o], r[c]) + 1e-12) ? 1 : 0)
                }
            }
            let standard = violations(1, 2, 3, 4)
            let alternative = violations(1, 3, 4, 2)
            let useAlternative = alternative < standard
            for r in arrays {
                let (o, h, l, c) = useAlternative ? (r[1], r[3], r[4], r[2]) : (r[1], r[2], r[3], r[4])
                guard o > 0, h > 0, l > 0, c > 0 else { continue }
                candles.append(PriceCandle(openedAt: seconds(r[0]), open: o, high: h, low: l, close: c, volume: r[5]))
            }
        }
        let sorted = Indicators.normalize(candles)
        guard !sorted.isEmpty else { throw BingXError.missing("Kurskerzen fehlen") }
        return sorted
    }

    // MARK: Orderbuch

    static func levels(_ raw: Any?) -> [PriceLevel] {
        guard let list = raw as? [Any] else { return [] }
        var result: [PriceLevel] = []
        result.reserveCapacity(list.count)
        for item in list {
            if let pair = item as? [Any], pair.count >= 2, let p = number(pair[0]), let q = number(pair[1]), p > 0, q > 0 {
                result.append(PriceLevel(price: p, quantity: q))
            } else if let dict = item as? [String: Any],
                      let p = number(dict["price"] ?? dict["p"]), let q = number(dict["quantity"] ?? dict["qty"] ?? dict["q"]),
                      p > 0, q > 0 {
                result.append(PriceLevel(price: p, quantity: q))
            }
        }
        return result
    }

    static func book(from dict: [String: Any]) -> (bids: [PriceLevel], asks: [PriceLevel], sequence: Int64?) {
        let bids = levels(dict["bids"] ?? dict["b"]).sorted { $0.price > $1.price }
        let asks = levels(dict["asks"] ?? dict["a"]).sorted { $0.price < $1.price }
        let seq = number(dict["lastUpdateId"] ?? dict["u"] ?? dict["ts"]).map { Int64($0) }
        return (bids, asks, seq)
    }

    public static func parseDepth(_ data: Data) throws -> (bids: [PriceLevel], asks: [PriceLevel], sequence: Int64?) {
        let root = try object(data)
        guard let dict = try dataField(root) as? [String: Any] else { throw BingXError.missing("Orderbuch fehlt") }
        let b = book(from: dict)
        guard !b.bids.isEmpty, !b.asks.isEmpty else { throw BingXError.missing("Orderbuch leer") }
        return b
    }

    // MARK: Trades

    static func trade(from dict: [String: Any]) -> PublicTrade? {
        guard let price = number(dict["price"] ?? dict["p"]), let qty = number(dict["qty"] ?? dict["quantity"] ?? dict["q"]),
              price > 0, qty > 0 else { return nil }
        let time = number(dict["time"] ?? dict["T"] ?? dict["E"] ?? dict["ts"]) ?? Date().timeIntervalSince1970
        let id = number(dict["id"] ?? dict["tradeId"] ?? dict["t"]).map { Int64($0) } ?? Int64(time * 1000)
        // buyerMaker == true: der Kaeufer war der passive Teil, also hat ein Verkaeufer zugeschlagen.
        let buyerMaker = bool(dict["buyerMaker"] ?? dict["m"] ?? dict["isBuyerMaker"]) ?? false
        return PublicTrade(id: id, at: seconds(time), price: price, quantity: qty, buyerInitiated: !buyerMaker)
    }

    public static func parseTrades(_ data: Data) throws -> [PublicTrade] {
        let root = try object(data)
        let raw = try dataField(root)
        var items: [[String: Any]] = []
        if let list = raw as? [[String: Any]] { items = list }
        else if let dict = raw as? [String: Any], let list = dict["trades"] as? [[String: Any]] { items = list }
        let trades = items.compactMap { trade(from: $0) }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        guard !trades.isEmpty else { throw BingXError.missing("Öffentliche Trades fehlen") }
        return trades
    }

    // MARK: Livestream

    public static func parseStream(_ data: Data) -> StreamEvent {
        if let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ping" {
            return .ping
        }
        guard let root = try? object(data) else { return .unknown }
        if let code = number(root["code"]), Int(code) != 0 {
            return .error((root["msg"] as? String) ?? "Fehlercode \(Int(code))")
        }
        guard let type = root["dataType"] as? String else {
            return root["id"] != nil ? .ack : .unknown
        }
        let body = root["data"]
        if type.hasSuffix("@trade") {
            var items: [[String: Any]] = []
            if let d = body as? [String: Any] { items = [d] }
            else if let l = body as? [[String: Any]] { items = l }
            let trades = items.compactMap { trade(from: $0) }
            return trades.isEmpty ? .unknown : .trades(trades)
        }
        if type.contains("@depth") {
            guard let d = body as? [String: Any] else { return .unknown }
            let b = book(from: d)
            guard !b.bids.isEmpty, !b.asks.isEmpty else { return .unknown }
            return .depth(bids: b.bids, asks: b.asks, sequence: b.sequence)
        }
        return .unknown
    }

    // MARK: Konto (nur Lesen)

    public struct SpotBalance: Hashable, Sendable, Identifiable {
        public var asset: String
        public var free: Double
        public var locked: Double
        public var id: String { asset }
        public var total: Double { free + locked }
    }

    public struct SpotCommission: Hashable, Sendable {
        public var takerRate: Double
        public var makerRate: Double
        public var takerBps: Double { takerRate * 10_000 }
        public var makerBps: Double { makerRate * 10_000 }
    }

    public static func parseBalances(_ data: Data) throws -> [SpotBalance] {
        let root = try object(data)
        let raw = try dataField(root)
        var list: [[String: Any]] = []
        if let dict = raw as? [String: Any], let l = dict["balances"] as? [[String: Any]] { list = l }
        else if let l = raw as? [[String: Any]] { list = l }
        else { throw BingXError.missing("BingX-Guthaben fehlt") }
        return list.compactMap { item in
            guard let asset = item["asset"] as? String else { return nil }
            return SpotBalance(asset: asset, free: number(item["free"]) ?? 0, locked: number(item["locked"]) ?? 0)
        }
    }

    public static func parseCommission(_ data: Data) throws -> SpotCommission {
        let root = try object(data)
        let raw = try dataField(root)
        guard let dict = raw as? [String: Any] else { throw BingXError.missing("BingX-Gebühren fehlen") }
        let inner = (dict["commission"] as? [String: Any]) ?? dict
        guard let taker = number(inner["takerCommissionRate"]) else { throw BingXError.missing("BingX-Gebühren fehlen") }
        return SpotCommission(takerRate: taker, makerRate: number(inner["makerCommissionRate"]) ?? taker)
    }
}

// MARK: - Signatur (nur Lesezugriff auf das Konto)

public struct BingXCredentials: Codable, Equatable, Sendable {
    public var apiKey: String
    public var secretKey: String

    public init(apiKey: String, secretKey: String) {
        self.apiKey = apiKey
        self.secretKey = secretKey
    }
}

public enum BingXSigner {
    /// HMAC-SHA256 ueber den Query-String, hexadezimal (kleingeschrieben).
    public static func signature(query: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(query.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Alphabetisch sortierter Query-String `a=1&b=2`.
    public static func canonicalQuery(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }.joined(separator: "&")
    }
}
