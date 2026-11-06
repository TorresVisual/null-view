import Foundation

/// A video the user has partly watched (decisions.md "Persistence and library").
public struct WatchRecord: Equatable {
    public let id: VideoID
    public var title: String
    public var poster: String?     // thumbnail URL where the page offers one (og:image / poster)
    public var position: Double
    public var duration: Double
    public var updated: Date

    public init(id: VideoID, title: String, poster: String?, position: Double, duration: Double, updated: Date) {
        self.id = id; self.title = title; self.poster = poster
        self.position = position; self.duration = duration; self.updated = updated
    }
}

/// A page in History or Watch Later. `date` is the visit time / the time it was saved.
public struct SavedPage: Equatable {
    public let page: String        // canonical URL
    public var title: String
    public var poster: String?
    public var date: Date

    public init(page: String, title: String, poster: String? = nil, date: Date) {
        self.page = page; self.title = title; self.poster = poster; self.date = date
    }
}

/// Plain storage, no rules. The app implements it with GRDB (`NullView/LibraryDB.swift`, only
/// built on the runner: GRDB needs a system SQLite that the Windows toolchain lacks); tests use
/// `MemoryLibraryStore`. All rules live in `Library`, so they are tested here.
public protocol LibraryStore: AnyObject {
    func record(for id: VideoID) -> WatchRecord?
    func records() -> [WatchRecord]
    func save(_ record: WatchRecord)
    func deleteRecord(_ id: VideoID)
    func deleteRecords(before: Date)

    /// One row per page (a revisit moves it up). Newest first.
    func history() -> [SavedPage]
    func saveHistory(_ page: SavedPage)
    func deleteHistory(before: Date)
    func deleteHistory(page: String)
    func clearHistory()

    /// Newest first.
    func watchLater() -> [SavedPage]
    func saveLater(_ page: SavedPage)
    func deleteLater(page: String)

    func queue() -> [String]
    func setQueue(_ pages: [String])
}

/// Watching state rules. Thresholds are constants and may be tuned (decisions.md).
public final class Library {
    public static let minResume = 15.0          // seconds watched before it counts as "continue"
    public static let completeFraction = 0.95   // past this share of the duration = finished
    public static let historyDays = 90
    public static let continueDays = 60

    public enum Outcome: Equatable { case ignored, saved, completed }

    public let store: LibraryStore
    public init(store: LibraryStore) { self.store = store }

    // MARK: Playback position and Continue Watching

    public static func isComplete(position: Double, duration: Double) -> Bool {
        duration > 0 && position >= duration * completeFraction
    }

    /// Call as playback progresses. Live streams (no finite duration) are never stored.
    @discardableResult
    public func reportProgress(_ id: VideoID, title: String, poster: String?, position: Double,
                               duration: Double?, ended: Bool = false, now: Date = Date()) -> Outcome {
        guard let duration, duration.isFinite, duration > 0, position.isFinite else { return .ignored }
        if ended || Self.isComplete(position: position, duration: duration) {
            store.deleteRecord(id)
            return .completed
        }
        guard position >= Self.minResume else { return .ignored }
        let old = store.record(for: id)
        // Keep a good title/poster once found; later reports may come before the page has them.
        store.save(WatchRecord(id: id, title: title.isEmpty ? old?.title ?? "" : title,
                               poster: poster ?? old?.poster, position: position, duration: duration, updated: now))
        return .saved
    }

    /// Where to resume this video, if it was left part-way.
    public func resumePosition(for id: VideoID) -> Double? {
        guard let r = store.record(for: id), !Self.isComplete(position: r.position, duration: r.duration) else { return nil }
        return r.position
    }

    /// Most recently watched first; entries untouched for 60 days are gone (also removed by `prune`).
    public func continueWatching(now: Date = Date()) -> [WatchRecord] {
        let cutoff = Self.cutoff(days: Self.continueDays, from: now)
        return store.records().filter { $0.updated >= cutoff }.sorted { $0.updated > $1.updated }
    }

    /// Any saved position on this page, whatever the video index (for the relaunch banner).
    public func hasRecord(onPage url: URL) -> Bool {
        let page = VideoID.canonical(url)
        return store.records().contains { $0.id.page == page }
    }

    // MARK: History

