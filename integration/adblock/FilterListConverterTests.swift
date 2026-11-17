import XCTest
@testable import TabMapCore

final class FilterListConverterTests: XCTestCase {
    func one(_ line: String) -> ConvertedFilters { FilterListConverter.convert(line) }

    /// Matches a WebKit url-filter against an address the way WebKit does (case-insensitive by default).
    func matches(_ filter: String, _ url: String) -> Bool {
        url.range(of: filter, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func testHostAnchorMatchesHostAndSubdomainsOnly() {
        let r = one("||ads.example.com^").blocks
        XCTAssertEqual(r.count, 1)
        let f = r[0].trigger.urlFilter
        XCTAssertTrue(matches(f, "https://ads.example.com/banner.js"))
        XCTAssertTrue(matches(f, "http://cdn.ads.example.com/x"))
        XCTAssertTrue(matches(f, "https://ads.example.com:8080/x"))
        XCTAssertFalse(matches(f, "https://notads.example.com/x"))
        XCTAssertFalse(matches(f, "https://ads.example.com.evil.org/x"))
        XCTAssertFalse(matches(f, "https://site.org/?u=ads.example.com"))
        XCTAssertEqual(r[0].action.type, "block")
        XCTAssertEqual(r[0].trigger.resourceType, FilterListConverter.allTypes)
    }

    func testSeparatorAtEndAllowsEndOfAddress() {
        let f = one("||example.com/ad.js^").blocks[0].trigger.urlFilter
        XCTAssertTrue(matches(f, "https://example.com/ad.js"))
        XCTAssertTrue(matches(f, "https://example.com/ad.js?v=2"))
        XCTAssertFalse(matches(f, "https://example.com/ad.jsx"))
    }

    func testWildcardsAndAnchors() {
        let f = one("/banner/*/img").blocks[0].trigger.urlFilter
        XCTAssertTrue(matches(f, "https://x.com/banner/123/img.png"))
        XCTAssertFalse(matches(f, "https://x.com/banner/img"))
        let start = one("|https://track.").blocks[0].trigger.urlFilter
        XCTAssertTrue(matches(start, "https://track.site.com/"))
        XCTAssertFalse(matches(start, "https://a.com/?r=https://track.x"))
        let end = one(".gif|").blocks[0].trigger.urlFilter
        XCTAssertTrue(matches(end, "https://a.com/p.gif"))
        XCTAssertFalse(matches(end, "https://a.com/p.gif?x=1"))
    }

    func testRegexCharactersAreEscaped() {
        let f = one("/ads.php?id=").blocks[0].trigger.urlFilter
        XCTAssertTrue(matches(f, "https://a.com/ads.php?id=3"))
        XCTAssertFalse(matches(f, "https://a.com/adsXphp?id=3"))
    }

    func testOptions() {
        let r = one("||tracker.net^$script,third-party,domain=news.com|~sport.news.com").blocks[0].trigger
        XCTAssertEqual(r.resourceType, ["script"])
        XCTAssertEqual(r.loadType, ["third-party"])
        XCTAssertEqual(r.ifDomain, ["*news.com"])
        XCTAssertNil(r.unlessDomain)

        let only = one("||x.com^$domain=~a.com|~b.com").blocks[0].trigger
        XCTAssertEqual(only.unlessDomain, ["*a.com", "*b.com"])

        let negated = one("||x.com^$~script,~image").blocks[0].trigger
        XCTAssertFalse(negated.resourceType!.contains("script"))
        XCTAssertFalse(negated.resourceType!.contains("image"))
        XCTAssertTrue(negated.resourceType!.contains("raw"))

        XCTAssertEqual(one("||x.com^$xmlhttprequest").blocks[0].trigger.resourceType, ["raw"])
        XCTAssertEqual(one("||x.com^$subdocument").blocks[0].trigger.resourceType, ["document"])
        XCTAssertEqual(one("||x.com^$~third-party").blocks[0].trigger.loadType, ["first-party"])
        XCTAssertEqual(one("||x.com/Ad^$match-case").blocks[0].trigger.urlFilterIsCaseSensitive, true)
        XCTAssertEqual(one("||x.com^$popup").blocks[0].trigger.resourceType, ["popup"])
    }

    func testUnsupportedFiltersAreSkipped() {
        for line in ["||x.com^$redirect=noop.js", "||x.com^$csp=script-src 'none'", "/ads[0-9]+/",
                     "||x.com^$removeparam=utm", "example.com#$#abort-on-property-read x",
                     "example.com##+js(nobab)", "example.com#?#div:-abp-has(.ad)", "##.ad:has-text(Sponsored)",
                     "$script,third-party", "||x.com^$document", "||ünicode.com^"] {
            let c = one(line)
            XCTAssertEqual(c.ruleCount, 0, line)
            XCTAssertEqual(c.skipped, 1, line)
        }
    }

    func testCommentsAndHeadersAreIgnored() {
        let c = FilterListConverter.convert("[Adblock Plus 2.0]\n! Title: EasyList\n\n||ads.com^\n")
        XCTAssertEqual(c.blocks.count, 1)
        XCTAssertEqual(c.skipped, 0)
    }

    func testDomainOptionAloneAllowsCatchAll() {
        let r = one("$script,domain=bad.com").blocks
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].trigger.urlFilter, ".*")
        XCTAssertEqual(r[0].trigger.ifDomain, ["*bad.com"])
    }

