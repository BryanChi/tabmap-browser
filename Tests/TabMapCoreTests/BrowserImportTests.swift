import XCTest
@testable import TabMapCore

final class BrowserImportTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: Chromium bookmarks

    func testChromiumBookmarksKeepFoldersButNotRoots() throws {
        let json = """
        {"roots":{
          "bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[
            {"type":"url","name":"Swift","url":"https://swift.org/","date_added":"13300000000000000"},
            {"type":"folder","name":"Recipes","children":[
              {"type":"folder","name":"Soups","children":[
                {"type":"url","name":"Pho","url":"https://example.com/pho"}]}]},
            {"type":"url","name":"Bookmarklet","url":"javascript:alert(1)"},
            {"type":"url","name":"Settings","url":"chrome://settings"}]},
          "other":{"type":"folder","name":"Other bookmarks","children":[
            {"type":"url","name":"News","url":"https://news.example.com"}]},
          "synced":{"type":"folder","name":"Mobile bookmarks","children":[]}
        },"version":1}
        """
        let list = try ChromiumBookmarks.parse(Data(json.utf8))
        XCTAssertEqual(list.map(\.title), ["Swift", "Pho", "News"])
        XCTAssertEqual(list[0].folders, [])
        XCTAssertEqual(list[0].collection, "")
        XCTAssertEqual(list[1].folders, ["Recipes", "Soups"])
        XCTAssertEqual(list[1].collection, "Recipes")
        XCTAssertEqual(list[1].tags, ["soups"])
        XCTAssertNotNil(list[0].addedAt)
        XCTAssertEqual(list[0].addedAt!.timeIntervalSince1970, 13_300_000_000 - 11_644_473_600, accuracy: 1)
    }

    func testChromiumBookmarksRejectsOtherJSON() {
        XCTAssertThrowsError(try ChromiumBookmarks.parse(Data("{\"a\":1}".utf8)))
    }

    func testChromiumTimeRoundTrips() {
        let micro = ChromiumTime.microseconds(now)
        XCTAssertEqual(ChromiumTime.date(micro)!.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(ChromiumTime.date(0))
    }

    // MARK: Safari bookmarks

    func testSafariBookmarksPlist() throws {
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList", "Title": "",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.com/",
                     "URIDictionary": ["title": "Apple"]],
                    ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Work", "Children": [
                        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://github.com/",
                         "URIDictionary": ["title": "GitHub"]],
                    ]],
                ]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://blog.example.com/post",
                     "URIDictionary": ["title": "A post"], "ReadingList": ["DateAdded": now]],
                ]],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let list = try SafariBookmarks.parse(data)
        XCTAssertEqual(list.map(\.title), ["Apple", "GitHub", "A post"])
        XCTAssertEqual(list.map(\.collection), ["", "Work", "Reading List"])
        XCTAssertEqual(list[2].addedAt, now)
    }

    // MARK: Bookmark HTML

    func testNetscapeBookmarkFile() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Favorites</H3>
            <DL><p>
                <DT><A HREF="https://swift.org/" ADD_DATE="1700000000">Swift &amp; more</A>
                <DT><H3>Travel</H3>
                <DL><p>
                    <DT><A HREF="https://maps.example.com/?a=1&amp;b=2">Maps &#8212; <b>world</b></A>
                    <DT><H3>Japan</H3>
                    <DL><p>
                        <DT><A href='https://jp.example.com'>Tokyo</A>
                    </DL><p>
                </DL><p>
                <DT><A HREF="place:sort=8">Firefox query</A>
            </DL><p>
            <DT><A HREF="https://top.example.com">Top</A>
        </DL><p>
        """
        let list = NetscapeBookmarks.parse(html)
        XCTAssertEqual(list.map(\.title), ["Swift & more", "Maps — world", "Tokyo", "Top"])
        XCTAssertEqual(list[0].folders, [])
        XCTAssertEqual(list[0].addedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(list[1].url.absoluteString, "https://maps.example.com/?a=1&b=2")
        XCTAssertEqual(list[1].folders, ["Travel"])
        XCTAssertEqual(list[2].folders, ["Travel", "Japan"])
        XCTAssertEqual(list[2].tags, ["japan"])
        XCTAssertEqual(list[3].folders, [])
    }

    func testUniqueBookmarksKeepsFirst() {
        let a = ImportedBookmark(url: url("https://a.com"), title: "A", folders: ["One"])
        let b = ImportedBookmark(url: url("https://a.com"), title: "A again", folders: ["Two"])
        XCTAssertEqual(BrowserImport.uniqueBookmarks([a, b]), [a])
    }

    // MARK: Safari history export

    func testSafariHistoryExport() throws {
        let json = """
        {"metadata":{"browser_name":"Safari","data_type":"history"},
         "history":[
          {"url":"https://a.com/","title":"A","time_usec":1700000000000000,"visit_count":5},
          {"url":"https://b.com/x","title":"B","time_usec":1700000100000000},
          {"url":"https://b.com/x","title":"B newer","time_usec":1700000200000000},
          {"url":"file:///Users/me/x.html","title":"local","time_usec":1700000000000000}
         ]}
        """
        let visits = try SafariHistoryExport.parse(Data(json.utf8))
        XCTAssertEqual(visits.count, 2)
        XCTAssertEqual(visits[0].visitCount, 5)
        XCTAssertEqual(visits[0].lastVisit, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(visits[1].visitCount, 2)
        XCTAssertEqual(visits[1].title, "B newer")
    }

    // MARK: Passwords

    func testChromePasswordCSV() {
        let csv = "name,url,username,password,note\r\n"
            + "github.com,https://github.com/login,me@example.com,\"p,ss\"\"word\",\"two\nlines\"\r\n"
            + "app,android://abc@com.example/,me,secret,\r\n"
            + "nopass,https://x.com,me,,\r\n"
        let result = PasswordCSV.parse(csv)
        XCTAssertEqual(result.logins.count, 1)
        XCTAssertEqual(result.skipped, 2)
        let login = result.logins[0]
        XCTAssertEqual(login.host, "github.com")
        XCTAssertEqual(login.username, "me@example.com")
        XCTAssertEqual(login.password, "p,ss\"word")
        XCTAssertEqual(login.note, "two\nlines")
        XCTAssertEqual(login.title, "github.com")
    }

    func testSafariPasswordCSVWithByteOrderMarkAndBareHost() {
        let csv = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\n"
            + "Example,example.com,bob,hunter2,,\n"
            + "Wi-Fi,,home,router,,\n"
        let result = PasswordCSV.parse(csv)
        XCTAssertEqual(result.logins.map(\.url.absoluteString), ["https://example.com"])
        XCTAssertEqual(result.logins.first?.title, "Example")
        XCTAssertEqual(result.skipped, 1)
    }

    func testCSVWithoutPasswordColumnReadsNothing() {
        XCTAssertEqual(PasswordCSV.parse("a,b\n1,2\n").logins, [])
    }

    func testCSVRows() {
        XCTAssertEqual(CSV.rows("a,\"b\"\"c\",d\n\"x\ny\",,z"), [["a", "b\"c", "d"], ["x\ny", "", "z"]])
        XCTAssertEqual(CSV.rows("a,b\r\nc,d\r\n"), [["a", "b"], ["c", "d"]])
    }

    // MARK: Address completion

    func visit(_ s: String, _ n: Int, typed: Int = 0, daysAgo: Double = 0) -> ImportedVisit {
        ImportedVisit(url: url(s), title: s, visitCount: n, typedCount: typed, lastVisit: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func testCompletesSitesFromHistory() {
        var index = VisitIndex()
        index.merge([
            visit("https://www.github.com/apple/swift", 10),
            visit("https://github.com/", 5),
            visit("https://gitlab.com/", 3),
            visit("https://news.ycombinator.com/item?id=1", 2),
        ], now: now)
        XCTAssertEqual(index.completion(for: "git", now: now), "github.com")
        XCTAssertEqual(index.completion(for: "gitl", now: now), "gitlab.com")
        XCTAssertEqual(index.completion(for: "GitH", now: now), "GitHub.com")
        XCTAssertEqual(index.completion(for: "www.git", now: now), "www.github.com")
        XCTAssertEqual(index.completion(for: "https://git", now: now), "https://github.com")
        XCTAssertEqual(index.completion(for: "github.com/a", now: now), "github.com/apple/swift")
        XCTAssertNil(index.completion(for: "github.com", now: now))
        XCTAssertNil(index.completion(for: "git hub", now: now))
        XCTAssertNil(index.completion(for: "zzz", now: now))
    }

    func testSingleLetterNeedsAWellUsedSite() {
        var index = VisitIndex()
        index.merge([visit("https://rarely.com", 1), visit("https://often.com", 20)], now: now)
        XCTAssertNil(index.completion(for: "r", now: now))
        XCTAssertEqual(index.completion(for: "o", now: now), "often.com")
    }

    func testRecentAndTypedOutweighOldVisits() {
        var index = VisitIndex()
        index.merge([visit("https://mail.old.com", 20, daysAgo: 200), visit("https://mail.new.com", 3, daysAgo: 1)], now: now)
        XCTAssertEqual(index.completion(for: "mail.", now: now), "mail.new.com")
        index.markTyped(url("https://mail.typed.com"), now: now)
        index.markTyped(url("https://mail.typed.com"), now: now)
        XCTAssertEqual(index.completion(for: "mail.", now: now), "mail.typed.com")
    }

    func testImportingTwiceDoesNotDoubleCounts() {
        var index = VisitIndex()
        let visits = [visit("https://a.com/x", 4)]
        XCTAssertEqual(index.merge(visits, now: now), 1)
        XCTAssertEqual(index.merge(visits, now: now), 0)
        XCTAssertEqual(index.entries[VisitIndex.key(url("http://www.a.com/x/#top"))!]?.visits, 4)
        index.record(url("https://a.com/x"), title: "X", now: now)
        XCTAssertEqual(index.entries["a.com/x"]?.visits, 5)
        XCTAssertEqual(index.entries["a.com/x"]?.title, "X")
    }

    func testKeysIgnoreSchemeWWWAndFragment() {
        XCTAssertEqual(VisitIndex.key(url("https://www.Example.com:443/a/?q=1#x")), "example.com/a?q=1")
        XCTAssertEqual(VisitIndex.key(url("http://localhost:3000/")), "localhost:3000")
        XCTAssertNil(VisitIndex.key(url("about:blank")))
    }
}
