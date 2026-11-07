import XCTest
@testable import NullViewCore

final class LibraryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let url = URL(string: "https://example.com/watch?v=1&utm_source=x")!
    var id: VideoID { VideoID(url: url, index: 0) }

    func day(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 86_400) }

    func testContinueWatchingThresholds() {
        let lib = Library(store: MemoryLibraryStore())
        XCTAssertEqual(lib.reportProgress(id, title: "A", poster: nil, position: 10, duration: 600, now: t0), .ignored)
        XCTAssertNil(lib.resumePosition(for: id))
        XCTAssertEqual(lib.reportProgress(id, title: "A", poster: nil, position: 120, duration: 600, now: t0), .saved)
        XCTAssertEqual(lib.resumePosition(for: id), 120)
        XCTAssertEqual(lib.continueWatching(now: t0).map(\.title), ["A"])
        // Within the last 5 %: finished, removed.
        XCTAssertEqual(lib.reportProgress(id, title: "A", poster: nil, position: 580, duration: 600, now: t0), .completed)
        XCTAssertNil(lib.resumePosition(for: id))
    }

    func testEndedAndLiveAreNotStored() {
        let lib = Library(store: MemoryLibraryStore())
        lib.reportProgress(id, title: "A", poster: nil, position: 100, duration: 600, now: t0)
        XCTAssertEqual(lib.reportProgress(id, title: "A", poster: nil, position: 100, duration: 600, ended: true, now: t0), .completed)
        XCTAssertTrue(lib.continueWatching(now: t0).isEmpty)
        XCTAssertEqual(lib.reportProgress(id, title: "L", poster: nil, position: 100, duration: nil, now: t0), .ignored)
        XCTAssertEqual(lib.reportProgress(id, title: "L", poster: nil, position: 100, duration: .infinity, now: t0), .ignored)
    }

    func testKeepsTitleAndPosterOnceFound() {
        let lib = Library(store: MemoryLibraryStore())
        lib.reportProgress(id, title: "Title", poster: "https://example.com/p.jpg", position: 30, duration: 600, now: t0)
        lib.reportProgress(id, title: "", poster: nil, position: 60, duration: 600, now: t0)
        let r = lib.continueWatching(now: t0).first
        XCTAssertEqual(r?.title, "Title")
        XCTAssertEqual(r?.poster, "https://example.com/p.jpg")
        XCTAssertEqual(r?.position, 60)
        XCTAssertTrue(lib.hasRecord(onPage: URL(string: "https://EXAMPLE.com/watch?v=1")!))
    }

    func testPruneRetention() {
        let store = MemoryLibraryStore()
        let lib = Library(store: store)
        lib.reportProgress(id, title: "A", poster: nil, position: 60, duration: 600, now: t0)
        lib.visit(url, title: "A", now: t0)
        lib.toggleLater(url, title: "A", now: t0)
        lib.enqueue(url)
        lib.prune(now: day(59))
        XCTAssertEqual(store.records().count, 1)
        XCTAssertEqual(store.history().count, 1)
        lib.prune(now: day(61))   // Continue Watching gone, history still there
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertEqual(store.history().count, 1)
        XCTAssertTrue(lib.continueWatching(now: day(61)).isEmpty)
        lib.prune(now: day(91))
        XCTAssertTrue(store.history().isEmpty)
        XCTAssertEqual(store.watchLater().count, 1)   // never auto-deleted
        XCTAssertEqual(store.queue().count, 1)
    }

    func testHistoryOneRowPerPageAndOnlyWeb() {
        let lib = Library(store: MemoryLibraryStore())
        lib.visit(url, title: "Old", now: t0)
        lib.visit(URL(string: "https://example.com/watch?v=1")!, title: "New", now: day(1))
        lib.visit(URL(string: "file:///etc/passwd")!, title: "x", now: day(1))
        lib.visit(URL(string: "about:blank")!, title: "x", now: day(1))
        XCTAssertEqual(lib.store.history().map(\.title), ["New"])
    }

    func testWatchLaterToggle() {
        let lib = Library(store: MemoryLibraryStore())
        XCTAssertTrue(lib.toggleLater(url, title: "A", now: t0))
        XCTAssertTrue(lib.isLater(url))
        XCTAssertFalse(lib.toggleLater(url, title: "A", now: t0))
        XCTAssertFalse(lib.isLater(url))
    }

    func testQueueOrderDedupeAndPop() {
        let lib = Library(store: MemoryLibraryStore())
        let a = URL(string: "https://a.example/1")!, b = URL(string: "https://b.example/2")!
        lib.enqueue(a); lib.enqueue(b); lib.enqueue(a)
        XCTAssertEqual(lib.store.queue().map(\.page), ["https://a.example/1", "https://b.example/2"])
        XCTAssertEqual(lib.popNext(), a)
        lib.removeFromQueue(page: "https://b.example/2")
        XCTAssertNil(lib.popNext())
    }

    func testQueueTitles() {
        let lib = Library(store: MemoryLibraryStore())
        let a = URL(string: "https://a.example/1?utm_source=x")!
        lib.enqueue(a)                                            // no title yet
        lib.enqueue(a, title: "  Part\n one  ")                   // a later enqueue fills it in, whitespace tidied
        lib.enqueue(a, title: "Other")                            // but never overwrites a title
        XCTAssertEqual(lib.store.queue(), [QueueItem(page: "https://a.example/1", title: "Part one")])
        lib.enqueue(URL(string: "https://b.example/2")!, title: String(repeating: "x", count: 500))
        XCTAssertEqual(lib.store.queue().last?.title.count, Library.maxTitle)
    }

    func testQuerySearchSiteAndSort() {
        let items = [("Zebra clip", "https://b.com/z"), ("apple pie", "https://a.com/p"), ("Éclair", "https://b.com/e")]
        func run(_ search: String = "", site: String? = nil, sort: LibrarySort = .newest) -> [String] {
            LibraryQuery.apply(items, search: search, site: site, sort: sort) { (title: $0.0, page: $0.1) }.map { $0.0 }
        }
        XCTAssertEqual(run(), ["Zebra clip", "apple pie", "Éclair"])
        XCTAssertEqual(run(sort: .oldest), ["Éclair", "apple pie", "Zebra clip"])
        XCTAssertEqual(run(sort: .title), ["apple pie", "Éclair", "Zebra clip"])
        XCTAssertEqual(run(sort: .site), ["apple pie", "Éclair", "Zebra clip"])
        XCTAssertEqual(run("eclair"), ["Éclair"])
        XCTAssertEqual(run("B.COM clip"), ["Zebra clip"])
        XCTAssertEqual(run(site: "b.com"), ["Zebra clip", "Éclair"])
        XCTAssertEqual(run("apple", site: "b.com"), [])
    }
}