    func testExceptions() {
        let c = FilterListConverter.convert("||ads.com^\n@@||ads.com/ok.js^$script")
        XCTAssertEqual(c.exceptions.count, 1)
        XCTAssertEqual(c.exceptions[0].action.type, "ignore-previous-rules")
        XCTAssertEqual(c.exceptions[0].trigger.resourceType, ["script"])

        let page = one("@@||bank.com^$document")
        XCTAssertEqual(page.pageExceptions.count, 1)
        XCTAssertEqual(page.pageExceptions[0].trigger.ifDomain, ["*bank.com"])
        XCTAssertEqual(page.pageExceptions[0].trigger.urlFilter, ".*")
    }

    func testElementHiding() {
        let c = FilterListConverter.convert("""
        ##.ad-banner
        ###sponsored
        news.com,~sport.news.com##.promo
        ##.sidebar-ad
        quiet.com#@#.sidebar-ad
        """)
        // Generic selectors nobody excepts share one rule.
        let generic = c.hides.first { $0.trigger.ifDomain == nil && $0.trigger.unlessDomain == nil }
        XCTAssertEqual(generic?.action.selector, ".ad-banner, #sponsored")
        XCTAssertEqual(generic?.action.type, "css-display-none")
        // An excepted generic selector gets its own rule that skips that site.
        let excepted = c.hides.first { $0.action.selector == ".sidebar-ad" }
        XCTAssertEqual(excepted?.trigger.unlessDomain, ["*quiet.com"])
        // Site-specific hiding applies on its sites (exclusions dropped: WebKit can't combine them).
        let site = c.hides.first { $0.action.selector == ".promo" }
        XCTAssertEqual(site?.trigger.ifDomain, ["*news.com"])
        XCTAssertEqual(c.hides.count, 3)
    }

    func testGenericSelectorsAreBatched() {
        let lines = (0..<1000).map { "##.ad\($0)" }.joined(separator: "\n")
        let c = FilterListConverter.convert(lines)
        XCTAssertEqual(c.hides.count, 3) // 400 + 400 + 200
        XCTAssertEqual(c.hides.map { $0.action.selector!.components(separatedBy: ", ").count }.reduce(0, +), 1000)
    }

    func testNetworkFilterWithHashIsNotCosmetic() {
        let c = one("||x.com/page#ad^")
        XCTAssertEqual(c.blocks.count, 1)
        XCTAssertEqual(c.hides.count, 0)
    }

    func testChunksKeepExceptionsWithBlocksAndRespectLimit() {
        var text = (0..<250).map { "||ad\($0).com^" }
        text.append("@@||ad1.com/ok^")
        text.append("@@||bank.com^$document")
        text.append("##.ad")
        let c = FilterListConverter.convert(text.joined(separator: "\n"))
        let chunks = c.chunks(maxRules: 102)
        // 250 blocks at 100 per chunk = 3 request chunks, then 1 hiding chunk.
        XCTAssertEqual(chunks.count, 4)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 102) }
        for chunk in chunks.prefix(3) {
            XCTAssertEqual(chunk.suffix(2).map(\.action.type), ["ignore-previous-rules", "ignore-previous-rules"])
        }
        XCTAssertEqual(chunks[3].first?.action.type, "css-display-none")
        XCTAssertEqual(chunks[3].last?.trigger.ifDomain, ["*bank.com"])
    }

    func testEncodesWebKitFieldNames() {
        let json = ConvertedFilters.encode(one("||x.com^$script,third-party,domain=a.com").blocks)
        XCTAssertTrue(json.contains("\"url-filter\""))
        XCTAssertTrue(json.contains("\"resource-type\":[\"script\"]"))
        XCTAssertTrue(json.contains("\"load-type\":[\"third-party\"]"))
        XCTAssertTrue(json.contains("\"if-domain\":[\"*a.com\"]"))
        XCTAssertFalse(json.contains("null"))
    }

    // MARK: Allowlist

    func testAllowlistCoversSubdomainsAndIgnoresWww() {
        var list = BlockingAllowlist(["www.News.com"])
        XCTAssertEqual(list.sites, ["news.com"])
        XCTAssertTrue(list.allows(host: "news.com"))
        XCTAssertTrue(list.allows(host: "www.news.com"))
        XCTAssertTrue(list.allows(host: "video.news.com"))
        XCTAssertFalse(list.allows(host: "fakenews.com"))
        XCTAssertFalse(list.allows(host: nil))

        // Turning blocking back on from a subdomain clears the parent entry too.
        list.set(host: "video.news.com", allowed: false)
        XCTAssertFalse(list.allows(host: "news.com"))
        list.set(host: "shop.com", allowed: true)
        XCTAssertTrue(list.allows(host: "shop.com"))
    }
}
