import XCTest
@testable import NullViewCore

final class AddressInputTests: XCTestCase {
    private func r(_ s: String) -> String? { AddressInput.resolve(s)?.absoluteString }

    func testUrls() {
        XCTAssertEqual(r("https://example.com/a?b=1"), "https://example.com/a?b=1")
        XCTAssertEqual(r("  example.com  "), "https://example.com")
        XCTAssertEqual(r("example.com/path"), "https://example.com/path")
        XCTAssertEqual(r("http://example.com"), "http://example.com")
        XCTAssertEqual(r("localhost:3000"), "https://localhost:3000")
        XCTAssertEqual(r("192.168.0.1:8080/x"), "https://192.168.0.1:8080/x")
        XCTAssertEqual(r("[::1]:8080"), "https://[::1]:8080")
    }

    func testSearch() {
        let ddg = "https://duckduckgo.com/?q="
        XCTAssertEqual(r("cats"), ddg + "cats")
        XCTAssertEqual(r("funny cats & dogs"), ddg + "funny%20cats%20%26%20dogs")
        XCTAssertEqual(r("3.14"), ddg + "3.14")
        XCTAssertEqual(r("999.1.1.1"), ddg + "999.1.1.1")
        XCTAssertEqual(r("example.com is down"), ddg + "example.com%20is%20down")
    }

    func testSchemesNeverLoadDirectly() {
        for s in ["javascript:alert(1)", "javascript:alert(document.domain)", "data:text/html,hi",
                  "file:///etc/passwd", "ftp://example.com", "about:blank", "mailto:a@b.com"] {
            let u = AddressInput.resolve(s)
            XCTAssertEqual(u?.host, "duckduckgo.com", s)
        }
    }

    func testEmptyAndBadTemplate() {
        XCTAssertNil(r(""))
        XCTAssertNil(r("   "))
        XCTAssertNil(AddressInput.resolve("cats", searchTemplate: "no placeholder"))
        XCTAssertNil(AddressInput.resolve("cats", searchTemplate: "javascript:%s"))
        XCTAssertEqual(AddressInput.resolve("a b", searchTemplate: "https://x.org/s?q=%s")?.absoluteString,
                       "https://x.org/s?q=a%20b")
        XCTAssertTrue(AddressInput.isValidSearchTemplate(AddressInput.defaultSearchTemplate))
    }

    func testDeepLink() {
        func p(_ s: String) -> String? { DeepLink.parse(URL(string: s)!)?.absoluteString }
        XCTAssertEqual(p("nullview://open?url=https://example.com/v?id=1"), "https://example.com/v?id=1")
        XCTAssertEqual(p("nullview://open?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1%26c%3D2"),
                       "https://example.com/a?b=1&c=2")
        XCTAssertEqual(p("NullView://open?url=http://example.com"), "http://example.com")
        XCTAssertNil(p("nullview://open?url=javascript:alert(1)"))
        XCTAssertNil(p("nullview://open?url=file:///etc/passwd"))
        XCTAssertNil(p("nullview://open"))
        XCTAssertNil(p("nullview://other?url=https://example.com"))
        XCTAssertNil(p("https://example.com/?url=https://example.com"))
    }
}
