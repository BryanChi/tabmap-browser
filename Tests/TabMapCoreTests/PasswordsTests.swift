import XCTest
@testable import TabMapCore

final class PasswordsTests: XCTestCase {

    // MARK: Which site a login belongs to

    func testRegistrableDomain() {
        XCTAssertEqual(LoginDomain.registrable("accounts.google.com"), "google.com")
        XCTAssertEqual(LoginDomain.registrable("WWW.GitHub.com."), "github.com")
        XCTAssertEqual(LoginDomain.registrable("github.com"), "github.com")
        XCTAssertEqual(LoginDomain.registrable("shop.example.co.uk"), "example.co.uk")
        XCTAssertEqual(LoginDomain.registrable("bryan.github.io"), "bryan.github.io")
        XCTAssertEqual(LoginDomain.registrable("localhost"), "localhost")
        XCTAssertEqual(LoginDomain.registrable("192.168.1.10"), "192.168.1.10")
        XCTAssertNil(LoginDomain.registrable(""))
        XCTAssertNil(LoginDomain.registrable(nil))
    }

    func testMatchingAcrossSubdomainsButNotAcrossSites() {
        XCTAssertTrue(LoginDomain.matches(savedHost: "google.com", pageHost: "accounts.google.com"))
        XCTAssertTrue(LoginDomain.matches(savedHost: "www.apple.com", pageHost: "idmsa.apple.com"))
        XCTAssertFalse(LoginDomain.matches(savedHost: "google.com", pageHost: "google.com.evil.net"))
        XCTAssertFalse(LoginDomain.matches(savedHost: "alice.github.io", pageHost: "mallory.github.io"))
        XCTAssertFalse(LoginDomain.matches(savedHost: "bbc.co.uk", pageHost: "evil.co.uk"))
        XCTAssertFalse(LoginDomain.matches(savedHost: "10.0.0.1", pageHost: "10.0.0.2"))
    }

    // MARK: Order of suggestions

    func testExactHostFirstThenMostRecent() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let logins = [
            SavedLogin(host: "google.com", username: "work@x.com", lastUsed: new),
            SavedLogin(host: "accounts.google.com", username: "me@gmail.com", lastUsed: old),
            SavedLogin(host: "accounts.google.com", username: "alt@gmail.com", lastUsed: new),
            SavedLogin(host: "github.com", username: "bryan"),
        ]
        let picked = LoginMatcher.candidates(logins, pageHost: "accounts.google.com").map(\.username)
        XCTAssertEqual(picked, ["alt@gmail.com", "me@gmail.com", "work@x.com"])
        XCTAssertEqual(LoginMatcher.candidates(logins, pageHost: "www.github.com").map(\.username), ["bryan"])
        XCTAssertTrue(LoginMatcher.candidates(logins, pageHost: "example.com").isEmpty)
    }

    // MARK: Save or update

    func testSaveOffer() {
        XCTAssertEqual(SaveDecision.offer(username: "a", password: "pw", existing: [:], neverSave: false), .save)
        XCTAssertEqual(SaveDecision.offer(username: "a", password: "pw", existing: ["a": true], neverSave: false), .none)
        XCTAssertEqual(SaveDecision.offer(username: " a ", password: "pw2", existing: ["a": false], neverSave: false), .update)
        XCTAssertEqual(SaveDecision.offer(username: "b", password: "pw", existing: ["a": false], neverSave: false), .save)
        XCTAssertEqual(SaveDecision.offer(username: "a", password: "", existing: [:], neverSave: false), .none)
        XCTAssertEqual(SaveDecision.offer(username: "a", password: "pw", existing: [:], neverSave: true), .none)
    }

    // MARK: Suggested passwords

    func testGeneratedPasswordShape() {
        for _ in 0..<200 {
            let p = PasswordGenerator.generate()
            let groups = p.split(separator: "-")
            XCTAssertEqual(groups.count, 3, p)
            XCTAssertTrue(groups.allSatisfy { $0.count == 6 }, p)
            XCTAssertTrue(p.contains { $0.isUppercase }, p)
            XCTAssertTrue(p.contains { $0.isNumber }, p)
            XCTAssertFalse(p.contains { "lIO01".contains($0) }, p)
        }
        XCTAssertNotEqual(PasswordGenerator.generate(), PasswordGenerator.generate())
    }
}
