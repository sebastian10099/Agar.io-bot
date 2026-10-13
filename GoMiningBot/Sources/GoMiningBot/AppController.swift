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
    static let appName = "GoMining Bot Pro"

    let market = MarketStore()
    let bot: BotStore
    let status = StatusStore()
    let backtest = BacktestStore()
    let shadows = ShadowStore()
    let profiles = ProfileStore()
    let prefs: Preferences
    let paths: AppPaths
    /// Nur fuer den Rauchtest: erzwingt eine Seite der Oberflaeche.
    @Published var forcedTab: String?

    private let stateStore: StateStore
    private let journal: MarketJournal
    private let api: BingXPublicAPI
    private let privateAPI = BingXPrivateAPI()
    private let updates = UpdateService()
    private var lastUpdateCheck = 0.0
    private var terminationSource: DispatchSourceSignal?
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
    private var shadowsDirty = false
    private var lastShadowSave = 0.0

    init() {
        // Vor dem ersten Lesen von Einstellungen und Datenordner (alte Bundle-ID/alter Ordner -> eigene).
        AppMigration.run()
        prefs = Preferences()
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
        if let book = JSONFile.read(ShadowBook.self, from: paths.shadowFile) {
            shadows.book = book
        }
        if let book = JSONFile.read(ProfileBook.self, from: paths.profilesFile) {
            profiles.book = book
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
                                                         reason: "\(Self.appName) beobachtet den Markt")
        Notifier.shared.requestAuthorizationIfNeeded()
        observeSystem()
        loadCredentials()
        status.dataFolderBytes = journal.diskUsageBytes()
        prepareWhatsNew()
        tasks.append(Task { [weak self] in await self?.bootstrap() })
        scheduleSmokeReportIfRequested()
    }

    /// Rauchtest fuer die CI: Mit `GOMINING_SMOKE_OUT=<Datei>` laeuft die App ein kurzes Skript
    /// (Seiten durchschalten, optional Bilder nach `GOMINING_SMOKE_SHOTS`, Backtest und Optimierer mit echten
    /// Kerzen), schreibt einen Bericht und beendet sich.
    private func scheduleSmokeReportIfRequested() {
        guard let out = ProcessInfo.processInfo.environment["GOMINING_SMOKE_OUT"], !out.isEmpty else { return }
        tasks.append(Task { [weak self] in
            await self?.runSmokeScript(out: out)
        })
    }

    private func runSmokeScript(out: String) async {
        let shots = ProcessInfo.processInfo.environment["GOMINING_SMOKE_SHOTS"] ?? ""
        var extra: [String] = []
        if !shots.isEmpty { try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true) }
        func shot(_ name: String) {
            guard !shots.isEmpty else { return }
            saveScreenshot(to: "\(shots)/\(name).png")
        }
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        // Schattenkonten fuer die Vergleichsseite.
        if shadows.book.accounts.isEmpty {
            addShadow(.current, name: "")
            addShadow(.cautious, name: "")
            addShadow(.maker, name: "")
        }

        for (index, tab) in AppTab.allCases.enumerated() {
            if tab == .backtest {
                // Replay aus dem (in der CI noch sehr kurzen) Marktprotokoll.
                backtest.days = 1
                backtest.source = .journal
                runBacktest()
                await waitUntil(timeout: 60) { !self.backtest.running }
                extra.append("Replay aus dem Marktprotokoll: \(backtest.message) · \(backtest.journalInfo)")
                if let r = backtest.result {
                    extra.append("  Marktmomente \(r.frameCount) · Käufe \(r.buys) · Verkäufe \(r.sells) · Ergebnis \(String(format: "%.2f", r.netPnL)) USDT")
                }
                backtest.source = .candles
                backtest.days = 7
                let started = Date()
                runBacktest()
                await waitUntil(timeout: 120) { !self.backtest.running }
                extra.append("Backtest (7 Tage, echte Kerzen) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(backtest.message)")
                if let r = backtest.result {
                    extra.append("  Kerzen \(r.candleCount) · Käufe \(r.buys) · Verkäufe \(r.sells) · Ergebnis \(String(format: "%.2f", r.netPnL)) USDT · Max. Rückgang \(String(format: "%.2f", r.maxDrawdownUSDT)) USDT")
                }
                backtest.axes = [.minNetProfitBps: "30, 50, 80, 120", .stopLossFraction: "0.02, 0.03, 0.05"]
                let optimizerStarted = Date()
                runOptimizer()
                await waitUntil(timeout: 180) { !self.backtest.optimizing }
                extra.append("Optimierer (12 Kombinationen x Training+Test) in \(String(format: "%.1f", Date().timeIntervalSince(optimizerStarted))) s: \(backtest.message) · \(backtest.entries.count) Ergebnisse")
                if let best = backtest.entries.first {
                    extra.append("  Bestes Training \(String(format: "%.2f", best.train.netPnL)) USDT · Test \(best.test.map { String(format: "%.2f", $0.netPnL) } ?? "—") USDT · Abschnitte \(best.positiveSegments)/\(best.segments.count) im Plus")
                }
                if let wf = backtest.walkForward {
                    extra.append("  Walk-forward: außerhalb der Stichprobe \(String(format: "%+.2f", wf.outOfSamplePnL)) USDT (\(wf.positiveSteps)/\(wf.steps.count) Schritte im Plus)")
                }
            }
            forcedTab = tab.rawValue
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            shot("\(index + 1)-\(tab.slug)")
        }

        // Dunkelmodus pruefen.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        forcedTab = AppTab.overview.rawValue
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        shot("7-dunkel-uebersicht")
        forcedTab = AppTab.compare.rawValue
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        shot("8-dunkel-vergleich")
        NSApp.appearance = nil

        // Profile und Berichte.
        saveProfile(name: "Rauchtest")
        let week = report(.week)
        extra.append("Profile: \(profiles.book.profiles.count) · Wochenbericht: \(ReportBuilder.summaryText(week)) · HTML \(ReportBuilder.html(week, appName: Self.appName, appVersion: Self.version, settings: bot.stored.settings, generatedAt: nowTs()).count) Zeichen")

        await checkForUpdates(manual: true)
        extra.append("Update-Prüfung: \(status.updateStatus)")
        let bidNow = market.bid
        for a in shadows.accounts {
            extra.append("Schattenkonto \(a.name): \(a.buys) Käufe, \(a.sells) Verkäufe, Ergebnis \(String(format: "%+.3f", a.result(bid: bidNow))) USDT · \(a.lastReason)")
        }
        await compareStrategies(into: &extra)

        let report = diagnosticsText() + "\n" + extra.joined(separator: "\n")
        try? report.write(toFile: out, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// Rauchtest: vergleicht Strategie-Varianten auf den echten Kerzen der letzten 7 Tage
    /// (ganzer Zeitraum sowie erste 60 % / letzte 40 %), damit Aenderungen an der Strategie belegt sind.
    private func compareStrategies(into extra: inout [String]) async {
        guard let candles = await prepareHistory(days: 7) else { return }
        var assumed = backtest.config(rules: rules)
        assumed.spreadBps = 20
        assumed.depthUSDT = 3_000
        var live = assumed
        if let snap = market.snapshot, snap.bid > 0 {
            live.spreadBps = max(2, snap.spreadBps)
            live.depthUSDT = max(200, min(snap.bidDepthUSDT, snap.askDepthUSDT))
        }
        let split = Int(Double(candles.count) * 0.6)
        func variant(_ name: String, _ cfg: BacktestConfig, _ edit: (inout BotSettings) -> Void) -> String {
            var s = BotSettings()
            edit(&s)
            let all = Backtester.run(candles: candles, settings: s, config: cfg, collect: false)
            let first = Backtester.run(candles: candles, settings: s, config: cfg, endIndex: split, collect: false)
            let last = Backtester.run(candles: candles, settings: s, config: cfg, startIndex: split, collect: false)
            return String(format: "  %@: gesamt %+.2f (dd %.2f, %ld/%ld) · Teil 1 %+.2f · Teil 2 %+.2f", name, all.netPnL,
                          all.maxDrawdownUSDT, all.buys, all.sells, first.netPnL, last.netPnL)
        }
        let hold = Backtester.run(candles: candles, settings: BotSettings(), config: assumed, collect: false).holdReturnFraction
        for (label, cfg) in [("angenommen", assumed), ("live gemessen", live)] {
            extra.append(String(format: "Strategievergleich (7 Tage, Spread %@ %.1f bp, Tiefe %.0f USDT, Halten %+.1f%%):",
                                label, cfg.spreadBps, cfg.depthUSDT, hold * 100))
            extra.append(variant("Standard 4.2 (Mindest-Kaufabstand 80, Trendfilter)", cfg, { _ in }))
            extra.append(variant("Wie 4.1 (ohne Mindest-Kaufabstand)", cfg, { $0.minBuyStepBps = 0 }))
            for floor in [60.0, 100, 120] {
                extra.append(variant(String(format: "Mindest-Kaufabstand %.0f bp", floor), cfg, { $0.minBuyStepBps = floor }))
            }
            extra.append(variant("Ohne Trendfilter", cfg, { $0.trendFilterEnabled = false }))
            extra.append(variant("Limit-Kauf am Bid", cfg, { $0.makerEntries = true }))
            extra.append(variant("Ziel 30", cfg, { $0.minNetProfitBps = 30 }))
            extra.append(variant("Ziel 80", cfg, { $0.minNetProfitBps = 80 }))
        }
    }

    private func waitUntil(timeout: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 500_000_000) }
    }

    private func saveScreenshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.title == Self.appName }) ?? NSApp.windows.first(where: { $0.contentView != nil }),
              let content = window.contentView else { return }
        let view = content.superview ?? content
        let bounds = view.bounds
        guard bounds.width > 10, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    private func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWake() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        // SIGTERM (z. B. vom Installationsbefehl oder `kill`) wie "Beenden" behandeln, damit vorher gespeichert wird.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminationSource = source
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
        try? JSONFile.write(shadows.book, to: paths.shadowFile)
        journal.flushAndWait()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    private func bootstrap() async {
        if prefs.autoCheckUpdates {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.checkForUpdates(manual: false)
            }
        }
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
            let fetched = try await api.klines(limit: min(1_000, bot.stored.settings.requiredCandles + 20))
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
        if shadowsDirty, now - lastShadowSave >= 60 { saveShadows() }
        checkDailySummary(now: now)
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
        if prefs.autoCheckUpdates, lastUpdateCheck > 0, now - lastUpdateCheck >= 6 * 3_600 {
            lastUpdateCheck = now
            Task { await checkForUpdates(manual: false) }
        }
    }

    private func sampleEquity(now: Double) {
        guard let snap = market.snapshot, snap.bid > 0 else { return }
        let value = bot.stored.state.equity(atBid: snap.bid)
        let hold = bot.stored.holdBenchmarkUSDT(bid: snap.bid)
        if equity.append(EquityPoint(t: now, equity: value, hold: hold), minInterval: 60) {
            bot.equityHistory = equity.points
        }
        if !shadows.book.accounts.isEmpty {
            for i in shadows.book.accounts.indices { shadows.book.accounts[i].sample(bid: snap.bid, now: now) }
            shadowsDirty = true
        }
    }

    // MARK: - Berichte

    private static func localDay(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    func report(_ kind: ReportKind) -> PeriodReport {
        let now = nowTs()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        let bid = market.bid
        let currentEquity = bid > 0 ? bot.stored.state.equity(atBid: bid) : nil
        let currentHold = bid > 0 ? bot.stored.holdBenchmarkUSDT(bid: bid) : nil
        let events = bot.stored.events
        let points = equity.points
        switch kind {
        case .today:
            return ReportBuilder.period(title: "Tagesbericht \(Date(timeIntervalSince1970: today).formatted(date: .numeric, time: .omitted))", events: events, equity: points,
                                        from: today, to: now + 1, currentEquity: currentEquity, currentHold: currentHold)
        case .yesterday:
            let start = cal.date(byAdding: .day, value: -1, to: Date(timeIntervalSince1970: today))?.timeIntervalSince1970 ?? today - 86_400
            return ReportBuilder.period(title: "Tagesbericht \(Date(timeIntervalSince1970: start).formatted(date: .numeric, time: .omitted))", events: events, equity: points,
                                        from: start, to: today)
        case .week:
            return ReportBuilder.period(title: "Wochenbericht", events: events, equity: points, from: now - 7 * 86_400, to: now + 1,
                                        currentEquity: currentEquity, currentHold: currentHold)
        }
    }

    func exportReport(_ kind: ReportKind) {
        let r = report(kind)
        let html = ReportBuilder.html(r, appName: Self.appName, appVersion: Self.version, settings: bot.stored.settings,
                                      generatedAt: nowTs())
        let name = "gomining-\(kind == .week ? "wochenbericht" : "tagesbericht")-\(Self.localDay(r.from)).html"
        savePanel(name: name, type: .html) { url in
            try html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        }
    }

    /// Nach Mitternacht (Ortszeit) einmal die Zusammenfassung des Vortags als Mitteilung.
    private func checkDailySummary(now: Double) {
        let today = Self.localDay(now)
        guard prefs.lastSummaryDay != today else { return }
        let first = prefs.lastSummaryDay.isEmpty
        prefs.lastSummaryDay = today
        guard !first, prefs.dailySummary else { return }
        let r = report(.yesterday)
        guard !r.isEmpty else { return }
        Notifier.shared.post(title: "\(Self.appName): Zusammenfassung von gestern", body: ReportBuilder.summaryText(r), sound: false)
    }

    // MARK: - Profile

    private func saveProfiles() {
        let book = profiles.book
        let url = paths.profilesFile
        DispatchQueue.global(qos: .utility).async { try? JSONFile.write(book, to: url) }
    }

    func saveProfile(name: String) {
        let profile = profiles.book.save(name: name, settings: bot.stored.settings, at: nowTs())
        saveProfiles()
        status.notice = "Profil „\(profile.name)“ gespeichert."
    }

    /// Laedt die Strategie-Werte eines Profils; Startkapital und Gebuehren des eigenen Kontos bleiben.
    func loadProfile(_ id: UUID) {
        guard let profile = profiles.book.profiles.first(where: { $0.id == id }) else { return }
        let current = bot.stored.settings
        updateSettings { $0 = current.adoptingStrategy(from: profile.settings) }
        status.notice = "Profil „\(profile.name)“ geladen."
    }

    func deleteProfile(_ id: UUID) {
        profiles.book.remove(id)
        saveProfiles()
    }

    func applyPreset(_ preset: ShadowPreset) {
        let current = bot.stored.settings
        updateSettings { $0 = preset.settings(from: current) }
        status.notice = "Vorlage „\(preset.rawValue)“ angewendet."
    }

    /// Legt ein Schattenkonto mit den Einstellungen eines Profils an.
    func testProfileAsShadow(_ id: UUID) {
        guard let profile = profiles.book.profiles.first(where: { $0.id == id }),
              shadows.book.accounts.count < ShadowAccount.maxAccounts else {
            status.notice = "Höchstens \(ShadowAccount.maxAccounts) Schattenkonten – bitte zuerst eines entfernen."
            return
        }
        let account = ShadowAccount(name: profile.name, settings: bot.stored.settings.adoptingStrategy(from: profile.settings),
                                    at: nowTs(), bid: market.snapshot?.bid)
        shadows.book.accounts.append(account)
        saveShadows()
        status.notice = "Schattenkonto „\(profile.name)“ angelegt (Seite Vergleich)."
    }

    func exportProfile(_ id: UUID) {
        guard let profile = profiles.book.profiles.first(where: { $0.id == id }),
              let data = try? ProfileFile.encode(profile, appVersion: Self.version) else { return }
        let safe = profile.name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        savePanel(name: "gomining-profil-\(String(safe)).json", type: .json) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let data = try? Data(contentsOf: url)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let name = url.deletingPathExtension().lastPathComponent
                guard let data, let profile = ProfileFile.decode(data, fallbackName: name, now: self.nowTs()) else {
                    self.status.notice = "Die Datei enthält kein lesbares Profil."
                    return
                }
                let added = self.profiles.book.add(imported: profile)
                self.saveProfiles()
                self.status.notice = "Profil „\(added.name)“ importiert. Zum Verwenden „Laden“ oder „Als Schattenkonto testen“ wählen."
            }
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

    /// Abgeschlossene Kerzen plus die laufende Minute (aus Trades und letztem Kurs). Fuer das Diagramm wird der
    /// gespeicherte Verlauf davor gesetzt (bis 12 Stunden), damit man herauszoomen kann.
    private func chartCandles(closed rawClosed: [PriceCandle], now: Double, price: Double) -> [PriceCandle] {
        var closed = rawClosed
        if let first = closed.first {
            let older = history.suffix(720).filter { $0.openedAt < first.openedAt }
            if !older.isEmpty { closed = older + closed }
        }
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
        stepShadows(snap, fastMoveBps: fast, now: now)
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

    /// Merkt eine Aenderung vor und speichert spaetestens nach 3 s (nicht bei jeder Kursbewegung neu).
    private func markDirty() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
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
        updateSettings {
            $0.feeBps = (c.takerBps * 100).rounded() / 100
            $0.makerFeeBps = (c.makerBps * 100).rounded() / 100
        }
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

    // MARK: - Updates

    /// Fragt GitHub nach der neuesten veroeffentlichten Version.
    func checkForUpdates(manual: Bool) async {
        lastUpdateCheck = nowTs()
        if manual { status.updateStatus = "Suche nach Updates …" }
        do {
            let info = try await updates.latestRelease()
            if let current = AppVersion(Self.version), info.version > current {
                let isNew = status.availableUpdate?.tag != info.tag
                status.availableUpdate = info
                status.updateStatus = "Version \(info.version) ist verfügbar (installiert: \(Self.version))."
                if isNew { status.updateBannerHidden = false }
                if isNew, !manual {
                    Notifier.shared.post(title: "\(Self.appName) \(info.version) verfügbar",
                                         body: "Ein Update steht bereit. In der App auf „Jetzt aktualisieren“ klicken.", sound: false)
                }
            } else {
                status.availableUpdate = nil
                status.updateStatus = "\(Self.appName) ist aktuell (Version \(Self.version))."
            }
        } catch {
            if manual {
                status.updateStatus = "Update-Prüfung fehlgeschlagen: \(error.localizedDescription)"
                status.note("Update-Prüfung", error)
            }
        }
    }

    /// Laedt die neue Version, prueft sie und tauscht die App nach dem Beenden aus.
    func installUpdate() {
        guard let info = status.availableUpdate, !status.updateBusy else { return }
        let target = Bundle.main.bundleURL
        guard info.downloadURL != nil, UpdateInstaller.canReplace(appAt: target) else {
            NSWorkspace.shared.open(info.pageURL)
            status.updateStatus = "Automatisches Update an diesem Ort nicht möglich – die Download-Seite wurde geöffnet."
            return
        }
        status.updateBusy = true
        let updates = updates
        let status = status
        Task {
            defer { status.updateBusy = false }
            do {
                let app = try await updates.download(info) { text in
                    Task { @MainActor in status.updateStatus = text }
                }
                try updates.scheduleInstall(newApp: app, replacing: target)
                status.updateStatus = "Version \(info.version) wird installiert, die App startet neu …"
                try? await Task.sleep(nanoseconds: 500_000_000)
                NSApp.terminate(nil)
            } catch {
                status.updateStatus = "Update fehlgeschlagen: \(error.localizedDescription)"
                status.note("Update", error)
            }
        }
    }

    /// Zeigt nach einem Update einmal die Neuerungen dieser Version.
    private func prepareWhatsNew() {
        let current = Self.version
        defer { prefs.lastSeenVersion = current }
        // Im Rauchtest der CI kein Dialog ueber der Oberflaeche.
        guard ProcessInfo.processInfo.environment["GOMINING_SMOKE_OUT"] == nil else { return }
        if let last = AppVersion(prefs.lastSeenVersion), let now = AppVersion(current), !(now > last) { return }
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              let section = ReleaseParser.changelogSection(markdown, version: current) else { return }
        status.whatsNew = section
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
            let tail = Array(aggregated.suffix(1_000))
            await MainActor.run {
                market.longCandles = tail
                market.longMinutes = minutes
            }
        }
    }

    // MARK: - Schattenkonten

    /// Alle Schattenkonten handeln auf demselben Marktbild wie das Hauptkonto.
    private func stepShadows(_ snap: MarketSnapshot, fastMoveBps: Double, now: Double) {
        guard !shadows.book.accounts.isEmpty else { return }
        var book = shadows.book
        var traded = false
        for i in book.accounts.indices {
            if book.accounts[i].step(snap, fastMoveBps: fastMoveBps, now: now) != nil { traded = true }
        }
        shadows.book = book
        shadowsDirty = true
        if traded { saveShadows() }
    }

    private func saveShadows() {
        shadowsDirty = false
        lastShadowSave = nowTs()
        let book = shadows.book
        let url = paths.shadowFile
        DispatchQueue.global(qos: .utility).async { try? JSONFile.write(book, to: url) }
    }

    func addShadow(_ preset: ShadowPreset, name: String) {
        guard shadows.book.accounts.count < ShadowAccount.maxAccounts else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = ShadowAccount(name: trimmed.isEmpty ? preset.rawValue : trimmed,
                                    settings: preset.settings(from: bot.stored.settings),
                                    at: nowTs(), bid: market.snapshot?.bid)
        shadows.book.accounts.append(account)
        saveShadows()
        scheduleEvaluate()
    }

    func removeShadow(_ id: UUID) {
        shadows.book.accounts.removeAll { $0.id == id }
        saveShadows()
    }

    func resetShadow(_ id: UUID) {
        guard let i = shadows.book.accounts.firstIndex(where: { $0.id == id }) else { return }
        shadows.book.accounts[i].reset(at: nowTs(), bid: market.snapshot?.bid)
        saveShadows()
    }

    /// Setzt alle Schattenkonten gleichzeitig zurueck (fairer Neustart des Vergleichs).
    func resetAllShadows() {
        let now = nowTs()
        let bid = market.snapshot?.bid
        for i in shadows.book.accounts.indices { shadows.book.accounts[i].reset(at: now, bid: bid) }
        saveShadows()
    }

    /// Uebernimmt die Einstellungen eines Schattenkontos ins Hauptkonto (Papierkonto bleibt unveraendert).
    func applyShadowSettings(_ id: UUID) {
        guard let account = shadows.book.accounts.first(where: { $0.id == id }) else { return }
        let incoming = account.settings
        updateSettings { s in
            let start = s.startingUSDT
            s = incoming
            s.startingUSDT = start
        }
        status.notice = "Einstellungen von „\(account.name)“ übernommen."
    }

    // MARK: - Verlauf, Backtest, Optimierung

    /// BingX liefert 1-Minuten-Kerzen hoechstens 7 Tage weit zurueck (Fehler 100204).
    static let exchangeHistoryDays = 7.0

    /// Stellt sicher, dass `days` Tage Kerzen lokal vorliegen; laedt fehlende von BingX (soweit dort abrufbar).
    func prepareHistory(days: Int) async -> [PriceCandle]? {
        let now = nowTs()
        let start = now - Double(days) * 86_400
        // Aelteres als der Abrufbereich von BingX kann nur die App selbst gesammelt haben.
        let fetchableStart = now - Self.exchangeHistoryDays * 86_400 + 3_600
        let wantedStart = max(start, fetchableStart)
        let covers = (history.first?.openedAt ?? .infinity) <= wantedStart + 7_200
        let fresh = (history.last.map { now - $0.openedAt < 900 }) ?? false
        if !(covers && fresh) {
            status.historyStatus = "Lade Kerzen von BingX …"
            do {
                let fetched = try await api.history(from: wantedStart) { p in
                    Task { @MainActor [weak self] in self?.backtest.progress = p * 0.5 }
                }
                history = CandleCache.merged(history, fetched, now: now)
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
        let span = ((filled.last?.openedAt ?? 0) - (filled.first?.openedAt ?? 0)) / 86_400
        if span < Double(days) * 0.9 {
            status.historyStatus = "Verfügbar sind \(Fmt.usdt(span, digits: 1)) von \(days) Tagen (\(filled.count) Kerzen): BingX liefert höchstens \(Int(Self.exchangeHistoryDays)) Tage; die App sammelt weiteren Verlauf, solange sie läuft."
        } else {
            status.historyStatus = "\(Fmt.usdt(span, digits: 1)) Tage Verlauf (\(filled.count) Kerzen) lokal gespeichert"
        }
        return filled
    }

    func useLiveMarketForBacktest() {
        guard let snap = market.snapshot, snap.bid > 0 else { return }
        backtest.spreadBps = max(1, (snap.spreadBps).rounded())
        backtest.depthUSDT = max(200, ((min(snap.bidDepthUSDT, snap.askDepthUSDT)) / 100).rounded() * 100)
    }

    /// Liest das eigene Marktprotokoll der letzten `days` Tage im Hintergrund.
    private func loadJournal(days: Int) async -> ReplayData {
        journal.flushAndWait()
        let dir = paths.journalDirectory
        let now = nowTs()
        let from = now - Double(days) * 86_400
        let worker = Task.detached(priority: .userInitiated) {
            JournalReader.load(directory: dir, from: from, to: now, shouldCancel: { Task.isCancelled })
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private func describe(_ data: ReplayData) -> String {
        guard data.frames.count >= 2 else {
            return "Im Marktprotokoll ist noch nichts gespeichert. Die App schreibt alle 5 Sekunden einen Eintrag, solange sie läuft."
        }
        return "Marktprotokoll: \(data.frames.count) Einträge aus \(data.filesRead) Tagesdateien · \(Fmt.usdt(data.coveredHours, digits: 1)) Stunden Livebetrieb"
            + (data.badLines > 0 ? " · \(data.badLines) unlesbare Zeilen übersprungen" : "")
    }

    /// Misst typischen Spread und Orderbuchtiefe im Protokoll und uebernimmt sie fuer den Kerzen-Backtest.
    func measureMarketFromJournal() {
        guard !backtest.running, !backtest.optimizing else { return }
        let store = backtest
        store.running = true
        store.message = "Lese Marktprotokoll …"
        store.task = Task { [weak self] in
            guard let self else { return }
            defer { store.running = false; store.task = nil }
            let data = await self.loadJournal(days: 7)
            store.journalInfo = self.describe(data)
            guard let c = data.calibration else {
                store.message = "Zu wenige Protokolleinträge zum Messen (mindestens 10)."
                return
            }
            store.calibration = c
            store.autoMarket = false
            store.spreadBps = min(300, max(1, c.medianSpreadBps.rounded()))
            store.depthUSDT = min(20_000, max(200, (c.medianDepthUSDT / 100).rounded() * 100))
            store.message = "Gemessen: Spread typisch \(Fmt.bps(c.medianSpreadBps, digits: 1)) (90 %: \(Fmt.bps(c.p90SpreadBps, digits: 1))), Tiefe typisch \(Fmt.usdt(c.medianDepthUSDT, digits: 0)) USDT je Seite."
        }
    }

    func runBacktest() {
        guard !backtest.running, !backtest.optimizing else { return }
        let store = backtest
        store.running = true
        store.progress = 0
        store.message = store.source == .journal ? "Lese Marktprotokoll …" : "Lade Kerzen …"
        store.result = nil
        if store.source == .journal {
            store.task = Task { [weak self] in
                guard let self else { return }
                defer { store.running = false; store.task = nil }
                await self.runReplay(store)
            }
            return
        }
        if store.autoMarket { useLiveMarketForBacktest() }
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

    /// Replay: echte Orderbuecher und Kaeuferanteile aus dem eigenen Protokoll statt Annahmen.
    private func runReplay(_ store: BacktestStore) async {
        let data = await loadJournal(days: store.days)
        store.journalInfo = describe(data)
        if let c = data.calibration { store.calibration = c }
        guard data.frames.count >= 2 else {
            store.message = store.journalInfo
            return
        }
        // Kerzen fuer die Ausloeser: Protokoll und gespeicherter Verlauf zusammen.
        if let first = data.firstTime, (history.first?.openedAt ?? .infinity) > first - 3 * 3_600 {
            _ = await prepareHistory(days: store.days)
        }
        let candles = Indicators.normalize(history + data.candles)
        store.message = "Spiele \(data.frames.count) Marktmomente ab …"
        store.progress = 0.5
        let settings = bot.stored.settings
        let config = store.config(rules: rules)
        let frames = data.frames
        let worker = Task.detached(priority: .userInitiated) {
            Backtester.replay(frames: frames, candles: candles, settings: settings, config: config, shouldCancel: { Task.isCancelled })
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        store.result = result
        store.progress = 1
        store.message = result.cancelled ? "Abgebrochen" : "Fertig (Replay aus dem Marktprotokoll)"
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
        if store.autoMarket { useLiveMarketForBacktest() }
        store.optimizing = true
        store.progress = 0
        store.entries = []
        store.walkForward = nil
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
            let report = await Optimizer.runReport(candles: candles, base: base, config: config, axes: axes, objective: objective,
                                                   trainFraction: train, segments: Optimizer.defaultSegments, progress: { done, total in
                Task { @MainActor in store.progress = Double(done) / Double(max(1, total)) }
            })
            store.entries = report.entries
            store.walkForward = report.walkForward
            store.progress = 1
            let passing = report.entries.filter(\.passesTest).count
            store.message = Task.isCancelled ? "Abgebrochen" : "Fertig: \(report.entries.count) Ergebnisse, \(passing) davon im Test im Plus"
        }
    }

    func cancelBacktest() {
        backtest.task?.cancel()
    }

    /// Uebernimmt die Einstellungen eines Optimierungsergebnisses (nur die untersuchten Parameter).
    func apply(_ entry: OptimizerEntry) {
        guard entry.passesTest else {
            status.notice = "Nicht übernommen: Diese Kombination liegt im Testabschnitt nicht im Plus."
            return
        }
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
        lines.append("\(Self.appName) \(Self.version) · Bundle \(Bundle.main.bundleIdentifier ?? "?") · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
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
