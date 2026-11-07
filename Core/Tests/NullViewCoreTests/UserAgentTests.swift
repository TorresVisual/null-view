import XCTest
@testable import NullViewCore

final class UserAgentTests: XCTestCase {
    func testSafariUserAgent() {
        XCTAssertEqual(UserAgent.safari(systemVersion: "18.6.2"),
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1")
        XCTAssertTrue(UserAgent.safari(systemVersion: "26").contains("iPhone OS 26_0 like Mac OS X"))   // no minor part
        XCTAssertTrue(UserAgent.safari(systemVersion: "").contains("Version/18.0 "))                    // unparsable: still a valid UA
    }
}
