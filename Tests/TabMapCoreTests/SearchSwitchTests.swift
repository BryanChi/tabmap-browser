import XCTest
@testable import TabMapCore

final class SearchSwitchTests: XCTestCase {
    let google = "https://www.google.com/search?q=%s"

    func testReadsQueryFromGoogleResults() {
        let url = URL(string: "https://www.google.com/search?q=rust+async&oq=rust&sourceid=chrome")!
        XCTAssertEqual(SearchSwitch.query(in: url, searchTemplate: google), "rust async")
        let plus = URL(string: "https://www.google.com/search?q=c%2B%2B")!
        XCTAssertEqual(SearchSwitch.query(in: plus, searchTemplate: google), "c++")
        let spaced = URL(string: "https://google.com/search?q=rust%20async")!
        XCTAssertEqual(SearchSwitch.query(in: spaced, searchTemplate: google), "rust async")
    }

    func testIgnoresOtherPages() {
        let cases = [
            "https://www.google.com/",
            "https://www.google.com/search?q=",
            "https://www.google.com/maps/search/cafe",
            "https://www.google.com/search?q=cats&udm=2",
            "https://www.bing.com/search?q=cats",
            "https://mail.google.com/search?q=cats",
        ]
        for c in cases { XCTAssertNil(SearchSwitch.query(in: URL(string: c), searchTemplate: google), c) }
    }

    func testOtherEngines() {
        XCTAssertEqual(SearchSwitch.query(in: URL(string: "https://duckduckgo.com/?q=tea&ia=web"),
                                          searchTemplate: "https://duckduckgo.com/?q=%s"), "tea")
        XCTAssertEqual(SearchSwitch.query(in: URL(string: "https://kagi.com/search?q=tea"),
                                          searchTemplate: "https://kagi.com/search?q=%s"), "tea")
    }

    func testBuildsTargetURLs() {
        let yt = SearchSwitch.targets.first { $0.id == "youtube" }!
        XCTAssertEqual(SearchSwitch.url(for: yt, query: "lofi & chill")?.absoluteString,
                       "https://www.youtube.com/results?search_query=lofi%20%26%20chill")
        let maps = SearchSwitch.targets.first { $0.id == "maps" }!
        XCTAssertEqual(SearchSwitch.url(for: maps, query: "cafe/bar")?.absoluteString,
                       "https://www.google.com/maps/search/cafe%2Fbar")
        let gemini = SearchSwitch.targets.first { $0.id == "gemini" }!
        XCTAssertEqual(SearchSwitch.url(for: gemini, query: "why sky blue?")?.absoluteString,
                       "https://gemini.google.com/app#tabmap-q=why%20sky%20blue?")
    }
}
