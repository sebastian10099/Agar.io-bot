import XCTest
@testable import GoMiningCore

// MARK: - Profile

final class ProfileTests: XCTestCase {
    func testAdoptingStrategyKeepsAccountValues() {
        var mine = BotSettings()
        mine.startingUSDT = 2_000
        mine.feeBps = 7
        mine.makerFeeBps = 3
        mine.slippageBps = 1
        var other = BotSettings()
        other.startingUSDT = 50
        other.feeBps = 30
        other.minNetProfitBps = 120
        other.minBuyStepBps = 40
        let merged = mine.adoptingStrategy(from: other)
        XCTAssertEqual(merged.startingUSDT, 2_000)
        XCTAssertEqual(merged.feeBps, 7)
        XCTAssertEqual(merged.makerFeeBps, 3)
        XCTAssertEqual(merged.slippageBps, 1)
        XCTAssertEqual(merged.minNetProfitBps, 120)
        XCTAssertEqual(merged.minBuyStepBps, 40)
    }

    func testSaveReplacesSameNameAndImportRenames() {
        var book = ProfileBook()
        var s = BotSettings()
        s.minNetProfitBps = 70
        let first = book.save(name: "  Mein Profil ", settings: s, at: 1)
        XCTAssertEqual(first.name, "Mein Profil")
        s.minNetProfitBps = 90
        book.save(name: "mein profil", settings: s, at: 2)
        XCTAssertEqual(book.profiles.count, 1)
        XCTAssertEqual(book.profiles[0].settings.minNetProfitBps, 90)
        XCTAssertEqual(book.profiles[0].id, first.id)
        let imported = book.add(imported: SettingsProfile(name: "Mein Profil", settings: s, createdAt: 3))
        XCTAssertEqual(imported.name, "Mein Profil (2)")
        XCTAssertNotEqual(imported.id, first.id)
        book.remove(first.id)
        XCTAssertEqual(book.profiles.map(\.name), ["Mein Profil (2)"])
        XCTAssertEqual(book.save(name: "", settings: s, at: 4).name, "Profil")
    }

    func testProfileFileRoundTripAndForeignFormats() throws {
        var s = BotSettings()
        s.stopLossFraction = 0.04
        let profile = SettingsProfile(name: "Teilen", settings: s, createdAt: 5, note: "Test")
        let data = try ProfileFile.encode(profile, appVersion: "4.3")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(ProfileFile.format))
        let back = try XCTUnwrap(ProfileFile.decode(data))
        XCTAssertEqual(back, profile)

