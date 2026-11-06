import XCTest
@testable import NullViewCore

/// The seams between modules, driven the way the app drives them (brief section 17).
/// Everything runs against `MemoryLibraryStore`; the GRDB adapter is only checked on the phone.
final class IntegrationTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func frameMsg(_ frame: String, pos: Double, dur: Double = 600, playing: Bool = true) -> VideoMessage {
        VideoMessage.parse("""
        {"type":"videos","frame":"\(frame)","videos":[{"i":0,"w":640,"h":360,"vis":230400,"playing":\(playing),
         "ended":false,"muted":false,"loop":false,"dur":\(dur),"pos":\(pos),"live":false,"drm":false,"src":true}]}
        """)!
    }

    /// Detector reports -> primary video -> progress saved -> app relaunch (new Library, same store)
    /// resumes at the saved position, and the video leaves Continue Watching once finished.
    func testDetectedVideoToWatchingStateAcrossRelaunch() throws {
        let page = URL(string: "https://video.example/watch?v=7&utm_source=feed")!
        let store = MemoryLibraryStore()
        var tracker = VideoTracker()
        tracker.apply(frameMsg("main", pos: 95), isMainFrame: true)
        let video = try XCTUnwrap(tracker.primary)

        let id = VideoID(url: page, index: video.index)
        let lib = Library(store: store)
        XCTAssertEqual(lib.reportProgress(id, title: "Clip", poster: nil, position: video.entry.pos,
                                          duration: video.entry.dur, now: t0), .saved)

        // Relaunch: a different Library over the same store, and the tracking parameter is gone from the URL.
        let relaunched = Library(store: store)
        let again = VideoID(url: URL(string: "https://video.example/watch?v=7")!, index: 0)
        XCTAssertEqual(relaunched.resumePosition(for: again), 95)
        XCTAssertEqual(relaunched.continueWatching(now: t0).map(\.title), ["Clip"])

        tracker.apply(frameMsg("main", pos: 596), isMainFrame: true)   // within the last few percent
        let end = try XCTUnwrap(tracker.primary).entry
        XCTAssertEqual(relaunched.reportProgress(id, title: "Clip", poster: nil, position: end.pos,
                                                 duration: end.dur, now: t0), .completed)
        XCTAssertTrue(relaunched.continueWatching(now: t0).isEmpty)
    }

    /// A video in an iframe still gets a stable identity (main frame first, then subframes).
    func testEmbeddedVideoIdentityIsStable() throws {
        var tracker = VideoTracker()
        tracker.apply(frameMsg("embed", pos: 10), isMainFrame: false)
        let first = try XCTUnwrap(tracker.primary)
        tracker.apply(frameMsg("main", pos: 0, playing: false), isMainFrame: true)
        XCTAssertEqual(tracker.videos.map(\.frame), ["main", "embed"])   // order does not depend on report order
        XCTAssertEqual(first.frame, "embed")
        XCTAssertEqual(tracker.primary?.frame, "embed")                  // the playing one still wins
    }

    /// A shared link opens a page; when its video ends, the queue hands out the next page once each.
    func testShareLinkThenQueueAutoAdvance() throws {
        let opened = try XCTUnwrap(DeepLink.parse(URL(string: "nullview://open?url=https%3A%2F%2Fa.example%2Fv%2F1")!))
        XCTAssertEqual(opened.host, "a.example")
        XCTAssertNil(DeepLink.parse(URL(string: "nullview://open?url=javascript%3Aalert(1)")!))

        let lib = Library(store: MemoryLibraryStore())
        lib.enqueue(URL(string: "https://a.example/v/2?utm_medium=x")!)
        lib.enqueue(URL(string: "https://a.example/v/2")!)             // duplicate after canonicalizing
        lib.enqueue(URL(string: "https://a.example/v/3")!)
        XCTAssertEqual(lib.popNext()?.path, "/v/2")
        XCTAssertEqual(lib.popNext()?.path, "/v/3")
        XCTAssertNil(lib.popNext())
    }

    /// Visiting a page records history once; pruning drops it after 90 days but keeps Watch Later.
    func testHistoryAndWatchLaterLifetimes() {
        let lib = Library(store: MemoryLibraryStore())
        let url = URL(string: "https://a.example/v/1")!
        lib.visit(url, title: "One", now: t0)
        lib.visit(url, title: "One", now: t0.addingTimeInterval(60))
        lib.toggleLater(url, title: "One", now: t0)
        XCTAssertEqual(lib.store.history().count, 1)
        lib.prune(now: t0.addingTimeInterval(91 * 86_400))
        XCTAssertTrue(lib.store.history().isEmpty)
        XCTAssertTrue(lib.isLater(url))
    }
}
