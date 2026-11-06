import XCTest
@testable import NullViewCore

final class BlockingTests: XCTestCase {
    func testAllowListMatching() {
        var a = AllowList()
        a.add("WWW.Example.com")
        a.add("example.com")           // duplicate after normalizing
        a.add("")
        a.add("a b")
        XCTAssertEqual(a.hosts, ["example.com"])
        XCTAssertTrue(a.contains("example.com"))
        XCTAssertTrue(a.contains("www.example.com"))
        XCTAssertTrue(a.contains("video.Example.com"))
        XCTAssertFalse(a.contains("evilexample.com"))
        XCTAssertFalse(a.contains("example.com.evil.org"))
        XCTAssertFalse(a.contains(nil))
        a.add("sub.other.org")
        XCTAssertFalse(a.contains("other.org"))
        XCTAssertTrue(a.contains("x.sub.other.org"))
        XCTAssertEqual(a.entry(covering: "video.example.com"), "example.com")
        a.remove("example.com")
        XCTAssertFalse(a.contains("example.com"))
    }

    func testAllowListCodable() throws {
        let a = AllowList(hosts: ["b.com", "a.com"])
        let back = try JSONDecoder().decode(AllowList.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        XCTAssertEqual(back.hosts, ["a.com", "b.com"])
    }

    func testStaleness() {
        let now = Date()
        XCTAssertTrue(Filters.isStale(nil, now: now))
        XCTAssertFalse(Filters.isStale(now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(Filters.isStale(now.addingTimeInterval(-25 * 3600), now: now))
    }

    func testCustomLines() {
        XCTAssertEqual(Filters.lines("  ||ads.example^ \n\n! comment\r\nexample.com##.x\n"),
                       ["||ads.example^", "! comment", "example.com##.x"])
        XCTAssertEqual(Set(Filters.defaults.map(\.id)).count, 3)
    }
}
