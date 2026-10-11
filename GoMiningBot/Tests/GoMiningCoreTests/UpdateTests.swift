import XCTest
@testable import GoMiningCore

final class UpdateTests: XCTestCase {
    func testVersionComparison() throws {
        let v41 = try XCTUnwrap(AppVersion("4.1"))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("4.0")), v41)
        XCTAssertLessThan(v41, try XCTUnwrap(AppVersion("4.10")))
        XCTAssertLessThan(v41, try XCTUnwrap(AppVersion("4.1.1")))
        XCTAssertEqual(v41, try XCTUnwrap(AppVersion("4.1.0")))
        XCTAssertEqual(AppVersion("gomining-bot-v4.2")?.description, "4.2")
        XCTAssertEqual(AppVersion("v5")?.description, "5")
        XCTAssertNil(AppVersion("kaputt"))
    }

    func testParsesLatestRelease() throws {
        let json = """
        {"tag_name":"gomining-bot-v4.2","html_url":"https://github.com/o/r/releases/tag/gomining-bot-v4.2","draft":false,
         "body":"## Neu\\n- vieles","published_at":"2026-10-12T08:00:00Z",
         "assets":[{"name":"andere.txt","browser_download_url":"https://x/andere.txt"},
                   {"name":"GoMining-Bot.zip","browser_download_url":"https://github.com/o/r/releases/download/gomining-bot-v4.2/GoMining-Bot.zip"}]}
        """
        let info = try XCTUnwrap(ReleaseParser.parseLatest(Data(json.utf8)))
        XCTAssertEqual(info.version.description, "4.2")
        XCTAssertEqual(info.downloadURL?.lastPathComponent, "GoMining-Bot.zip")
        XCTAssertTrue(info.notes.contains("vieles"))
        XCTAssertNil(ReleaseParser.parseLatest(Data(#"{"message":"Not Found"}"#.utf8)))
    }

    func testChangelogSection() {
        let md = """
        # Änderungen

        ## 4.2 – 12.10.2026
        - Punkt A
        - Punkt B

        ## 4.1
        - Alt
        """
        XCTAssertEqual(ReleaseParser.changelogSection(md, version: "4.2"), "- Punkt A\n- Punkt B")
        XCTAssertEqual(ReleaseParser.changelogSection(md, version: "4.1"), "- Alt")
        XCTAssertNil(ReleaseParser.changelogSection(md, version: "9.9"))
    }

    /// Fuehrt das echte Installationsskript mit Platzhalter-Bundles aus.
    func testInstallerScriptReplacesAppAndKeepsOldOnFailure() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gomining-update-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("Ziel.app")
        let new = root.appendingPathComponent("Neu.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("alt".utf8).write(to: target.appendingPathComponent("version.txt"))
        try Data("neu".utf8).write(to: new.appendingPathComponent("version.txt"))
        let script = root.appendingPathComponent("install.sh")
        try UpdateInstaller.script.write(to: script, atomically: true, encoding: .utf8)

        func run(_ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path] + args
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }

        // PID 999999 laeuft nicht -> es wird sofort ersetzt.
        XCTAssertEqual(try run(["999999", new.path, target.path, "noopen"]), 0)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version.txt"), encoding: .utf8), "neu")
        XCTAssertFalse(fm.fileExists(atPath: target.path + ".vor-update"))

        // Ungueltige Ziele werden abgelehnt, nichts wird angefasst.
        XCTAssertNotEqual(try run(["999999", new.path, root.path, "noopen"]), 0)
        XCTAssertTrue(fm.fileExists(atPath: root.path))
        XCTAssertNotEqual(try run(["999999", root.appendingPathComponent("Fehlt.app").path, target.path, "noopen"]), 0)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version.txt"), encoding: .utf8), "neu")
    }

    func testReplaceIsRefusedForTranslocatedApps() {
        XCTAssertFalse(UpdateInstaller.canReplace(appAt: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/GoMining Bot.app")))
        XCTAssertFalse(UpdateInstaller.canReplace(appAt: URL(fileURLWithPath: "/tmp/kein-bundle")))
    }
}

final class TrendFilterTests: XCTestCase {
    private let now = Fixture.now

    /// 150 Kerzen, die stetig um insgesamt `dropPercent` fallen (letzte schliesst kurz vor `now`).
    private func falling(dropPercent: Double) -> [PriceCandle] {
        let stepFraction: Double = dropPercent / 100 / 149
        var closes: [Double] = []
        for i in 0..<150 { closes.append(1.0 - stepFraction * Double(i)) }
        return MoveDetectorTests.candles(closes, endingAt: now - 70)
    }

    func testEMAFollowsPrice() throws {
        let flat = Fixture.candles(price: 1.0, count: 150)
        let ema = try XCTUnwrap(Indicators.ema(flat, period: 30))
        XCTAssertEqual(ema, 1.0, accuracy: 0.001)
        XCTAssertNil(Indicators.ema(Array(flat.prefix(10)), period: 30))
        let down = falling(dropPercent: 5)
        let fast = try XCTUnwrap(Indicators.ema(down, period: 30))
        let slow = try XCTUnwrap(Indicators.ema(down, period: 120))
        XCTAssertLessThan(fast, slow)
    }

    func testDowntrendBlocksBuyingOnlyWhenEnabled() {
        var s = Fixture.settings()
        s.useMoveDetector = false
        s.trendFilterEnabled = false
        let candles = falling(dropPercent: 5)
        let price = candles.last!.close * 0.985
        let snap = Fixture.snapshot(mid: price, candles: candles)

        var off = BotState.fresh(s, at: now)
        let r1 = BotEngine.step(snap, state: &off, settings: s, fastMoveBps: 0, now: now)
        XCTAssertNotEqual(r1.reason.hasPrefix("Abwärtstrend"), true)

        s.trendFilterEnabled = true
        var on = BotState.fresh(s, at: now)
        let r2 = BotEngine.step(snap, state: &on, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r2.kind, .wait)
        XCTAssertTrue(r2.reason.hasPrefix("Abwärtstrend"), r2.reason)
        XCTAssertTrue(on.lots.isEmpty)
    }

    func testTrendFilterDoesNotBlockSelling() {
        var s = Fixture.settings()
        s.trendFilterEnabled = true
        s.useMoveDetector = false
        var state = BotState.fresh(s, at: now)
        state.lots = [PositionLot(quantity: 50, costBasisUSDT: 50.05, buyPriceUSDT: 1.0, boughtAt: now - 600)]
        state.cashUSDT -= 50.05
        BotEngine.normalize(&state)
        // Fallender Trend, aber der Kurs liegt ueber dem Einstand: Gewinnverkauf bleibt erlaubt.
        let candles = falling(dropPercent: 5).map { c -> PriceCandle in
            var c = c; c.open *= 1.1; c.high *= 1.1; c.low *= 1.1; c.close *= 1.1; return c
        }
        let r = BotEngine.step(Fixture.snapshot(mid: 1.03, candles: candles), state: &state, settings: s, fastMoveBps: 0, now: now)
        XCTAssertEqual(r.kind, .sell, r.reason)
    }

    func testTrendFilterIsOnByDefault() {
        XCTAssertTrue(BotSettings().trendFilterEnabled)
        // Auch fuer alte Dateien ohne den Schluessel.
        let decoded = try? JSONDecoder().decode(BotSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded?.trendFilterEnabled, true)
    }

    func testSettingsKeepFastBelowSlow() {
        var s = BotSettings()
        s.trendFastMinutes = 500
        s.trendSlowMinutes = 100
        let c = s.clamped()
        XCTAssertLessThan(c.trendFastMinutes, c.trendSlowMinutes)
        XCTAssertGreaterThanOrEqual(c.requiredCandles, c.trendSlowMinutes + 10)
    }

    func testBacktestWithTrendFilterRuns() {
        var s = BotSettings()
        s.trendFilterEnabled = true
        let r = Backtester.run(candles: Fixture.sineCandles(count: 2 * 24 * 60), settings: s, config: BacktestConfig())
        XCTAssertTrue(r.finalEquity.isFinite)
        XCTAssertGreaterThan(r.buys, 0)
    }
}
