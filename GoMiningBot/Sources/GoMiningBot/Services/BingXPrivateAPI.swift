import Foundation
import GoMiningCore

/// Signierte Lese-Abfragen (Konto-ID, Guthaben, Gebuehrensatz). Es werden keine Orders gesendet.
struct BingXPrivateAPI: Sendable {
    private let session: URLSession
    private let base = "https://open-api.bingx.com"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "GoMiningBotMac/4.0"]
        session = URLSession(configuration: config)
    }

    func signedGet(_ path: String, credentials: BingXCredentials, extra: [String: String] = [:]) async throws -> Data {
        var params = extra
        params["timestamp"] = String(Int(Date().timeIntervalSince1970 * 1000))
        params["recvWindow"] = "5000"
        let query = BingXSigner.canonicalQuery(params)
        let signature = BingXSigner.signature(query: query, secret: credentials.secretKey)
        guard let url = URL(string: "\(base)\(path)?\(query)&signature=\(signature)") else { throw BingXError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue(credentials.apiKey, forHTTPHeaderField: "X-BX-APIKEY")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // BingX liefert bei Fehlern meist trotzdem JSON mit einer Meldung.
            if let root = try? BingXParser.object(data), let msg = root["msg"] as? String {
                throw BingXError.api(code: http.statusCode, message: msg)
            }
            throw BingXError.api(code: http.statusCode, message: "BingX antwortet nicht erfolgreich")
        }
        return data
    }

    /// Prueft Schluessel und Signatur ueber die Konto-ID. Gibt die UID zurueck.
    func testReadOnly(_ credentials: BingXCredentials) async throws -> String {
        let data = try await signedGet("/openApi/account/v1/uid", credentials: credentials)
        let root = try BingXParser.object(data)
        guard let payload = try BingXParser.dataField(root) as? [String: Any], let uid = payload["uid"] else {
            throw BingXError.missing("BingX hat die Verbindung nicht bestätigt")
        }
        return "\(uid)"
    }

    func spotBalances(_ credentials: BingXCredentials) async throws -> [BingXParser.SpotBalance] {
        let data = try await signedGet("/openApi/spot/v1/account/balance", credentials: credentials)
        return try BingXParser.parseBalances(data)
    }

    func spotCommission(_ credentials: BingXCredentials, symbol: String) async throws -> BingXParser.SpotCommission {
        let data = try await signedGet("/openApi/spot/v1/user/commissionRate", credentials: credentials, extra: ["symbol": symbol])
        return try BingXParser.parseCommission(data)
    }
}
