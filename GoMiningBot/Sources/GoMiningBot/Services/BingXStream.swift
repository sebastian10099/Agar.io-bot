import Foundation
import GoMiningCore

/// Livestream von BingX (WebSocket): Trades und Orderbuch (20 Stufen).
/// Verbindet sich bei Abbruch selbststaendig neu (Wartezeit 1, 2, 4 ... max. 30 s) und trennt
/// eine Verbindung, die 25 s lang nichts geliefert hat.
final class BingXStream: @unchecked Sendable {
    private let symbol: String
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private var lastMessageAt = Date()

    init(symbol: String) {
        self.symbol = symbol
        session = URLSession(configuration: .ephemeral)
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func touch() {
        lock.lock(); lastMessageAt = Date(); lock.unlock()
    }

    private var silence: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastMessageAt)
    }

    private func setTask(_ t: URLSessionWebSocketTask?) {
        lock.lock(); task = t; lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let t = task
        lock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
    }

    /// Erzwingt eine neue Verbindung (z. B. nach dem Aufwachen aus dem Ruhezustand).
    func reconnect() {
        lock.lock(); let t = task; lock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
    }

    func run(onEvent: @escaping @Sendable (StreamEvent) -> Void, onStatus: @escaping @Sendable (String) -> Void) async {
        var attempt = 0
        while !Task.isCancelled, !isStopped {
            do {
                onStatus(attempt == 0 ? "BingX-Livestream verbindet …" : "BingX-Livestream verbindet erneut …")
                try await listen(onEvent: onEvent, onStatus: onStatus, attempt: &attempt)
            } catch {
                if Task.isCancelled || isStopped { break }
                onStatus("Livestream unterbrochen: \(error.localizedDescription)")
            }
            attempt += 1
            let delay = min(30.0, 0.5 * pow(2.0, Double(min(attempt, 6))))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func subscribe(_ ws: URLSessionWebSocketTask, _ dataType: String) async throws {
        let payload: [String: Any] = ["id": UUID().uuidString, "reqType": "sub", "dataType": dataType]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func listen(onEvent: @escaping @Sendable (StreamEvent) -> Void,
                        onStatus: @escaping @Sendable (String) -> Void,
                        attempt: inout Int) async throws {
        guard let url = URL(string: "wss://open-api-ws.bingx.com/market") else { return }
        let ws = session.webSocketTask(with: url)
        ws.maximumMessageSize = 4 * 1024 * 1024
        setTask(ws)
        touch()
        ws.resume()
        try await subscribe(ws, "\(symbol)@trade")
        try await subscribe(ws, "\(symbol)@depth20")

        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if self.silence > 25 {
                    ws.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            ws.cancel(with: .goingAway, reason: nil)
            setTask(nil)
        }

        var receivedAny = false
        while !Task.isCancelled, !isStopped {
            let message = try await ws.receive()
            touch()
            let data: Data
            switch message {
            case .data(let d):
                guard let decoded = Gzip.decode(d) else {
                    onStatus("Livestream-Dekompression fehlgeschlagen")
                    continue
                }
                data = decoded
            case .string(let s):
                data = Data(s.utf8)
            @unknown default:
                continue
            }
            if !receivedAny {
                receivedAny = true
                attempt = 0
                onStatus("BingX-Livestream aktiv")
            }
            let event = BingXParser.parseStream(data)
            if case .ping = event {
                try await ws.send(.string("Pong"))
                continue
            }
            onEvent(event)
        }
    }
}
