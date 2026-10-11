import Foundation
import GoMiningCore

/// Oeffentliche Marktdaten von BingX (REST). Keine Anmeldung noetig.
struct BingXPublicAPI: Sendable {
    let symbol: String
    private let session: URLSession
    private let base = "https://open-api.bingx.com"

    init(symbol: String = "GOMINING-USDT") {
        self.symbol = symbol
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": "GoMiningBotMac/4.0"]
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
    }

    func get(_ path: String, _ query: [String: String]) async throws -> Data {
        guard var comps = URLComponents(string: base + path) else { throw BingXError.invalidResponse }
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps.queryItems = items
        guard let url = comps.url else { throw BingXError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BingXError.api(code: code, message: "BingX antwortet nicht erfolgreich")
        }
        return data
    }

    func symbolRules() async throws -> SymbolRules {
        let data = try await get("/openApi/spot/v1/common/symbols", ["symbol": symbol])
        return try BingXParser.parseSymbolRules(data, symbol: symbol)
    }

    /// Die neuesten 1-Minuten-Kerzen (die letzte kann noch im Aufbau sein).
    func klines(limit: Int = 150) async throws -> [PriceCandle] {
        let data = try await get("/openApi/spot/v2/market/kline", ["symbol": symbol, "interval": "1m", "limit": String(limit)])
        return try BingXParser.parseKlines(data)
    }

    func depth(limit: Int = 20) async throws -> (bids: [PriceLevel], asks: [PriceLevel], sequence: Int64?) {
        let data = try await get("/openApi/spot/v1/market/depth", ["symbol": symbol, "limit": String(limit)])
        return try BingXParser.parseDepth(data)
    }

    func recentTrades(limit: Int = 100) async throws -> [PublicTrade] {
        let data = try await get("/openApi/spot/v1/market/trades", ["symbol": symbol, "limit": String(limit)])
        return try BingXParser.parseTrades(data)
    }

    /// Laedt Kerzen rueckwaerts in Seiten bis `start` (Unix-Sekunden). `progress` meldet 0...1.
    func history(from start: Double, progress: @Sendable (Double) -> Void) async throws -> [PriceCandle] {
        var all: [PriceCandle] = []
        let now = Date().timeIntervalSince1970
        var end = now
        var pages = 0
        while end > start, pages < 80 {
            try Task.checkCancellation()
            pages += 1
            let data = try await get("/openApi/spot/v2/market/kline", [
                "symbol": symbol, "interval": "1m", "limit": "1000", "endTime": String(Int(end * 1000)),
            ])
            let page: [PriceCandle]
            do {
                page = try BingXParser.parseKlines(data)
            } catch BingXError.missing {
                break
            } catch BingXError.api where !all.isEmpty {
                break    // z. B. 100204: aelter als 7 Tage ist nicht abrufbar - bisherige Seiten behalten
            }
            guard let oldest = page.first, oldest.openedAt < end - 30 else { break }
            all.append(contentsOf: page)
            progress(min(1, max(0, (now - oldest.openedAt) / max(1, now - start))))
            end = oldest.openedAt - 1
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        progress(1)
        return Indicators.normalize(all).filter { $0.openedAt >= start }
    }
}
