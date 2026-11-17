import XCTest
@testable import TabMapCore

// Goes in Tests/TabMapCoreTests.
final class ProfilesTests: XCTestCase {
    func testFreshBookHasPersonalDefaultAndWork() {
        let book = ProfileBook()
        XCTAssertEqual(book.profiles.map(\.name), ["Personal", "Work"])
        XCTAssertTrue(book.defaultProfile.isDefault)
        XCTAssertEqual(book.defaultProfile.name, "Personal")
        XCTAssertEqual(book.defaultProfile.relativeDataPath, "")
        let work = book.profiles[1]
        XCTAssertEqual(work.relativeDataPath, "Profiles/\(work.id.uuidString)")
        XCTAssertNotEqual(work.color, book.defaultProfile.color)
    }

    func testAddingPicksUniqueNameAndUnusedColor() {
        var book = ProfileBook()
        let a = book.add(named: "  work ")
        XCTAssertEqual(a.name, "work 2")
        let b = book.add()
        XCTAssertEqual(b.name, "Profile")
        let c = book.add(named: "")
        XCTAssertEqual(c.name, "Profile 2")
        XCTAssertEqual(Set(book.profiles.map(\.color)).count, book.profiles.count)
    }

    func testRenameIgnoresBlankAndAvoidsClashes() {
        var book = ProfileBook()
        let work = book.profiles[1]
        book.rename(work.id, to: "   ")
        XCTAssertEqual(book.profile(work.id)?.name, "Work")
        book.rename(work.id, to: "personal")
        XCTAssertEqual(book.profile(work.id)?.name, "personal 2")
        book.rename(work.id, to: "Acme")
        XCTAssertEqual(book.profile(work.id)?.name, "Acme")
    }

    func testDefaultAndLastProfileCannotBeRemoved() {
        var book = ProfileBook()
        let personal = book.defaultProfile
        let work = book.profiles[1]
        XCTAssertFalse(book.canRemove(personal.id))
        XCTAssertNil(book.remove(personal.id))
        XCTAssertEqual(book.remove(work.id)?.id, work.id)
        XCTAssertEqual(book.profiles.count, 1)
        XCTAssertNil(book.remove(UUID()))
    }

    func testShortcutsFollowListOrder() {
        var book = ProfileBook()
        let work = book.profiles[1]
        XCTAssertEqual(book.profile(atShortcut: 2)?.id, work.id)
        XCTAssertNil(book.profile(atShortcut: 3))
        XCTAssertNil(book.profile(atShortcut: 0))
        book.move(work.id, by: -1)
        XCTAssertEqual(book.profile(atShortcut: 1)?.id, work.id)
        book.move(work.id, by: -3)
        XCTAssertEqual(book.profiles.first?.id, work.id)
    }

    func testLaunchArgumentsRoundTrip() {
        let book = ProfileBook()
        let work = book.profiles[1]
        let args = ["/Applications/Tabmap.app/Contents/MacOS/Tabmap"] + ProfileLaunch.arguments(for: work)
        XCTAssertEqual(ProfileLaunch.resolve(arguments: args, in: book).id, work.id)
        XCTAssertEqual(ProfileLaunch.arguments(for: book.defaultProfile), [])
        XCTAssertTrue(ProfileLaunch.resolve(arguments: ["Tabmap"], in: book).isDefault)
        XCTAssertTrue(ProfileLaunch.resolve(arguments: ["Tabmap", "--profile"], in: book).isDefault)
        XCTAssertTrue(ProfileLaunch.resolve(arguments: ["Tabmap", "--profile", UUID().uuidString], in: book).isDefault)
        XCTAssertTrue(ProfileLaunch.resolve(arguments: ["Tabmap", "--profile", "nonsense"], in: book).isDefault)
    }

    func testDecodingRepairsBadLists() throws {
        let id = UUID()
        let json = """
        {"profiles":[
          {"id":"\(id.uuidString)","name":" ","color":-3,"isDefault":false},
          {"id":"\(id.uuidString)","name":"Dup","color":1,"isDefault":true},
          {"id":"\(UUID().uuidString)","name":"B","color":99,"isDefault":true}
        ]}
        """
        let book = try JSONDecoder().decode(ProfileBook.self, from: Data(json.utf8))
        XCTAssertEqual(book.profiles.count, 2)
        XCTAssertEqual(book.profiles.filter(\.isDefault).count, 1)
        XCTAssertEqual(book.defaultProfile.id, book.profiles[1].id)
        XCTAssertEqual(book.profiles[0].name, "Profile")
        XCTAssertTrue(book.profiles.allSatisfy { (0..<Profile.colorNames.count).contains($0.color) })

        let empty = try JSONDecoder().decode(ProfileBook.self, from: Data(#"{"profiles":[]}"#.utf8))
        XCTAssertEqual(empty.profiles.map(\.name), ["Personal", "Work"])
    }

    func testRoundTripThroughJSON() throws {
        var book = ProfileBook()
        book.add(named: "School")
        let data = try JSONEncoder().encode(book)
        XCTAssertEqual(try JSONDecoder().decode(ProfileBook.self, from: data), book)
    }

    func testInitials() {
        XCTAssertEqual(Profile(name: "Work", color: 0).initials, "W")
        XCTAssertEqual(Profile(name: "side project", color: 0).initials, "SP")
        XCTAssertEqual(Profile(name: "a b c", color: 0).initials, "AB")
    }
}