        // Ganze simulation.json: Einstellungen werden herausgelesen.
        let stored = StoredBot.fresh(settings: s, at: 0, seedStartPosition: false)
        let storedData = try JSONEncoder().encode(stored)
        XCTAssertEqual(ProfileFile.decode(storedData, fallbackName: "Sicherung")?.settings.stopLossFraction, 0.04)
        XCTAssertEqual(ProfileFile.decode(storedData, fallbackName: "Sicherung")?.name, "Sicherung")
        // Nackte Einstellungen.
        XCTAssertEqual(ProfileFile.decode(Data(#"{"minNetProfitBps": 77}"#.utf8))?.settings.minNetProfitBps, 77)
        // Fremdes JSON wird abgelehnt.
        XCTAssertNil(ProfileFile.decode(Data(#"{"hallo": 1}"#.utf8)))
        XCTAssertNil(ProfileFile.decode(Data("kein json".utf8)))
    }

    func testBookToleratesBrokenEntries() throws {
        let json = #"{"profiles":[{"name":"A","settings":{"minNetProfitBps":-5}},{"name":"B"}]}"#
        let book = try JSONDecoder().decode(ProfileBook.self, from: Data(json.utf8))
        XCTAssertEqual(book.profiles.count, 2)
        XCTAssertEqual(book.profiles[0].settings.minNetProfitBps, 0, "wird auf den erlaubten Bereich begrenzt")
        XCTAssertEqual(book.profiles[1].settings, BotSettings().clamped())
    }
}

// MARK: - Berichte

final class ReportTests: XCTestCase {
    private func event(_ action: String, at t: Double, pnl: Double = 0, fee: Double = 0.05) -> BotEvent {
        BotEvent(at: t, action: action, reason: "Grund <b>", bidUSDT: 1, askUSDT: 1.001, quantity: 10, priceUSDT: 1,
                 feeUSDT: fee, realizedPnLUSDT: pnl, equityUSDT: 1_000)
    }

    func testPeriodCountsOnlyTradesInside() {
        let events = [event(BotAction.buy, at: 50), event(BotAction.buy, at: 100), event(BotAction.sell, at: 150, pnl: 0.4),
                      event(BotAction.sell, at: 180, pnl: -0.1), event(BotAction.sell, at: 250, pnl: 9),
                      BotEvent(at: 120, action: BotAction.wait, reason: "", bidUSDT: 1, askUSDT: 1, equityUSDT: 1_000)]
        let equity = [EquityPoint(t: 90, equity: 1_000, hold: 1_000), EquityPoint(t: 130, equity: 1_001, hold: 990),
                      EquityPoint(t: 190, equity: 1_002, hold: 980)]
        let r = ReportBuilder.period(title: "Test", events: events, equity: equity, from: 100, to: 200)
        XCTAssertEqual(r.buys, 1)
        XCTAssertEqual(r.sells, 2)
        XCTAssertEqual(r.wins, 1)
        XCTAssertEqual(r.realizedPnL, 0.3, accuracy: 1e-9)
        XCTAssertEqual(r.fees, 0.15, accuracy: 1e-9)
        XCTAssertEqual(r.bestTrade ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(r.worstTrade ?? 0, -0.1, accuracy: 1e-9)
        XCTAssertEqual(r.equityStart, 1_000)                 // letzter Punkt vor dem Zeitraum
        XCTAssertEqual(r.equityEnd, 1_002)
        XCTAssertEqual(r.equityChange ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(r.holdChangeFraction ?? 0, -0.02, accuracy: 1e-9)
        XCTAssertEqual(r.winRate ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertFalse(r.isEmpty)
    }

    func testCurrentEquityEndsTheOpenPeriod() {
        let equity = [EquityPoint(t: 10, equity: 1_000), EquityPoint(t: 20, equity: 1_001)]
        let r = ReportBuilder.period(title: "Heute", events: [], equity: equity, from: 0, to: 1_000, currentEquity: 1_005)
        XCTAssertEqual(r.equityEnd, 1_005)
        XCTAssertEqual(r.equity.last?.equity, 1_005)
        XCTAssertTrue(ReportBuilder.summaryText(r).hasPrefix("Keine Trades"))
    }

    func testHTMLIsSelfContainedAndEscaped() {
        let events = [event(BotAction.buy, at: 100), event(BotAction.sell, at: 150, pnl: 0.4)]
        let equity = (0..<10).map { EquityPoint(t: 100 + Double($0) * 10, equity: 1_000 + Double($0), hold: 1_000 - Double($0)) }
        let r = ReportBuilder.period(title: "Wochenbericht <Test>", events: events, equity: equity, from: 0, to: 1_000)
        let html = ReportBuilder.html(r, appName: "GoMining Bot Pro", appVersion: "4.3", settings: BotSettings(),
                                      generatedAt: 1_000, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("Wochenbericht &lt;Test&gt;"))
        XCTAssertTrue(html.contains("Grund &lt;b&gt;"))
        XCTAssertFalse(html.contains("<b>"))
        XCTAssertTrue(html.contains("<svg"))
        XCTAssertTrue(html.contains("stroke-dasharray"), "Halten-Linie")
        XCTAssertTrue(html.contains("+0,40"))
        XCTAssertTrue(html.contains("Mindest-Kaufabstand"))
        XCTAssertFalse(html.contains("http://") && html.contains("<script"), "keine externen Skripte")
    }

    func testSummaryText() {
        let events = [event(BotAction.buy, at: 1), event(BotAction.sell, at: 2, pnl: 1.25)]
        let equity = [EquityPoint(t: 0, equity: 1_000), EquityPoint(t: 3, equity: 1_001.25)]
        let text = ReportBuilder.summaryText(ReportBuilder.period(title: "Gestern", events: events, equity: equity, from: 0, to: 10))
        XCTAssertTrue(text.contains("1 Käufe, 1 Verkäufe"), text)
        XCTAssertTrue(text.contains("realisiert +1,25 USDT"), text)
        XCTAssertTrue(text.contains("Gewinnquote 100 %"), text)
    }
}

// MARK: - Vermoegensverlauf der Schattenkonten

final class ShadowHistoryTests: XCTestCase {
    func testSamplingOncePerMinuteAndThinning() {
        var account = ShadowAccount(name: "A", settings: BotSettings(), at: 0, bid: 1)
        XCTAssertEqual(account.history.points.count, 1)
        account.sample(bid: 1, now: 30)
        XCTAssertEqual(account.history.points.count, 1, "höchstens ein Punkt pro Minute")
        for i in 1...(ShadowAccount.historyLimit + 50) { account.sample(bid: 1, now: Double(i) * 60) }
        XCTAssertLessThanOrEqual(account.history.points.count, ShadowAccount.historyLimit)
        XCTAssertEqual(account.history.points.last?.t, Double(ShadowAccount.historyLimit + 50) * 60)
        account.reset(at: 10, bid: 1)
        XCTAssertEqual(account.history.points.count, 1)
    }

    func testOldShadowFilesWithoutHistoryLoad() throws {
        let book = try JSONDecoder().decode(ShadowBook.self, from: Data(#"{"accounts":[{"name":"Alt","createdAt":5}]}"#.utf8))
        XCTAssertEqual(book.accounts.first?.history.points.count, 0)
    }
}
