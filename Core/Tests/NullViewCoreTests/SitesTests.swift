import XCTest
@testable import NullViewCore

final class SitesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAddNormalisesAndRejects() {
        let s = Sites(store: MemorySiteStore())
        XCTAssertEqual(s.add("youtube.com")?.url, "https://youtube.com")
        XCTAssertEqual(s.add("youtube.com")?.name, nil, "duplicate")
        XCTAssertEqual(s.add("https://www.reddit.com", name: "  ")?.name, "reddit.com")
        XCTAssertEqual(s.add("https://x.org", name: " X ")?.name, "X")
        XCTAssertNil(s.add("cute cats"), "a search is not a site")
        XCTAssertNil(s.add("javascript:alert(1)"))
        XCTAssertNil(s.add(""))
        XCTAssertEqual(s.ordered().count, 3)
    }

    func testMostOpenedFirstThenRecentThenName() {
        let s = Sites(store: MemorySiteStore())
        let a = s.add("a.com")!, b = s.add("b.com")!, c = s.add("c.com")!
        XCTAssertEqual(s.ordered().map(\.name), ["a.com", "b.com", "c.com"])
        s.recordOpen(c, now: t0)
        XCTAssertEqual(s.ordered().first?.name, "c.com")
        s.recordOpen(b, now: t0.addingTimeInterval(5))
        XCTAssertEqual(s.ordered().map(\.name), ["b.com", "c.com", "a.com"], "same count: latest open wins")
        s.recordOpen(a, now: t0); s.recordOpen(a, now: t0)
        XCTAssertEqual(s.ordered().first?.name, "a.com")
        XCTAssertEqual(s.ordered().first?.opens, 2)
    }

    func testRemove() {
        let s = Sites(store: MemorySiteStore())
        let a = s.add("a.com")!
        XCTAssertEqual(s.ordered().first?.name, "a.com")
        s.remove(a)
        XCTAssertTrue(s.ordered().isEmpty)
    }
}
