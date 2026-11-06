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
        a.remove("example.com")
        XCTAssertFalse(a.contains("example.com"))
    }

    func testToggleOnlyAffectsTheCurrentHost() {
        var a = AllowList(hosts: ["example.com"])
        a.toggle("video.example.com")              // shield on a subdomain of an allowed site
        XCTAssertFalse(a.contains("video.example.com"))
        XCTAssertTrue(a.contains("example.com"))
        XCTAssertTrue(a.contains("shop.example.com"))
        XCTAssertFalse(a.contains("a.video.example.com"))   // exception covers its own subdomains
        XCTAssertEqual(a.hosts, ["example.com"])
        a.toggle("video.example.com")              // back: no redundant entry left behind
        XCTAssertTrue(a.contains("video.example.com"))
        XCTAssertEqual(a, AllowList(hosts: ["example.com"]))
    }

    func testToggleParentKeepsMoreSpecificChoices() {
        var a = AllowList(hosts: ["example.com"])
        a.toggle("video.example.com")              // blocked exception
        a.toggle("example.com")                    // block the parent too
        XCTAssertFalse(a.contains("example.com"))
        XCTAssertFalse(a.contains("shop.example.com"))
        a.toggle("shop.example.com")               // allow one child under a blocked parent
        XCTAssertTrue(a.contains("shop.example.com"))
        XCTAssertFalse(a.contains("example.com"))
        XCTAssertFalse(a.contains("video.example.com"))
        a.toggle("www.example.com")                // www is the same site as example.com
        XCTAssertTrue(a.contains("example.com"))
        XCTAssertFalse(a.contains("video.example.com"))
    }

    func testRemoveDropsOrphanedExceptionsAndAddClearsThem() {
        var a = AllowList(hosts: ["example.com"])
        a.toggle("video.example.com")
        a.remove("example.com")
        a.add("example.com")                       // must not resurrect the old exception
        XCTAssertTrue(a.contains("video.example.com"))
        a.toggle("video.example.com")
        a.add("video.example.com")                 // Settings "Add" on an excepted host allows it
        XCTAssertTrue(a.contains("video.example.com"))
    }

    func testAllowListDecodesOldFormat() throws {
        let old = Data(#"{"hosts":["a.com"]}"#.utf8)
        let a = try JSONDecoder().decode(AllowList.self, from: old)
        XCTAssertEqual(a.hosts, ["a.com"])
        var b = a
        b.toggle("x.a.com")
        let back = try JSONDecoder().decode(AllowList.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
        XCTAssertFalse(back.contains("x.a.com"))
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
