import XCTest
@testable import TabMapCore

final class AgentProtocolTests: XCTestCase {
    private func raw(_ s: String) -> Data { Data(s.utf8) }

    func testParsesCompleteRequest() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let text = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47823\r\nContent-Length: \(body.utf8.count)\r\nAuthorization: Bearer abc\r\n\r\n\(body)"
        guard case .request(let request, let consumed) = HTTPRequestParser.parse(raw(text)) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.headers["authorization"], "Bearer abc")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
        XCTAssertEqual(consumed, text.utf8.count)
    }

    func testWaitsForTheWholeBody() {
        let text = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\n12345"
        XCTAssertEqual(HTTPRequestParser.parse(raw(text)), .incomplete)
        XCTAssertEqual(HTTPRequestParser.parse(raw("POST /mcp HTTP/1.1\r\nHost: x")), .incomplete)
    }

    func testRejectsChunkedAndGarbage() {
        if case .invalid = HTTPRequestParser.parse(raw("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) {} else {
            XCTFail("chunked should be refused")
        }
        if case .invalid = HTTPRequestParser.parse(raw("hello\r\n\r\n")) {} else { XCTFail("garbage should be refused") }
    }

    private func request(_ headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data())
    }

    func testAccessNeedsTokenAndLocalHost() {
        let token = "s3cret"
        XCTAssertEqual(AgentAccess.check(request(["host": "127.0.0.1:47823", "authorization": "Bearer s3cret"]), token: token), .allowed)
        XCTAssertEqual(AgentAccess.check(request(["host": "localhost:47823", "authorization": "bearer s3cret"]), token: token), .allowed)
        XCTAssertEqual(AgentAccess.check(request(["host": "[::1]:47823", "authorization": "Bearer s3cret"]), token: token), .allowed)
        XCTAssertEqual(AgentAccess.check(request(["host": "127.0.0.1:47823", "authorization": "Bearer nope"]), token: token), .unauthorized)
        XCTAssertEqual(AgentAccess.check(request(["host": "127.0.0.1:47823"]), token: token), .unauthorized)
        XCTAssertEqual(AgentAccess.check(request(["host": "127.0.0.1", "authorization": "Bearer s3cret"]), token: ""), .unauthorized)
    }

    func testWebPagesAreRefused() {
        let fromPage = request(["host": "127.0.0.1:47823", "origin": "https://evil.example", "authorization": "Bearer t"])
        if case .forbidden = AgentAccess.check(fromPage, token: "t") {} else { XCTFail("pages must be refused") }
        let rebound = request(["host": "evil.example:47823", "authorization": "Bearer t"])
        if case .forbidden = AgentAccess.check(rebound, token: "t") {} else { XCTFail("foreign hosts must be refused") }
    }

    func testTokensAreRandomHex() {
        let a = AgentAccess.makeToken(), b = AgentAccess.makeToken()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
    }

    func testKeyParsing() {
        XCTAssertEqual(AgentKey.parse("Enter"), AgentKey(keyCode: 36, characters: "\r"))
        XCTAssertEqual(AgentKey.parse("cmd+a"), AgentKey(keyCode: 0, characters: "a", modifiers: [.command]))
        XCTAssertEqual(AgentKey.parse("Shift+Tab"), AgentKey(keyCode: 48, characters: "\t", modifiers: [.shift]))
        XCTAssertEqual(AgentKey.parse("ctrl+option+ArrowUp")?.modifiers, [.control, .option])
        XCTAssertEqual(AgentKey.parse("A")?.modifiers, [.shift])
        XCTAssertNil(AgentKey.parse("hyper+a"))
        XCTAssertNil(AgentKey.parse("F13"))
    }

    private func signals(title: String = "Shop", url: String = "https://shop.example/",
                         frames: [String] = [], markers: [String] = [], visible: Bool = true) -> PageSignals {
        PageSignals(title: title, url: url, frameURLs: frames, markers: markers, visibleWidget: visible)
    }

    func testSpotsHumanChecks() {
        XCTAssertEqual(HumanCheck.detect(signals(title: "Just a moment...")), "Cloudflare check")
        XCTAssertEqual(HumanCheck.detect(signals(frames: ["https://www.google.com/recaptcha/api2/anchor?k=x&size=normal"])), "reCAPTCHA")
        XCTAssertEqual(HumanCheck.detect(signals(frames: ["https://newassets.hcaptcha.com/captcha/v1/x"])), "hCaptcha")
        XCTAssertEqual(HumanCheck.detect(signals(markers: ["cf-turnstile"])), "Cloudflare check")
        XCTAssertEqual(HumanCheck.detect(signals(url: "https://www.google.com/sorry/index?continue=x")), "Google robot check")
    }

    func testIgnoresInvisibleWidgets() {
        XCTAssertNil(HumanCheck.detect(signals()))
        XCTAssertNil(HumanCheck.detect(signals(frames: ["https://www.google.com/recaptcha/api2/anchor?k=x&size=invisible"])))
        XCTAssertNil(HumanCheck.detect(signals(markers: ["g-recaptcha"], visible: false)))
    }

    func testPointerPathEndsOnTarget() {
        let path = PointerPath.points(from: (0, 0), to: (300, 120))
        XCTAssertGreaterThan(path.count, 4)
        XCTAssertEqual(path.last!.x, 300, accuracy: 0.001)
        XCTAssertEqual(path.last!.y, 120, accuracy: 0.001)
        XCTAssertEqual(PointerPath.points(from: (5, 5), to: (5, 5)).count, 1)
    }
}
