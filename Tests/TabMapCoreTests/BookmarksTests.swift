import XCTest
@testable import TabMapCore

final class BookmarksTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func page(_ address: String, _ title: String, at offset: TimeInterval = 0) -> Bookmark {
        Bookmark(url: URL(string: address)!, title: title, now: t0.addingTimeInterval(offset))
    }

    // MARK: Same page

    func testSamePageIgnoresSchemeWWWSlashAndAnchor() {
        var library = BookmarkLibrary()
        library.add(page("https://www.example.com/ramen/", "Ramen"))
        XCTAssertNotNil(library.bookmark(forPage: URL(string: "http://example.com/ramen#menu")!))
        XCTAssertNil(library.bookmark(forPage: URL(string: "https://example.com/ramen?page=2")!))
        XCTAssertNil(library.bookmark(forPage: URL(string: "https://example.com/udon")!))
    }

    func testSavedRowIsNotMistakenForItsFirstPage() {
        var library = BookmarkLibrary()
        let url = URL(string: "https://example.com/a")!
        library.add(Bookmark(url: url, title: "Trip", pages: [SavedPage(url: url, title: "A"),
                                                              SavedPage(url: URL(string: "https://example.com/b")!, title: "B")], now: t0))
        XCTAssertNil(library.bookmark(forPage: url))
    }

    // MARK: Highlights

    func testHighlightIsAddedOnceAndTrimmed() {
        var library = BookmarkLibrary()
        let b = page("https://example.com", "Example")
        library.add(b)
        XCTAssertTrue(library.addHighlight("  a fine passage \n", to: b.id, now: t0))
        XCTAssertFalse(library.addHighlight("a fine passage", to: b.id, now: t0))
        XCTAssertFalse(library.addHighlight("   ", to: b.id, now: t0))
        XCTAssertEqual(library.bookmark(b.id)?.highlights.map(\.text), ["a fine passage"])
    }

    // MARK: Smart collections

    func testSmartCollections() {
        var library = BookmarkLibrary()
        var old = page("https://example.com/old", "Old", at: -30 * 86400)
        old.lastOpenedAt = t0
        var recipe = page("https://example.com/soup", "Soup", at: -3600)
        recipe.collection = "Recipes"
        var changed = page("https://example.com/news", "News", at: -2 * 86400)
        changed.changedAt = t0
        library.add(old); library.add(recipe); library.add(changed)
        library.addHighlight("quote", to: recipe.id, now: t0)

        XCTAssertEqual(library.bookmarks(in: .all, now: t0).map(\.title), ["Soup", "News", "Old"])
        XCTAssertEqual(library.bookmarks(in: .thisWeek, now: t0).map(\.title), ["Soup", "News"])
        XCTAssertEqual(library.bookmarks(in: .readLater, now: t0).map(\.title), ["Soup", "News"])
        XCTAssertEqual(library.bookmarks(in: .highlights, now: t0).map(\.title), ["Soup"])
        XCTAssertEqual(library.bookmarks(in: .changed, now: t0).map(\.title), ["News"])
        XCTAssertEqual(library.bookmarks(in: .collection("Recipes"), now: t0).map(\.title), ["Soup"])
        XCTAssertEqual(library.count(in: .offline, now: t0), 0)
        XCTAssertEqual(library.collections().map(\.name), ["Recipes"])
    }

    func testOpeningClearsReadLaterAndChanged() {
        var library = BookmarkLibrary()
        var b = page("https://example.com", "Example")
        b.changedAt = t0
        library.add(b)
        library.markOpened(b.id, now: t0)
        XCTAssertEqual(library.count(in: .readLater, now: t0), 0)
        XCTAssertEqual(library.count(in: .changed, now: t0), 0)
    }

    // MARK: Search

    func testSearchFindsByTagsSummaryColoursAndPageText() {
        var ramen = page("https://menya.example/shop", "Menya Hanabi", at: 1)
        ramen.tags = ["ramen", "tokyo"]
        ramen.collection = "Places"
        ramen.colors = ["blue", "light"]
        var soup = page("https://cook.example/soup", "Tomato soup", at: 2)
        soup.summary = "A quick soup for weeknights"
        let plain = page("https://example.com/x", "Something else", at: 3)
        let all = [ramen, soup, plain]
        let texts = [plain.id: "the quarterly report mentions kumquats once"]

        XCTAssertEqual(BookmarkSearch.rank(all, query: "that ramen place with the blue logo").first?.id, ramen.id)
        XCTAssertEqual(BookmarkSearch.rank(all, query: "weeknights").map(\.id), [soup.id])
        XCTAssertEqual(BookmarkSearch.rank(all, query: "kumquats", texts: texts).map(\.id), [plain.id])
        XCTAssertEqual(BookmarkSearch.rank(all, query: "zebra"), [])
        XCTAssertEqual(BookmarkSearch.rank(all, query: "  ").count, 3)
    }

    func testSearchPrefersTitleOverPageText() {
        let inTitle = page("https://a.example", "Sourdough starter", at: 1)
        let inText = page("https://b.example", "Baking notes", at: 2)
        let ranked = BookmarkSearch.rank([inText, inTitle], query: "sourdough", texts: [inText.id: "about sourdough"])
        XCTAssertEqual(ranked.map(\.id), [inTitle.id, inText.id])
    }

    func testSearchNeedsEveryWordWhenSomethingHasThemAll() {
        var a = page("https://a.example", "Blue bicycle", at: 1)
        a.tags = ["repair"]
        let b = page("https://b.example", "Blue whale", at: 2)
        XCTAssertEqual(BookmarkSearch.rank([a, b], query: "blue repair").map(\.id), [a.id])
    }

    func testFillerWordsAloneStillSearch() {
        let b = page("https://a.example", "The Thing", at: 1)
        XCTAssertEqual(BookmarkSearch.terms("the thing"), ["the", "thing"])
        XCTAssertEqual(BookmarkSearch.rank([b], query: "the thing").count, 1)
    }

    // MARK: Filing without a model

    func testFilingBySiteAndByWords() {
        let video = FilingInput(title: "How to fold a paper crane", url: URL(string: "https://www.youtube.com/watch?v=1")!)
        XCTAssertEqual(BookmarkFiling.file(video).collection, "Videos")

        let shop = FilingInput(title: "Desk lamp", url: URL(string: "https://www.amazon.co.jp/dp/1")!)
        XCTAssertEqual(BookmarkFiling.file(shop).collection, "Shopping")

        let recipe = FilingInput(title: "Weeknight miso soup", url: URL(string: "https://blog.example/miso")!,
                                 text: "Ingredients: miso, tofu, dashi. Preheat nothing.")
        let filed = BookmarkFiling.file(recipe)
        XCTAssertEqual(filed.collection, "Recipes")
        XCTAssertTrue(filed.tags.contains("miso"))
        XCTAssertTrue(filed.tags.contains("blog"))

        let nothing = FilingInput(title: "Hello", url: URL(string: "https://tiny.example")!)
        XCTAssertEqual(BookmarkFiling.file(nothing).collection, BookmarkFiling.unsorted)
    }

    func testSummaryPrefersThePagesOwnDescription() {
        let input = FilingInput(title: "T", url: URL(string: "https://a.example")!,
                                description: "A  guide to\nkeeping bees in a small garden.",
                                text: "Unrelated first line that is certainly long enough to be used as a summary otherwise.")
        XCTAssertEqual(BookmarkFiling.file(input).summary, "A guide to keeping bees in a small garden.")
    }

    // MARK: Filing with a model

    func testParsesModelReply() {
        let reply = """
        **Collection:** recipes
        Tags: #Ramen, tokyo ; Ramen, "late night"
        Summary: A ramen shop in Tokyo known for its spicy mazesoba.
        """
        let parsed = BookmarkFilingText.parse(reply, known: ["Recipes", "Places"])
        XCTAssertEqual(parsed?.collection, "Recipes")
        XCTAssertEqual(parsed?.tags ?? [], ["ramen", "tokyo", "late night"])
        XCTAssertEqual(parsed?.summary, "A ramen shop in Tokyo known for its spicy mazesoba.")
    }

    func testModelMayInventAShortCollectionButNotAnEssay() {
        XCTAssertEqual(BookmarkFilingText.cleanCollection("board games", known: []), "Board Games")
        XCTAssertNil(BookmarkFilingText.cleanCollection("things that I might want to look at again", known: []))
        XCTAssertNil(BookmarkFilingText.parse("I cannot help with that.", known: []))
    }

    // MARK: Changes and dead links

    private func article(_ extra: String = "", clock: String = "10:42") -> String {
        let body = (1...120).map { "word\(["alpha", "beta", "gamma", "delta", "omega"][$0 % 5]) item\(Self.letters($0))" }
            .joined(separator: " ")
        return "<html><head><style>p{color:red}</style><script>var t=\(clock.count);</script></head>"
            + "<body><p>Updated \(clock) with 1234 views</p><p>\(body)</p>\(extra)</body></html>"
    }

    private static func letters(_ n: Int) -> String {
        String(String(n, radix: 26).map { Character(UnicodeScalar(UInt8(97 + Int(String($0), radix: 26)!))) })
    }

    func testSamePageWithADifferentClockIsNotAChange() {
        let a = PageSketch.sketch(ofHTML: article(clock: "10:42"))
        let b = PageSketch.sketch(ofHTML: article(clock: "23:59"))
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(PageSketch.similarity(a, b), 1, accuracy: 0.05)
    }

    func testRewrittenPageIsAChange() {
        let a = PageSketch.sketch(ofHTML: article())
        let other = (1...150).map { "fresh\(Self.letters($0)) text" }.joined(separator: " ")
        let b = PageSketch.sketch(ofHTML: "<html><body><p>\(other)</p></body></html>")
        XCTAssertLessThan(PageSketch.similarity(a, b), PageSketch.changedBelow)
    }

    func testTooLittleTextGivesNoFingerprint() {
        XCTAssertEqual(PageSketch.sketch(ofHTML: "<p>Please sign in</p>"), [])
    }

    func testChecksMarkChangedAndGone() {
        var library = BookmarkLibrary()
        let b = page("https://example.com/a", "A")
        library.add(b)
        let first = PageSketch.sketch(ofHTML: article())
        let other = PageSketch.sketch(ofWords: (1...150).map { "fresh" + Self.letters($0) })

        library.recordCheck(b.id, result: .found(first), now: t0)
        XCTAssertFalse(library.bookmark(b.id)!.hasChanged, "the first look is only a baseline")
        library.recordCheck(b.id, result: .found(first), now: t0)
        XCTAssertFalse(library.bookmark(b.id)!.hasChanged)
        library.recordCheck(b.id, result: .found(other), now: t0)
        XCTAssertTrue(library.bookmark(b.id)!.hasChanged)

        library.recordCheck(b.id, result: .unreachable, now: t0)
        library.recordCheck(b.id, result: .missing, now: t0)
        XCTAssertFalse(library.bookmark(b.id)!.isGone, "one miss is not enough")
        library.recordCheck(b.id, result: .missing, now: t0)
        XCTAssertTrue(library.bookmark(b.id)!.isGone)
        library.recordCheck(b.id, result: .found(other), now: t0)
        XCTAssertFalse(library.bookmark(b.id)!.isGone, "a page that comes back is no longer gone")
    }

    func testDueForCheckSkipsRowsAndRecentlyChecked() {
        var library = BookmarkLibrary()
        var recent = page("https://example.com/recent", "Recent")
        recent.checkedAt = t0.addingTimeInterval(-3600)
        var stale = page("https://example.com/stale", "Stale")
        stale.checkedAt = t0.addingTimeInterval(-3 * 86400)
        let never = page("https://example.com/never", "Never")
        let url = URL(string: "https://example.com/r")!
        let row = Bookmark(url: url, title: "Row", pages: [SavedPage(url: url, title: "R")], now: t0)
        [recent, stale, never, row].forEach { library.add($0) }
        XCTAssertEqual(library.dueForCheck(now: t0, every: 86400, limit: 5).map(\.title), ["Never", "Stale"])
    }

    // MARK: Colours

    func testColourWords() {
        let blue = (r: 0.1, g: 0.3, b: 0.9), white = (r: 1.0, g: 1.0, b: 1.0), black = (r: 0.02, g: 0.02, b: 0.02)
        XCTAssertEqual(ColorWords.words(forPixels: Array(repeating: white, count: 90) + Array(repeating: blue, count: 10)),
                       ["blue", "light"])
        XCTAssertEqual(ColorWords.words(forPixels: Array(repeating: black, count: 100)), ["dark"])
        XCTAssertEqual(ColorWords.words(forPixels: []), [])
    }

    // MARK: Highlight links

    func testTextFragment() {
        let url = URL(string: "https://example.com/post#top")!
        XCTAssertEqual(TextFragment.url(url, highlighting: "slow-cooked, rich broth").absoluteString,
                       "https://example.com/post#:~:text=slow%2Dcooked%2C%20rich%20broth")
        let long = "one two three four five six seven eight nine ten eleven twelve"
        XCTAssertEqual(TextFragment.url(url, highlighting: long).absoluteString,
                       "https://example.com/post#:~:text=one%20two%20three%20four%20five,eight%20nine%20ten%20eleven%20twelve")
        XCTAssertEqual(TextFragment.url(url, highlighting: "  \n ").absoluteString, url.absoluteString)
    }
}
