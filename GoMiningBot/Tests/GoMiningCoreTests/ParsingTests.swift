import XCTest
@testable import GoMiningCore

final class ParsingTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testSymbolRules() throws {
        let json = """
        {"code":0,"data":{"symbols":[{"symbol":"GOMINING-USDT","status":1,"apiStateBuy":true,"apiStateSell":false,
        "minQty":0.01,"minNotional":2,"stepSize":0.01}]}}
        """
        let r = try BingXParser.parseSymbolRules(data(json), symbol: "GOMINING-USDT")
        XCTAssertEqual(r.minQuantity, 0.01)
        XCTAssertEqual(r.minNotional, 2)
        XCTAssertEqual(r.stepSize, 0.01)
        XCTAssertTrue(r.buyEnabled)
        XCTAssertFalse(r.sellEnabled)
        XCTAssertTrue(r.verified)
    }

    func testInactiveSymbolThrows() {
        let json = #"{"code":0,"data":{"symbols":[{"symbol":"GOMINING-USDT","status":0}]}}"#
        XCTAssertThrowsError(try BingXParser.parseSymbolRules(data(json), symbol: "GOMINING-USDT")) { error in
            XCTAssertEqual(error as? BingXError, .inactive("GOMINING-USDT"))
        }
    }

    func testMissingMinimumsFallBackConservatively() throws {
        let json = #"{"code":0,"data":{"symbols":[{"symbol":"GOMINING-USDT","status":1}]}}"#
        let r = try BingXParser.parseSymbolRules(data(json), symbol: "GOMINING-USDT")
        XCTAssertFalse(r.verified)
        XCTAssertEqual(r.minNotional, SymbolRules.fallback.minNotional)
    }

    func testApiErrorIsReported() {
        let json = #"{"code":100400,"msg":"Invalid parameters","data":null}"#
        XCTAssertThrowsError(try BingXParser.parseDepth(data(json))) { error in
            XCTAssertEqual(error as? BingXError, .api(code: 100400, message: "Invalid parameters"))
        }
    }

    func testKlineRowsAreSortedAndConvertedToSeconds() throws {
        let json = """
        {"code":0,"data":[
          [1700000060000,"1.05","1.10","1.00","1.08","50",1700000119999,"54"],
          [1700000000000,"1.00","1.06","0.98","1.05","40",1700000059999,"42"]
        ]}
        """
        let c = try BingXParser.parseKlines(data(json))
        XCTAssertEqual(c.map(\.openedAt), [1_700_000_000, 1_700_000_060])
        XCTAssertEqual([c[0].open, c[0].high, c[0].low, c[0].close, c[0].volume], [1.00, 1.06, 0.98, 1.05, 40])
        XCTAssertTrue(c[1].isGreen)
    }

    func testKlineColumnOrderIsDetected() throws {
        // [t, open, close, high, low, volume]
        let json = """
        {"code":0,"data":[
          [1700000000000,"1.00","1.05","1.06","0.98","40"],
          [1700000060000,"1.05","1.08","1.10","1.00","50"],
          [1700000120000,"1.08","1.02","1.09","1.01","60"]
        ]}
        """
        let c = try BingXParser.parseKlines(data(json))
        XCTAssertEqual([c[0].open, c[0].high, c[0].low, c[0].close], [1.00, 1.06, 0.98, 1.05])
        XCTAssertFalse(c[2].isGreen)
    }

    func testKlineObjectsAreAccepted() throws {
        let json = #"{"code":0,"data":[{"time":1700000000000,"open":"1","high":"2","low":"0.5","close":"1.5","volume":"9"}]}"#
        let c = try BingXParser.parseKlines(data(json))
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].high, 2)
    }

    func testEmptyKlinesThrow() {
        XCTAssertThrowsError(try BingXParser.parseKlines(data(#"{"code":0,"data":[]}"#)))
    }

    func testDepthIsSortedBestFirst() throws {
        let json = """
        {"code":0,"data":{"bids":[["0.99","10"],["1.00","5"],["0.98","1"]],"asks":[["1.03","2"],["1.01","7"]],"lastUpdateId":77}}
        """
        let book = try BingXParser.parseDepth(data(json))
        XCTAssertEqual(book.bids.map(\.price), [1.00, 0.99, 0.98])
        XCTAssertEqual(book.asks.map(\.price), [1.01, 1.03])
        XCTAssertEqual(book.sequence, 77)
    }

    func testPublicTradesDirectionAndOrder() throws {
        let json = """
        {"code":0,"data":[
          {"id":2,"price":"1.02","qty":"10","time":1700000010000,"buyerMaker":false},
          {"id":1,"price":"1.01","qty":"5","time":1700000000000,"buyerMaker":true}
        ]}
        """
        let t = try BingXParser.parseTrades(data(json))
        XCTAssertEqual(t.map(\.id), [1, 2])
        XCTAssertFalse(t[0].buyerInitiated)      // Kaeufer war Maker -> Verkaeufer hat zugeschlagen
        XCTAssertTrue(t[1].buyerInitiated)
        XCTAssertEqual(t[0].at, 1_700_000_000, accuracy: 1e-6)
    }

    func testStreamMessages() {
        XCTAssertTrue(isPing(BingXParser.parseStream(data("Ping"))))

        let depth = #"{"code":0,"dataType":"GOMINING-USDT@depth20","data":{"bids":[["1.0","3"]],"asks":[["1.1","4"]],"lastUpdateId":5}}"#
        if case .depth(let bids, let asks, let seq) = BingXParser.parseStream(data(depth)) {
            XCTAssertEqual(bids.first?.price, 1.0)
            XCTAssertEqual(asks.first?.quantity, 4)
            XCTAssertEqual(seq, 5)
        } else { XCTFail("Tiefe nicht erkannt") }

        let trade = #"{"code":0,"dataType":"GOMINING-USDT@trade","data":{"E":1700000000000,"T":1700000000001,"e":"trade","m":false,"p":"1.2","q":"10","s":"GOMINING-USDT","t":99}}"#
        if case .trades(let trades) = BingXParser.parseStream(data(trade)) {
            XCTAssertEqual(trades.count, 1)
            XCTAssertEqual(trades[0].id, 99)
            XCTAssertTrue(trades[0].buyerInitiated)
        } else { XCTFail("Trade nicht erkannt") }

        let ack = #"{"id":"abc","code":0,"msg":"SUCCESS","timestamp":1700000000000}"#
        if case .ack = BingXParser.parseStream(data(ack)) {} else { XCTFail("Bestaetigung nicht erkannt") }

        let failure = #"{"code":100400,"msg":"bad request"}"#
        if case .error(let message) = BingXParser.parseStream(data(failure)) { XCTAssertEqual(message, "bad request") }
        else { XCTFail("Fehler nicht erkannt") }
    }

    private func isPing(_ e: StreamEvent) -> Bool {
        if case .ping = e { return true }
        return false
    }

    func testBalancesAndCommission() throws {
        let balances = #"{"code":0,"data":{"balances":[{"asset":"USDT","free":"12.5","locked":"1"},{"asset":"GOMINING","free":"100","locked":"0"}]}}"#
        let b = try BingXParser.parseBalances(data(balances))
        XCTAssertEqual(b.first(where: { $0.asset == "USDT" })?.total, 13.5)

        let commission = #"{"code":0,"data":{"takerCommissionRate":0.001,"makerCommissionRate":0.0008}}"#
        let c = try BingXParser.parseCommission(data(commission))
        XCTAssertEqual(c.takerBps, 10, accuracy: 1e-9)
        XCTAssertEqual(c.makerBps, 8, accuracy: 1e-9)
    }

    // MARK: gzip

    func testGzipRoundTrip() throws {
        let text = String(repeating: #"{"code":0,"dataType":"GOMINING-USDT@trade"}"#, count: 20)
        let wrapped = try XCTUnwrap(Gzip.wrapForTests(Data(text.utf8)))
        let decoded = try XCTUnwrap(Gzip.decode(wrapped))
        XCTAssertEqual(String(data: decoded, encoding: .utf8), text)
    }

    func testPlainTextPassesThrough() throws {
        let ping = try XCTUnwrap(Gzip.decode(Data("Ping".utf8)))
        XCTAssertEqual(String(data: ping, encoding: .utf8), "Ping")
        let json = try XCTUnwrap(Gzip.decode(Data(#"{"a":1}"#.utf8)))
        XCTAssertEqual(String(data: json, encoding: .utf8), #"{"a":1}"#)
    }

    func testGarbageIsRejected() {
        XCTAssertNil(Gzip.decode(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(Gzip.decode(Data()))
    }
}
