import XCTest
@testable import NullViewCore

final class VideoTests: XCTestCase {
    private func entry(i: Int = 0, w: Double = 640, h: Double = 360, vis: Double? = nil, playing: Bool = false,
                       muted: Bool = false, loop: Bool = false, drm: Bool = false, src: Bool = true,
                       dur: String = "120", pos: Double = 5) -> String {
        """
        {"i":\(i),"w":\(w),"h":\(h),"vis":\(vis ?? w * h),"playing":\(playing),"ended":false,"muted":\(muted),
         "loop":\(loop),"dur":\(dur),"pos":\(pos),"live":false,"drm":\(drm),"src":\(src)}
        """
    }

    private func msg(_ frame: String, _ entries: [String]) -> VideoMessage {
        VideoMessage.parse(#"{"type":"videos","frame":"\#(frame)","videos":[\#(entries.joined(separator: ","))]}"#)!
    }

    func testParseAndValidation() {
        XCTAssertNotNil(VideoMessage.parse(#"{"type":"videos","frame":"a","videos":[]}"#))
        XCTAssertEqual(VideoMessage.parse(#"{"type":"gone","frame":"a"}"#), .gone(frame: "a"))
        XCTAssertNil(VideoMessage.parse(#"{"type":"eval","frame":"a"}"#))             // unknown type
        XCTAssertNil(VideoMessage.parse(#"{"type":"gone","frame":""}"#))              // empty frame key
        XCTAssertNil(VideoMessage.parse("not json"))
        XCTAssertNil(VideoMessage.parse(#"{"type":"videos","frame":"a"}"#))            // videos missing
        XCTAssertNil(VideoMessage.parse(#"{"type":"videos","frame":"a","videos":[\#(entry(pos: -1))]}"#))
        XCTAssertNil(VideoMessage.parse(#"{"type":"videos","frame":"a","videos":[\#(entry(dur: "-3"))]}"#))
        let tooMany = Array(repeating: entry(), count: VideoMessage.maxVideosPerFrame + 1)
        XCTAssertNil(VideoMessage.parse(#"{"type":"videos","frame":"a","videos":[\#(tooMany.joined(separator: ","))]}"#))
        // dur null (live or unknown) is fine
        guard case let .videos(_, v)? = VideoMessage.parse(#"{"type":"videos","frame":"a","videos":[\#(entry(dur: "null"))]}"#)
        else { return XCTFail("null duration rejected") }
        XCTAssertNil(v[0].dur)
    }

    func testPrimaryPrefersPlayingThenVisibleThenSize() {
        var t = VideoTracker()
        XCTAssertNil(t.primary)
        t.apply(msg("main", [entry(i: 0, vis: 100_000), entry(i: 1, vis: 50_000, playing: true)]), isMainFrame: true)
        XCTAssertEqual(t.primary?.index, 1)                                     // playing beats bigger
        t.apply(msg("main", [entry(i: 0, vis: 100_000), entry(i: 1, vis: 50_000)]), isMainFrame: true)
        XCTAssertEqual(t.primary?.index, 0)                                     // none playing: most visible
        t.apply(msg("main", [entry(i: 0, vis: 50_000), entry(i: 1, vis: 50_000)]), isMainFrame: true)
        XCTAssertEqual(t.primary?.index, 0)                                     // tie: first
    }

    func testAmbientTinyDrmAndSourceless() {
        var t = VideoTracker()
        t.apply(msg("main", [
            entry(i: 0, playing: true, muted: true, loop: true),                // hero background loop
            entry(i: 1),                                                         // the real one, paused
            entry(i: 2, w: 1, h: 1),                                             // tracker
        ]), isMainFrame: true)
        XCTAssertEqual(t.primary?.index, 1)
        XCTAssertEqual(t.videos.count, 3)
        XCTAssertTrue(t.hasCandidate)

        var drm = VideoTracker()
        drm.apply(msg("main", [entry(drm: true)]), isMainFrame: true)
        XCTAssertTrue(drm.hasCandidate)                                         // button shows...
        XCTAssertNil(drm.primary)                                               // ...but disabled

        var tiny = VideoTracker()
        tiny.apply(msg("main", [entry(w: 1, h: 1), entry(i: 1, src: false)]), isMainFrame: true)
        XCTAssertNil(tiny.primary)
        XCTAssertTrue(tiny.hasCandidate)                                        // sourceless but big: shown, disabled

        var ambientOnly = VideoTracker()
        ambientOnly.apply(msg("main", [entry(muted: true, loop: true)]), isMainFrame: true)
        XCTAssertEqual(ambientOnly.primary?.index, 0)                           // still better than nothing
    }

    func testFrameOrderingAndGone() {
        var t = VideoTracker()
        t.apply(msg("ad", [entry()]), isMainFrame: false)                        // subframe reports first
        t.apply(msg("main", [entry(), entry(i: 1)]), isMainFrame: true)
        t.apply(msg("embed", [entry(playing: true)]), isMainFrame: false)
        let v = t.videos
        XCTAssertEqual(v.map(\.isMainFrame), [true, true, false, false])         // main first
        XCTAssertEqual(v.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(t.primary?.index, 3)                                     // playing embed in 2nd subframe

        t.apply(.gone(frame: "embed"), isMainFrame: false)
        XCTAssertEqual(t.videos.count, 3)
        t.apply(msg("main", []), isMainFrame: true)                              // update replaces, keeps position
        XCTAssertEqual(t.videos.count, 1)
        t.reset()
        XCTAssertTrue(t.videos.isEmpty)
        XCTAssertFalse(t.hasCandidate)
    }

    func testCanonicalURL() {
        func c(_ s: String) -> String { VideoID.canonical(URL(string: s)!) }
        XCTAssertEqual(c("HTTPS://Example.COM/watch?v=1&utm_source=x&fbclid=y&UTM_medium=z"), "https://example.com/watch?v=1")
        XCTAssertEqual(c("https://example.com/v?utm_source=x"), "https://example.com/v")
        XCTAssertEqual(c("https://example.com/v#comments"), "https://example.com/v")
        XCTAssertEqual(c("https://example.com/#/watch/1"), "https://example.com/#/watch/1")
        XCTAssertEqual(c("https://example.com/#!/watch/1"), "https://example.com/#!/watch/1")
        XCTAssertEqual(c("https://example.com/v?a=1&b=2"), "https://example.com/v?a=1&b=2")   // order kept
        XCTAssertEqual(VideoID(url: URL(string: "https://e.com/v?utm_x=1")!, index: 2),
                       VideoID(url: URL(string: "https://e.com/v")!, index: 2))
        XCTAssertNotEqual(VideoID(url: URL(string: "https://e.com/v")!, index: 1),
                          VideoID(url: URL(string: "https://e.com/v")!, index: 2))
    }
}

final class VideoGestureTests: XCTestCase {
    func testSeekTargetClamps() {
        XCTAssertEqual(VideoGestures.seekTarget(start: 50, duration: 60, dx: 100, width: 100), 60)   // clamp to end
        XCTAssertEqual(VideoGestures.seekTarget(start: 5, duration: 90, dx: -100, width: 100), 0)    // clamp to start
        XCTAssertEqual(VideoGestures.seekTarget(start: 50, duration: 600, dx: 50, width: 100), 150)  // half width = half of 200 s span
        XCTAssertEqual(VideoGestures.seekTarget(start: 7, duration: 0, dx: 50, width: 100), 7)       // unknown duration: no seek
    }

    func testLevelAndAxis() {
        XCTAssertEqual(VideoGestures.level(start: 0.5, dy: -100, height: 200), 1.0)
        XCTAssertEqual(VideoGestures.level(start: 0.5, dy: 50, height: 200), 0.25)
        XCTAssertNil(VideoGestures.axis(dx: 3, dy: 4))
        XCTAssertEqual(VideoGestures.axis(dx: 20, dy: -5), .horizontal)
        XCTAssertEqual(VideoGestures.axis(dx: 2, dy: -30), .vertical)
        XCTAssertEqual(VideoGestures.doubleTapDelta(x: 10, width: 100), -10)
        XCTAssertEqual(VideoGestures.doubleTapDelta(x: 90, width: 100), 10)
        XCTAssertEqual(VideoGestures.clock(65), "1:05")
        XCTAssertEqual(VideoGestures.clock(3723), "1:02:03")
    }

    func testFullscreenMessageAndFrameLookup() {
        XCTAssertEqual(VideoMessage.parse(#"{"type":"fullscreen","frame":"a","i":2}"#), .fullscreen(frame: "a", index: 2))
        XCTAssertNil(VideoMessage.parse(#"{"type":"fullscreen","frame":"a"}"#))
        XCTAssertNil(VideoMessage.parse(#"{"type":"fullscreen","frame":"a","i":-1}"#))
        var t = VideoTracker()
        let e = #"{"i":1,"w":640,"h":360,"vis":230400,"playing":false,"ended":false,"muted":false,"loop":false,"dur":9,"pos":0,"live":false,"drm":false,"src":true}"#
        t.apply(VideoMessage.parse(#"{"type":"videos","frame":"f","videos":[\#(e)]}"#)!, isMainFrame: false)
        XCTAssertEqual(t.video(frame: "f", i: 1)?.index, 0)
        XCTAssertNil(t.video(frame: "f", i: 0))
    }
}
