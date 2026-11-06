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

    func testFilterConfig() throws {
        var c = FilterConfig()
        XCTAssertEqual(c.active.map(\.id), Filters.defaults.map(\.id))
        c.setEnabled("adguard-popups", true)
        c.setEnabled("easylist", false)
        c.setEnabled("nonsense", true)                       // unknown ids are ignored
        XCTAssertEqual(c.active.map(\.id), ["easyprivacy", "adguard-mobile", "adguard-popups"])

        XCTAssertNil(c.addCustom(name: "x", urlText: "http://example.com/l.txt"))   // plain http refused
        XCTAssertNil(c.addCustom(name: "x", urlText: "not a url"))
        XCTAssertNil(c.addCustom(name: "x", urlText: Filters.defaults[0].url.absoluteString))   // duplicate
        let l = try XCTUnwrap(c.addCustom(name: "  ", urlText: " https://example.com/l.txt "))
        XCTAssertEqual(l.name, "example.com")                // blank name falls back to the host
        XCTAssertTrue(c.isEnabled(l.id) && c.isCustom(l.id))
        XCTAssertNil(c.addCustom(name: "again", urlText: "https://example.com/l.txt"))

        let back = try JSONDecoder().decode(FilterConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)                              // the id is stable, so the saved choice survives a relaunch
        XCTAssertEqual(back.custom.first?.id, l.id)
        c.removeCustom(l.id)
        XCTAssertFalse(c.isEnabled(l.id))
        XCTAssertTrue(c.custom.isEmpty)
        XCTAssertEqual(Set(Filters.builtIn.map(\.id)).count, Filters.builtIn.count)
    }

    func testPopupPolicy() {
        let page = URL(string: "https://video.example.com/watch")
        let ad = URL(string: "https://ads.evil.test/x")
        XCTAssertTrue(PopupPolicy.allows(linkTap: true, from: page, to: ad))             // a tapped link
        XCTAssertFalse(PopupPolicy.allows(linkTap: false, from: page, to: ad))           // a script popunder
        XCTAssertTrue(PopupPolicy.allows(linkTap: false, from: page, to: URL(string: "https://www.example.com/")))
        XCTAssertTrue(PopupPolicy.allows(linkTap: false, from: page, to: URL(string: "https://sso.video.example.com/")))
        XCTAssertFalse(PopupPolicy.allows(linkTap: false, from: page, to: URL(string: "https://notexample.com/")))
        XCTAssertFalse(PopupPolicy.allows(linkTap: false, from: page, to: nil))          // about:blank style popups
        XCTAssertFalse(PopupPolicy.allows(linkTap: false, from: nil, to: ad))
    }

    func testElementRule() {
        XCTAssertEqual(ElementRule.line(host: "www.Example.com", selector: "div#ad > p.promo:nth-of-type(2)"),
                       "example.com##div#ad > p.promo:nth-of-type(2)")
        XCTAssertEqual(ElementRule.line(host: "a.org", selector: ".x"), "a.org##.x")
        for bad in ["", "+js(abort-on-property-read, x)", "%x", "a\nb##c", "a,b", "a[href]", "a\\31", "ünï"] {
            XCTAssertNil(ElementRule.line(host: "a.org", selector: bad), bad)
        }
        XCTAssertNil(ElementRule.line(host: nil, selector: "div"))
        XCTAssertNil(ElementRule.line(host: "a.org", selector: String(repeating: "a", count: 401)))
    }
}
