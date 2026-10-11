import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoMiningCore

private struct LiveBook {
    var bids: [PriceLevel] = []
    var asks: [PriceLevel] = []
    /// Lokaler Empfangszeitpunkt.
    var at: Double = 0
}

/// Verbindet Datenquellen (Livestream, REST), Engine, Speicher und Oberflaeche.
@MainActor
final class AppController: ObservableObject {
    static let symbol = "GOMINING-USDT"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0"

    let market = MarketStore()
    let bot: BotStore
    let status = StatusStore()
    let backtest = BacktestStore()
    let prefs = Preferences()
    let paths: AppPaths

    private let stateStore: StateStore
    private let journal: MarketJournal
    private let api: BingXPublicAPI
    private let privateAPI = BingXPrivateAPI()
    private let stream: BingXStream

    // Live-Daten (nicht veroeffentlicht)
    private var book = LiveBook()
    private var rules = SymbolRules.fallback
    private var restCandles: [PriceCandle] = []
    private var candlesFetchedAt = 0.0
    private var trades: [PublicTrade] = []
    private var seenTradeIDs = Set<Int64>()
    private var clockOffset: Double?
    private var detector = FastMoveDetector()
    private var history: [PriceCandle] = []
    private var equity = EquityHistory()
    private var credentials: BingXCredentials?

    // Takt und Zustand
    private var started = false
    private var tasks: [Task<Void, Never>] = []
    private var activity: NSObjectProtocol?
    private var lastStreamAt = 0.0
    private var lastEvaluateAt = 0.0
    private var evaluatePending = false
    private var saveTask: Task<Void, Never>?
    private var lastJournalAt = 0.0
    private var lastJournalFlush = 0.0
    private var lastCachePersist = 0.0
    private var lastPrune = 0.0
    private var lastLongRebuild = 0.0
    private var lastLimitNoticeDay = ""
    private var lastDecisionKey = ""

    init() {
        let paths = AppPaths.standard()
        try? paths.prepare()
        let store = StateStore(paths: paths)
        let outcome = store.load()
        let now = Date().timeIntervalSince1970
        let stored = outcome.stored ?? StoredBot.fresh(at: now, seedStartPosition: true)
        self.paths = paths
        stateStore = store
        bot = BotStore(stored: stored)
        api = BingXPublicAPI(symbol: Self.symbol)
        stream = BingXStream(symbol: Self.symbol)
        let days = UserDefaults.standard.integer(forKey: "journalDays")
        journal = MarketJournal(directory: paths.journalDirectory, legacyDirectory: paths.legacyJournalDirectory,
                                retentionDays: days == 0 ? 7 : days)

        status.notice = outcome.note
        if let saved = JSONFile.read(EquityHistory.self, from: paths.equityFile) {
            equity = saved
            bot.equityHistory = saved.points
        }
        if let cache = JSONFile.read(CandleCache.self, from: paths.candleCacheFile) {
            history = cache.candles
        }
        bot.recomputeStats()
        status.journal = journal.status
    }

    private func nowTs() -> Double { Date().timeIntervalSince1970 }

    // MARK: - Start und Ende