    public func visit(_ url: URL, title: String, now: Date = Date()) {
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return }
        store.saveHistory(SavedPage(page: VideoID.canonical(url), title: title, date: now))
    }

    // MARK: Watch Later (never auto-deleted)

    public func isLater(_ url: URL) -> Bool {
        let page = VideoID.canonical(url)
        return store.watchLater().contains { $0.page == page }
    }

    /// Adds the page, or removes it if it is already saved. Returns the new state.
    @discardableResult
    public func toggleLater(_ url: URL, title: String, poster: String? = nil, now: Date = Date()) -> Bool {
        let page = VideoID.canonical(url)
        if isLater(url) { store.deleteLater(page: page); return false }
        store.saveLater(SavedPage(page: page, title: title, poster: poster, date: now))
        return true
    }

    // MARK: Queue

    /// Appends the page unless it is already queued.
    public func enqueue(_ url: URL) {
        let page = VideoID.canonical(url)
        var q = store.queue()
        if !q.contains(page) { q.append(page); store.setQueue(q) }
    }

    public func removeFromQueue(page: String) { store.setQueue(store.queue().filter { $0 != page }) }

    /// The next page to play; it leaves the queue. nil when the queue is empty.
    public func popNext() -> URL? {
        var q = store.queue()
        while !q.isEmpty {
            let page = q.removeFirst()
            if let u = URL(string: page) { store.setQueue(q); return u }
        }
        store.setQueue(q)
        return nil
    }

    // MARK: Cleanup

    /// History after 90 days, Continue Watching entries after 60. Watch Later and the queue stay.
    public func prune(now: Date = Date()) {
        store.deleteHistory(before: Self.cutoff(days: Self.historyDays, from: now))
        store.deleteRecords(before: Self.cutoff(days: Self.continueDays, from: now))
    }

    private static func cutoff(days: Int, from now: Date) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
}

/// Sorting, site filter and search for the Library lists. Items come in newest first.
public enum LibrarySort: String, CaseIterable {
    case newest = "Newest", oldest = "Oldest", title = "Title", site = "Site"
}

public enum LibraryQuery {
    public static func host(_ page: String) -> String { URL(string: page)?.host ?? page }

    /// `search` matches title or address, case and diacritics ignored, all words must hit.
    /// `site` keeps only that host. `sort` reorders; `.newest` keeps the given order.
    public static func apply<T>(_ items: [T], search: String = "", site: String? = nil, sort: LibrarySort = .newest,
                                key: (T) -> (title: String, page: String)) -> [T] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        var out = items.filter { item in
            let k = key(item)
            if let site, host(k.page) != site { return false }
            let hay = k.title + " " + k.page
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        switch sort {
        case .newest: break
        case .oldest: out.reverse()
        case .title: out.sort { key($0).title.localizedCaseInsensitiveCompare(key($1).title) == .orderedAscending }
        case .site:
            out.sort {
                let (a, b) = (host(key($0).page), host(key($1).page))
                return a == b ? key($0).title.localizedCaseInsensitiveCompare(key($1).title) == .orderedAscending : a < b
            }
        }
        return out
    }
}

/// In-memory store for tests.
public final class MemoryLibraryStore: LibraryStore {
    private var recs: [VideoID: WatchRecord] = [:]
    private var hist: [String: SavedPage] = [:]
    private var later: [String: SavedPage] = [:]
    private var q: [String] = []

    public init() {}

    public func record(for id: VideoID) -> WatchRecord? { recs[id] }
    public func records() -> [WatchRecord] { Array(recs.values) }
    public func save(_ record: WatchRecord) { recs[record.id] = record }
    public func deleteRecord(_ id: VideoID) { recs[id] = nil }
    public func deleteRecords(before d: Date) { recs = recs.filter { $0.value.updated >= d } }

    public func history() -> [SavedPage] { hist.values.sorted { $0.date > $1.date } }
    public func saveHistory(_ p: SavedPage) { hist[p.page] = p }
    public func deleteHistory(before d: Date) { hist = hist.filter { $0.value.date >= d } }
    public func deleteHistory(page: String) { hist[page] = nil }
    public func clearHistory() { hist = [:] }

    public func watchLater() -> [SavedPage] { later.values.sorted { $0.date > $1.date } }
    public func saveLater(_ p: SavedPage) { later[p.page] = p }
    public func deleteLater(page: String) { later[page] = nil }

    public func queue() -> [String] { q }
    public func setQueue(_ pages: [String]) { q = pages }
}
