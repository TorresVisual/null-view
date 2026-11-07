import XCTest
@testable import NullViewCore

final class PlaybackTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let yt = URL(string: "https://www.youtube.com/watch?v=a")!

    func testLabels() {
        XCTAssertEqual(PlaybackSpeed.label(1), "1×")
        XCTAssertEqual(PlaybackSpeed.label(1.25), "1.25×")
        XCTAssertEqual(PlaybackSpeed.label(1.5), "1.5×")
    }

    func testSpeedIsPerSiteIgnoringWww() {
        var p = SpeedPrefs()
        p.set(1.5, for: yt)
        XCTAssertEqual(p.rate(for: URL(string: "https://youtube.com/watch?v=b")!), 1.5)
        XCTAssertNil(p.rate(for: URL(string: "https://joyn.at/x")!))
    }

    func testOneTimesForgetsTheSite() {
        var p = SpeedPrefs()
        p.set(2, for: yt)
        p.set(1, for: yt)
        XCTAssertTrue(p.rates.isEmpty)
        XCTAssertNil(p.rate(for: yt))
    }

    func testBadRatesAreRejected() {
        var p = SpeedPrefs()
        p.set(0, for: yt); p.set(.nan, for: yt); p.set(99, for: yt)
        XCTAssertTrue(p.rates.isEmpty)
        XCTAssertNil(SpeedPrefs(rates: ["youtube.com": 99]).rate(for: yt), "tampered defaults")
        XCTAssertNil(SpeedPrefs(rates: ["youtube.com": 1]).rate(for: yt), "1x needs no command")
    }

    func testTimerDueAfterMinutes() {
        let t = SleepTimer(.minutes(15), now: t0)
        XCTAssertFalse(t.isDue(now: t0.addingTimeInterval(14 * 60 + 59)))
        XCTAssertTrue(t.isDue(now: t0.addingTimeInterval(15 * 60)))
        XCTAssertFalse(t.holdsQueue)
    }

    func testEndOfVideoHoldsQueueAndIsNeverDueByClock() {
        let t = SleepTimer(.endOfVideo, now: t0)
        XCTAssertTrue(t.holdsQueue)
        XCTAssertFalse(t.isDue(now: t0.addingTimeInterval(86_400)))
    }

    func testOffDoesNothing() {
        let t = SleepTimer(.off, now: t0)
        XCTAssertFalse(t.isDue(now: t0.addingTimeInterval(86_400)))
        XCTAssertFalse(t.holdsQueue)
        XCTAssertNil(SleepTimer(.minutes(0), now: t0).deadline)
    }
}