    func start() {
        guard !started else { return }
        started = true
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "GoMining Bot beobachtet den Markt")
        Notifier.shared.requestAuthorizationIfNeeded()
        observeSystem()
        loadCredentials()
        status.dataFolderBytes = journal.diskUsageBytes()
        tasks.append(Task { [weak self] in await self?.bootstrap() })
        scheduleSmokeReportIfRequested()
    }

    /// Rauchtest fuer die CI: Mit `GOMINING_SMOKE_OUT=<Datei>` schreibt die App nach 25 s einen Bericht
    /// (Verbindung, Livestream, Marktdaten, Fehler) und beendet sich.
    private func scheduleSmokeReportIfRequested() {
        guard let out = ProcessInfo.processInfo.environment["GOMINING_SMOKE_OUT"], !out.isEmpty else { return }
        tasks.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self else { return }
            let report = self.diagnosticsText()
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        })
    }

    private func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWake() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    private func handleWake() {
        status.connection = "Nach dem Ruhezustand: Marktdaten werden erneuert …"
        stream.reconnect()
        Task {
            await refreshCandles()
            await refreshBookAndTrades()
        }
    }

    /// Beim Beenden: alles sicher auf die Platte.
    func shutdown() {
        stream.stop()
        tasks.forEach { $0.cancel() }
        saveTask?.cancel()
        try? stateStore.save(bot.stored)
        try? JSONFile.write(equity, to: paths.equityFile)
        try? JSONFile.write(CandleCache(candles: history), to: paths.candleCacheFile)
        journal.flushAndWait()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    private func bootstrap() async {
        await refreshRules()
        await refreshCandles()
        await refreshBookAndTrades()
        startStream()
        startLoops()
        evaluate()
    }

    // MARK: - Datenquellen

    private func refreshRules() async {
        do {
            rules = try await api.symbolRules()
            status.rulesVerified = rules.verified
        } catch {
            status.note("Handelsregeln", error)
            status.connection = "Marktdaten eingeschränkt: \(error.localizedDescription)"
        }
    }

    private func refreshCandles() async {
        do {
            let fetched = try await api.klines(limit: 150)
            restCandles = Indicators.fillGaps(fetched)
            candlesFetchedAt = nowTs()
            Indicators.mergeTail(&history, fetched)
            status.connection = "BingX-Marktdaten verbunden"
            scheduleEvaluate()
        } catch {
            status.note("Kerzen", error)
            status.connection = "Marktdaten eingeschränkt: \(error.localizedDescription)"
        }
    }

    private func refreshBookAndTrades() async {
        async let depth = api.depth()
        async let recent = api.recentTrades(limit: 100)
        do {
            let d = try await depth
            book = LiveBook(bids: Array(d.bids.prefix(20)), asks: Array(d.asks.prefix(20)), at: nowTs())
        } catch {
            status.note("Orderbuch", error)
            status.connection = "Marktdaten eingeschränkt: \(error.localizedDescription)"
        }
        if let t = try? await recent { ingest(t, live: false) }
        scheduleEvaluate()
    }

    private func startStream() {
        let (events, continuation) = AsyncStream<StreamEvent>.makeStream(bufferingPolicy: .bufferingNewest(2_000))
        let stream = stream
        let status = status
        tasks.append(Task.detached {
            await stream.run(onEvent: { continuation.yield($0) }, onStatus: { text in
                Task { @MainActor in status.stream = text }
            })
            continuation.finish()
        })
        tasks.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case .depth(let bids, let asks, _):
            let now = nowTs()
            book = LiveBook(bids: Array(bids.prefix(20)), asks: Array(asks.prefix(20)), at: now)
            lastStreamAt = now
            scheduleEvaluate()
        case .trades(let list):
            ingest(list, live: true)
            scheduleEvaluate()
        case .error(let message):
            status.stream = "Livestream-Fehler: \(message)"
        case .ping, .ack, .unknown:
            break
        }
    }

    private func ingest(_ list: [PublicTrade], live: Bool) {
        let now = nowTs()
        for var t in list {
            if live {
                let offset = t.at - now
                if let current = clockOffset { clockOffset = 0.95 * current + 0.05 * offset } else { clockOffset = offset }
                t.at -= clockOffset ?? 0
                detector.add(price: t.price, at: now)
            }
            guard seenTradeIDs.insert(t.id).inserted else { continue }
            trades.append(t)
        }
        if !live { trades.sort { $0.at < $1.at } }
        if trades.count > 1_500 {
            trades.removeFirst(trades.count - 1_000)
            seenTradeIDs = Set(trades.map(\.id))
        }
    }

    // MARK: - Takt

    private func startLoops() {
        // REST: Kerzen jede Minute neu, bei hakendem Livestream auch Orderbuch und Trades.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.restTick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        })
        // Engine-Takt (zusaetzlich zu den Livestream-Ereignissen).
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.nowTs() - self.lastEvaluateAt > 0.9 { self.evaluate() }
            }
        })
        // Haushalt: Vermoegensverlauf, Protokoll, Zwischenspeicher.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                self.housekeeping()
            }
        })
        // Konto.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.credentials != nil { await self.refreshAccount() }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        })
        // Regeln gelegentlich erneuern.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                await self?.refreshRules()
            }
        })
    }

    private func restTick() async {
        let now = nowTs()
        let minuteRolled = Int(now / 60) > Int(candlesFetchedAt / 60)
        if minuteRolled || now - candlesFetchedAt >= 10 { await refreshCandles() }
        let streamFresh = now - lastStreamAt < 8
        if !streamFresh { await refreshBookAndTrades() }
    }

    private func housekeeping() {
        let now = nowTs()
        sampleEquity(now: now)
        if now - lastJournalFlush >= 10 {
            lastJournalFlush = now
            journal.flush()
            status.journal = journal.status
        }
        if now - lastCachePersist >= 300 {
            lastCachePersist = now
            let snapshot = history
            let eq = equity
            let cachePath = paths.candleCacheFile
            let eqPath = paths.equityFile
            DispatchQueue.global(qos: .utility).async {
                try? JSONFile.write(CandleCache(candles: snapshot), to: cachePath)
                try? JSONFile.write(eq, to: eqPath)
            }
            bot.recomputeStats()
            status.dataFolderBytes = journal.diskUsageBytes()
        }
        if now - lastPrune >= 6 * 3_600 {
            lastPrune = now
            journal.retentionDays = prefs.journalDays
            journal.prune(now: now)
        }
        if prefs.chartMinutes > 1, now - lastLongRebuild >= 30 { rebuildLongCandles() }
    }

    private func sampleEquity(now: Double) {
        guard let snap = market.snapshot, snap.bid > 0 else { return }
        let value = bot.stored.state.equity(atBid: snap.bid)
        let hold = bot.stored.holdBenchmarkUSDT(bid: snap.bid)
        if equity.append(EquityPoint(t: now, equity: value, hold: hold), minInterval: 60) {
            bot.equityHistory = equity.points
        }
    }

    // MARK: - Marktbild

    private func closedCandles(now: Double) -> [PriceCandle] {
        let minuteNow = (now / 60).rounded(.down) * 60
        let reliableUntil = (min(now, candlesFetchedAt) / 60).rounded(.down) * 60 - 60   // Beginn der letzten sicher abgeschlossenen Kerze
        var closed = restCandles.filter { $0.openedAt <= reliableUntil }
        if now - candlesFetchedAt < 45 { closed = Indicators.extendFlat(closed, upTo: minuteNow - 60) }
        return closed
    }

    /// Abgeschlossene Kerzen plus die laufende Minute (aus Trades und letztem Kurs).
    private func chartCandles(closed: [PriceCandle], now: Double, price: Double) -> [PriceCandle] {
        guard let last = closed.last, price > 0 else { return closed }
        let minuteNow = (now / 60).rounded(.down) * 60
        var forming: PriceCandle
        if let rest = restCandles.last, rest.openedAt == minuteNow {
            forming = rest
        } else {
            forming = PriceCandle(openedAt: minuteNow, open: last.close, high: last.close, low: last.close, close: last.close, volume: 0)
        }
        forming.high = max(forming.high, price)
        forming.low = min(forming.low, price)
        forming.close = price
        return closed + [forming]
    }

    private func buildSnapshot(now: Double) -> MarketSnapshot? {
        guard !book.bids.isEmpty, !book.asks.isEmpty else { return nil }
        let recent = Array(trades.drop(while: { now - $0.at > 600 }))
        return MarketSnapshot(receivedAt: now, bookAt: book.at, candles: closedCandles(now: now), asks: book.asks,
                              bids: book.bids, rules: rules, trades: recent)
    }

    private func scheduleEvaluate() {
        guard !evaluatePending else { return }
        let wait = 0.25 - (nowTs() - lastEvaluateAt)
        if wait <= 0 {
            evaluate()
        } else {
            evaluatePending = true
            Task {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self.evaluatePending = false
                self.evaluate()
            }
        }
    }

    // MARK: - Engine

    func evaluate() {
        let now = nowTs()
        lastEvaluateAt = now
        guard let snap = buildSnapshot(now: now) else { return }
        let stored = bot.stored
        let settings = stored.settings
        let fast = detector.value(now: now)
        let metrics = BotEngine.metrics(snap, state: stored.state, settings: settings, now: now)

        market.snapshot = snap
        market.metrics = metrics
        market.fastMoveBps = fast
        market.chartCandles = chartCandles(closed: snap.candles, now: now, price: snap.displayPrice)
        market.recentTrades = Array(snap.trades.filter { now - $0.at <= 60 }.suffix(40).reversed())
        market.lastUpdate = Date()

        var state = stored.state
        let bookHealthy = snap.bid > 0 && snap.ask >= snap.bid && now - snap.bookAt <= settings.maxBookAgeSeconds

        // Einmaliger virtueller Startkauf.
        if stored.initialSeedPending == true, state.running, bookHealthy {
            var next = state
            if let event = BotEngine.seedReferencePosition(snap, state: &next, settings: settings, budgetUSDT: settings.startingUSDT, now: now) {
                bot.stored.initialSeedPending = false
                bot.stored.initialSeeded = true
                commit(next, event: event)
            } else {
                bot.stored.initialSeedPending = false
                markDirty()
            }
            return
        }

        let result = BotEngine.step(snap, state: &state, settings: settings, fastMoveBps: fast, now: now)
        if let event = result.event {
            commit(state, event: event)
        } else if state != bot.stored.state {
            bot.stored.state = state
            markDirty()
        }
        recordDecision(result, now: now)
        checkAlerts(price: snap.displayPrice)
        journalTick(snap, result: result, now: now)
    }

    private func commit(_ state: BotState, event: BotEvent) {
        bot.stored.state = state
        bot.stored.record(event)
        bot.lastTradeAt = Date()
        bot.recomputeStats()
        saveNow()
        notify(event)
        if let snap = market.snapshot { journalTrade(snap, event: event) }
    }

    private func recordDecision(_ result: StepResult, now: Double) {
        guard !result.isTrade else { return }
        let kind: String
        switch result.kind {
        case .paused: kind = BotAction.paused
        case .watch: kind = BotAction.watch
        default: kind = BotAction.wait
        }
        // Zahlen im Text (Spread, Rueckgang ...) aendern sich laufend und gehoeren nicht zum Schluessel.
        let stable = result.reason.filter { !$0.isNumber && $0 != "." && $0 != "," }
        let key = result.kind == .watch ? "watch" : "\(kind):\(stable)"
        if let first = bot.decisions.first, first.key == key, now - first.at < 600 {
            if first.reason != result.reason || now - first.at >= 5 {
                bot.decisions[0].at = now
                bot.decisions[0].reason = result.reason
                bot.decisions[0].count += 1
            }
        } else {
            bot.decisions.insert(DecisionEntry(key: key, at: now, kind: kind, reason: result.reason), at: 0)
            if bot.decisions.count > 150 { bot.decisions.removeLast(bot.decisions.count - 150) }
        }
        if key != lastDecisionKey {
            lastDecisionKey = key
            notifyLimitIfNeeded(result.reason, now: now)
        }
    }

    // MARK: - Benachrichtigungen und Alarme

    private func notify(_ event: BotEvent) {
        let isStop = event.reason.hasPrefix("Stop-Loss")
        guard prefs.notifyTrades || (isStop && prefs.notifyStops) else { return }
        let amount = "\(Fmt.quantity(event.quantity)) GOMINING zu \(Fmt.price(event.priceUSDT)) USDT"
        switch event.action {
        case BotAction.sell:
            let result = Fmt.signedUSDT(event.realizedPnLUSDT, digits: 2)
            Notifier.shared.post(title: isStop ? "Stop-Loss ausgelöst" : "Verkauf (simuliert)",
                                 body: "\(amount) · Ergebnis \(result) USDT", sound: prefs.soundEnabled)
        case BotAction.seed:
            Notifier.shared.post(title: "Startkauf (simuliert)", body: amount, sound: false)
        default:
            if prefs.notifyTrades {
                Notifier.shared.post(title: "Kauf (simuliert)", body: "\(amount) · \(event.reason)", sound: prefs.soundEnabled)
            }
        }
    }

    private func notifyLimitIfNeeded(_ reason: String, now: Double) {
        guard prefs.notifyLimits, reason == "Tagesverlustgrenze erreicht" || reason == "Drawdown-Grenze erreicht" else { return }
        let day = BotEngine.utcDay(now)
        guard lastLimitNoticeDay != day + reason else { return }
        lastLimitNoticeDay = day + reason
        Notifier.shared.post(title: "Schutzgrenze erreicht", body: "\(reason). Neue Käufe sind gestoppt.", sound: prefs.soundEnabled)
    }

    private func checkAlerts(price: Double) {
        guard price > 0, prefs.alerts.contains(where: \.enabled) else { return }
        var alerts = prefs.alerts
        var changed = false
        for i in alerts.indices where alerts[i].enabled {
            let hit = alerts[i].above ? price >= alerts[i].price : price <= alerts[i].price
            if hit {
                alerts[i].enabled = false
                changed = true
                Notifier.shared.post(title: "Preisalarm GOMINING",
                                     body: "Kurs \(Fmt.price(price)) USDT hat \(Fmt.price(alerts[i].price)) \(alerts[i].above ? "erreicht" : "unterschritten").",
                                     sound: prefs.soundEnabled)
            }
        }
        if changed { prefs.alerts = alerts }
    }

    // MARK: - Protokoll

    private func journalTick(_ snap: MarketSnapshot, result: StepResult, now: Double) {
        guard now - lastJournalAt >= 5, snap.bid > 0 else { return }
        lastJournalAt = now
        journal.append(makeJournalEntry(snap, action: result.kind == .watch ? BotAction.watch : (result.kind == .paused ? BotAction.paused : BotAction.wait),
                                        why: result.reason, now: now))
    }

    private func journalTrade(_ snap: MarketSnapshot, event: BotEvent) {
        journal.append(makeJournalEntry(snap, action: event.action, why: event.reason, now: event.at))
    }

    private func makeJournalEntry(_ snap: MarketSnapshot, action: String, why: String, now: Double) -> JournalEntry {
        let state = bot.stored.state
        let candle = snap.candles.last.map { [$0.openedAt, $0.open, $0.high, $0.low, $0.close, $0.volume] }
        return JournalEntry(t: now, bid: snap.bid, ask: snap.ask,
                            bids: snap.bids.prefix(10).map { [$0.price, $0.quantity] },
                            asks: snap.asks.prefix(10).map { [$0.price, $0.quantity] },
                            share: Indicators.marketPressure(snap.trades, now: now), act: action, why: why,
                            cash: state.cashUSDT, tokens: state.tokens, eq: state.equity(atBid: snap.bid),
                            hold: bot.stored.holdBenchmarkUSDT(bid: snap.bid), candle: candle)
    }

    // MARK: - Speichern

    private func markDirty() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { self?.saveNow() }
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        stateStore.saveAsync(bot.stored) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in self?.status.notice = "Speichern fehlgeschlagen: \(error.localizedDescription)" }
        }
    }

    // MARK: - Bedienung

    func toggleRunning() {
        bot.stored.state.running.toggle()
        saveNow()
        scheduleEvaluate()
    }

    func setRunning(_ running: Bool) {
        guard bot.stored.state.running != running else { return }
        toggleRunning()
    }

    func updateSettings(_ edit: (inout BotSettings) -> Void) {
        var s = bot.stored.settings
        edit(&s)
        s = s.clamped()
        guard s != bot.stored.settings else { return }
        bot.stored.settings = s
        markDirty()
        scheduleEvaluate()
    }

    /// Bindung auf eine Einstellung; Aenderungen werden begrenzt und gespeichert.
    func binding<T>(_ keyPath: WritableKeyPath<BotSettings, T>) -> Binding<T> {
        Binding(get: { self.bot.stored.settings[keyPath: keyPath] },
                set: { value in self.updateSettings { $0[keyPath: keyPath] = value } })
    }

    func resetSimulation(seedStartPosition: Bool) {
        if let url = stateStore.backupNow(bot.stored, tag: "vor-reset") {
            status.notice = "Simulation zurückgesetzt. Sicherung des alten Zustands: \(url.lastPathComponent)"
        } else {
            status.notice = "Simulation zurückgesetzt."
        }
        let fresh = StoredBot.fresh(settings: bot.stored.settings, at: nowTs(), seedStartPosition: seedStartPosition)
        bot.stored = fresh
        bot.decisions = []
        equity = EquityHistory()
        bot.equityHistory = []
        lastDecisionKey = ""
        bot.recomputeStats()
        try? JSONFile.write(equity, to: paths.equityFile)
        saveNow()
        scheduleEvaluate()
    }

    /// Legt den Startkauf nachtraeglich an (nur sinnvoll im frisch zurueckgesetzten Konto).
    func seedNow() {
        guard bot.stored.state.lots.isEmpty else { return }
        bot.stored.initialSeedPending = true
        scheduleEvaluate()
    }

    func applyAccountFee() {
        guard let c = status.commission else { return }
        updateSettings { $0.feeBps = (c.takerBps * 100).rounded() / 100 }
    }

    // MARK: - Konto

    private func loadCredentials() {
        do {
            credentials = try CredentialStore.load()
            if credentials != nil { status.account = "API-Schlüssel gespeichert · Verbindung noch nicht geprüft" }
        } catch {
            status.note("Schlüsselbund", error)
            status.account = "Gespeicherter API-Schlüssel konnte nicht gelesen werden: \(error.localizedDescription)"
        }
    }

    func connectAccount(apiKey: String, secretKey: String) async {
        let creds = BingXCredentials(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                     secretKey: secretKey.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !creds.apiKey.isEmpty, !creds.secretKey.isEmpty else {
            status.account = "Bitte API-Schlüssel und Secret Key eingeben."
            return
        }
        status.busy = true
        defer { status.busy = false }
        status.account = "Prüfe BingX-Zugang …"
        do {
            let uid = try await privateAPI.testReadOnly(creds)
            try CredentialStore.save(creds)
            credentials = creds
            status.accountConnected = true
            status.account = "BingX-Konto \(uid) verbunden · nur Lesezugriff"
            await refreshAccount()
        } catch {
            status.note("Konto", error)
            status.account = "Verbindung fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func disconnectAccount() {
        CredentialStore.remove()
        credentials = nil
        status.accountConnected = false
        status.balances = []
        status.commission = nil
        status.account = "Kein BingX-Konto verbunden"
    }

    private func refreshAccount() async {
        guard let creds = credentials else { return }
        do {
            let balances = try await privateAPI.spotBalances(creds)
            status.balances = balances
            status.accountConnected = true
            if !status.account.hasPrefix("BingX-Konto") { status.account = "BingX-Konto verbunden · nur Lesezugriff" }
            if let commission = try? await privateAPI.spotCommission(creds, symbol: Self.symbol) { status.commission = commission }
        } catch {
            status.note("Konto", error)
            status.accountConnected = false
            status.account = "Gespeicherter API-Schlüssel konnte nicht geprüft werden: \(error.localizedDescription)"
        }
    }

    // MARK: - Diagramm

    func setChartMinutes(_ minutes: Int) {
        prefs.chartMinutes = minutes
        guard minutes > 1 else { return }
        rebuildLongCandles()
        if history.count < 1_500 {
            Task {
                _ = await prepareHistory(days: 3)
                rebuildLongCandles()
            }
        }
    }

    func rebuildLongCandles() {
        lastLongRebuild = nowTs()
        let minutes = prefs.chartMinutes
        guard minutes > 1 else { return }
        let source = history
        let market = market
        Task.detached(priority: .utility) {
            let aggregated = Indicators.aggregate(source, minutes: minutes)
            let tail = Array(aggregated.suffix(240))
            await MainActor.run {
                market.longCandles = tail
                market.longMinutes = minutes
            }
        }
    }

    // MARK: - Verlauf, Backtest, Optimierung

    /// Stellt sicher, dass `days` Tage Kerzen lokal vorliegen; laedt fehlende von BingX.
    func prepareHistory(days: Int) async -> [PriceCandle]? {
        let now = nowTs()
        let start = now - Double(days) * 86_400
        let covers = (history.first?.openedAt ?? .infinity) <= start + 7_200
        let fresh = (history.last.map { now - $0.openedAt < 900 }) ?? false
        if !(covers && fresh) {
            status.historyStatus = "Lade \(days) Tage Kerzen von BingX …"
            do {
                let fetched = try await api.history(from: start) { p in
                    Task { @MainActor [weak self] in self?.backtest.progress = p * 0.5 }
                }
                history = CandleCache.merged(history, fetched, now: now)
                status.historyStatus = "\(history.count) Kerzen lokal gespeichert"
            } catch {
                status.note("Kerzenverlauf", error)
                status.historyStatus = "Kerzen konnten nicht geladen werden: \(error.localizedDescription)"
                if history.isEmpty { return nil }
            }
        }
        let slice = history.filter { $0.openedAt >= start }
        let filled = Indicators.fillGaps(slice)
        guard filled.count > Backtester.warmupCandles + 60 else {
            status.historyStatus = "Zu wenige Kerzen für einen Backtest (\(filled.count))."
            return nil
        }
        return filled
    }

    func useLiveMarketForBacktest() {
        guard let snap = market.snapshot, snap.bid > 0 else { return }
        backtest.spreadBps = max(5, (snap.spreadBps).rounded())
        backtest.depthUSDT = max(200, ((min(snap.bidDepthUSDT, snap.askDepthUSDT)) / 100).rounded() * 100)
    }

    func runBacktest() {
        guard !backtest.running, !backtest.optimizing else { return }
        let store = backtest
        store.running = true
        store.progress = 0
        store.message = "Lade Kerzen …"
        store.result = nil
        store.task = Task { [weak self] in
            guard let self else { return }
            defer { store.running = false; store.task = nil }
            guard let candles = await self.prepareHistory(days: store.days) else {
                store.message = self.status.historyStatus
                return
            }
            store.message = "Rechne \(candles.count) Kerzen …"
            let settings = self.bot.stored.settings
            let config = store.config(rules: self.rules)
            let worker = Task.detached(priority: .userInitiated) {
                Backtester.run(candles: candles, settings: settings, config: config, shouldCancel: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            store.result = result
            store.progress = 1
            store.message = result.cancelled ? "Abgebrochen" : "Fertig"
        }
    }

    func runOptimizer() {
        guard !backtest.running, !backtest.optimizing else { return }
        let store = backtest
        var axes: [OptimizerAxis] = []
        for (parameter, text) in store.axes {
            let values = BacktestStore.parseValues(text)
            if !values.isEmpty { axes.append(OptimizerAxis(parameter: parameter, values: values)) }
        }
        axes.sort { $0.parameter.rawValue < $1.parameter.rawValue }
        guard !axes.isEmpty else {
            store.message = "Bitte mindestens einen Parameter mit Werten angeben."
            return
        }
        let combos = Optimizer.combinations(axes).count
        guard combos <= Optimizer.maxCombinations else {
            store.message = "Zu viele Kombinationen (\(combos)); erlaubt sind \(Optimizer.maxCombinations)."
            return
        }
        store.optimizing = true
        store.progress = 0
        store.entries = []
        store.optimizerAxesUsed = axes.map(\.parameter)
        store.message = "Lade Kerzen …"
        store.task = Task { [weak self] in
            guard let self else { return }
            defer { store.optimizing = false; store.task = nil }
            guard let candles = await self.prepareHistory(days: store.days) else {
                store.message = self.status.historyStatus
                return
            }
            store.message = "Teste \(combos) Kombinationen …"
            let base = self.bot.stored.settings
            let config = store.config(rules: self.rules)
            let objective = store.objective
            let train = store.trainFraction
            let results = await Optimizer.run(candles: candles, base: base, config: config, axes: axes, objective: objective,
                                              trainFraction: train, progress: { done, total in
                Task { @MainActor in store.progress = Double(done) / Double(max(1, total)) }
            })
            store.entries = results
            store.progress = 1
            store.message = Task.isCancelled ? "Abgebrochen" : "Fertig: \(results.count) Ergebnisse"
        }
    }

    func cancelBacktest() {
        backtest.task?.cancel()
    }

    /// Uebernimmt die Einstellungen eines Optimierungsergebnisses (nur die untersuchten Parameter).
    func apply(_ entry: OptimizerEntry) {
        let parameters = backtest.optimizerAxesUsed
        updateSettings { s in
            for (parameter, value) in zip(parameters, entry.values) { parameter.apply(value, to: &s) }
        }
    }

    // MARK: - Export und Diagnose

    func exportTradesCSV() {
        let csv = CSVExport.trades(bot.stored.events)
        savePanel(name: "gomining-trades.csv", type: .commaSeparatedText) { url in
            try csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func exportBackup() {
        let stored = bot.stored
        savePanel(name: "gomining-sicherung.json", type: .json) { url in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: url, options: .atomic)
        }
    }

    private func savePanel(name: String, type: UTType, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try write(url) } catch {
                Task { @MainActor [weak self] in self?.status.notice = "Export fehlgeschlagen: \(error.localizedDescription)" }
            }
        }
    }

    func openDataFolder() {
        NSWorkspace.shared.open(paths.root)
    }

    func diagnosticsText() -> String {
        var lines: [String] = []
        lines.append("GoMining Bot \(Self.version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Verbindung: \(status.connection)")
        lines.append("Livestream: \(status.stream) · letzte Daten vor \(lastStreamAt > 0 ? String(Int(nowTs() - lastStreamAt)) : "—") s")
        lines.append("Konto: \(status.account)")
        lines.append("Handelsregeln: minQty \(rules.minQuantity), minNotional \(rules.minNotional), step \(rules.stepSize), verifiziert \(rules.verified), Kauf \(rules.buyEnabled), Verkauf \(rules.sellEnabled)")
        if let s = market.snapshot {
            lines.append("Buch: bid \(s.bid) ask \(s.ask) · Spread \(String(format: "%.1f", s.spreadBps)) bp · \(s.bids.count)/\(s.asks.count) Stufen")
            lines.append("Kerzen: \(s.candles.count) geschlossen (letzte \(s.candles.last.map { Fmt.dateTime($0.openedAt) } ?? "—")) · Trades: \(s.trades.count)")
            if let c = s.candles.last { lines.append("Letzte Kerze: O \(c.open) H \(c.high) L \(c.low) C \(c.close) V \(c.volume)") }
        } else {
            lines.append("Noch kein Marktbild")
        }
        lines.append("REST-Kerzen: \(restCandles.count) · Verlauf lokal: \(history.count) · Trades im Speicher: \(trades.count)")
        let st = bot.stored.state
        lines.append("Konto-Zustand: Bargeld \(st.cashUSDT) · Bestand \(st.tokens) · \(st.lots.count) Lose · läuft \(st.running)")
        if let d = bot.decisions.first { lines.append("Letzte Entscheidung: \(d.kind): \(d.reason)") }
        lines.append("Fehler:")
        lines.append(contentsOf: status.errors.isEmpty ? ["  keine"] : status.errors.map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText(), forType: .string)
        status.notice = "Diagnose in die Zwischenablage kopiert."
    }
}
