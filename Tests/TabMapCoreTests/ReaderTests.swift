import XCTest
@testable import TabMapCore

final class ReaderTests: XCTestCase {
    let page = URL(string: "https://www.example.com/news/story")!

    func reply(words: Int, title: String? = "A Story", content: String = "<p>Hi</p>") -> [String: Any] {
        var r: [String: Any] = ["words": NSNumber(value: words), "content": content]
        if let title { r["title"] = title }
        return r
    }

    // MARK: Article from the extractor

    func testShortPagesHaveNoArticle() {
        XCTAssertNil(ReaderArticle(reply: reply(words: ReaderArticle.minimumWords - 1), url: page))
        XCTAssertNil(ReaderArticle(reply: ["words": NSNumber(value: 900)], url: page), "no content")
        XCTAssertNotNil(ReaderArticle(reply: reply(words: ReaderArticle.minimumWords), url: page))
    }

    func testMetadataIsTrimmedAndBlankFieldsDropped() {
        var r = reply(words: 500, title: "  Big Story \n")
        r["byline"] = "   "
        r["siteName"] = " Example News "
        let article = ReaderArticle(reply: r, url: page)!
        XCTAssertEqual(article.title, "Big Story")
        XCTAssertNil(article.byline)
        XCTAssertEqual(article.siteName, "Example News")
        XCTAssertEqual(article.url, page)
    }

    func testMissingTitleFallsBackToHost() {
        let article = ReaderArticle(reply: reply(words: 500, title: nil), url: page)!
        XCTAssertEqual(article.title, "www.example.com")
    }

    func testReadingTime() {
        func minutes(_ words: Int) -> Int { ReaderArticle(title: "t", contentHTML: "", wordCount: words).readingMinutes }
        XCTAssertEqual(minutes(10), 1)
        XCTAssertEqual(minutes(230), 1)
        XCTAssertEqual(minutes(1150), 5)
        XCTAssertEqual(minutes(2400), 10)
    }

    // MARK: Style

    func testTextSizeStaysInRange() {
        var style = ReaderStyle()
        XCTAssertEqual(style.fontSize, 18)
        for _ in 0..<20 { style.grow() }
        XCTAssertEqual(style.fontSize, ReaderStyle.sizes.last)
        XCTAssertFalse(style.canGrow)
        for _ in 0..<20 { style.shrink() }
        XCTAssertEqual(style.fontSize, ReaderStyle.sizes.first)
        XCTAssertFalse(style.canShrink)
        XCTAssertEqual(ReaderStyle(sizeStep: 99).sizeStep, ReaderStyle.sizes.count - 1)
        XCTAssertEqual(ReaderStyle(sizeStep: -3).sizeStep, 0)
    }

    // MARK: Document

    func testDocumentEscapesTitleAndBylineButKeepsContent() {
        let article = ReaderArticle(title: "<script>x</script> & \"quotes\"", byline: "<b>Eve</b>",
                                    contentHTML: "<p>Body <em>text</em></p>", url: page, wordCount: 460)
        let html = ReaderDocument.html(for: article, style: ReaderStyle())
        XCTAssertFalse(html.contains("<script>x"))
        XCTAssertTrue(html.contains("&lt;script&gt;x&lt;/script&gt; &amp; &quot;quotes&quot;"))
        XCTAssertTrue(html.contains("&lt;b&gt;Eve&lt;/b&gt;"))
        XCTAssertTrue(html.contains("<p>Body <em>text</em></p>"))
        XCTAssertTrue(html.contains("example.com · &lt;b&gt;Eve&lt;/b&gt; · 2 min read"), "site without www, byline, time")
    }

    func testDocumentLocksDownWhatTheReaderCanLoad() {
        let html = ReaderDocument.html(for: ReaderArticle(title: "t", contentHTML: "", wordCount: 300), style: ReaderStyle())
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(ReaderDocument.contentSecurityPolicy.contains("default-src 'none'"))
        XCTAssertFalse(ReaderDocument.contentSecurityPolicy.contains("script-src"))
    }

    func testDocumentCarriesStyle() {
        let article = ReaderArticle(title: "t", contentHTML: "", wordCount: 300)
        let html = ReaderDocument.html(for: article, style: ReaderStyle(theme: .sepia, font: .sans, sizeStep: 4))
        XCTAssertTrue(html.contains("class=\"theme-sepia\""))
        XCTAssertTrue(html.contains("font-size:22px"))
        XCTAssertTrue(html.contains("-apple-system, \"SF Pro Text\""))
        let auto = ReaderDocument.styleSheet(ReaderStyle(theme: .auto))
        XCTAssertTrue(auto.contains("prefers-color-scheme: dark"), "auto follows the system")
    }
}
