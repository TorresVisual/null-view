import Foundation
import GRDB
import NullViewCore

/// `LibraryStore` on SQLite via GRDB (decisions.md "Persistence and library"). Dumb storage only:
/// every rule is in `NullViewCore.Library`, which is tested on Windows. This file can only be
/// compiled on the runner (GRDB needs a system SQLite).
final class LibraryDB: LibraryStore, SiteStore {
    private let db: DatabaseQueue

    init() throws {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        db = try DatabaseQueue(path: dir.appendingPathComponent("library.sqlite").path)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS record (page TEXT NOT NULL, idx INTEGER NOT NULL, title TEXT NOT NULL,
                    poster TEXT, pos REAL NOT NULL, dur REAL NOT NULL, at REAL NOT NULL, PRIMARY KEY (page, idx))
                """)
            for t in ["history", "later"] {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS \(t) (page TEXT PRIMARY KEY, title TEXT NOT NULL, poster TEXT, at REAL NOT NULL)
                    """)
            }
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS queue (n INTEGER PRIMARY KEY AUTOINCREMENT, page TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS site (url TEXT PRIMARY KEY, name TEXT NOT NULL, opens INTEGER NOT NULL, at REAL NOT NULL)")
        }
    }

    private func run(_ sql: String, _ args: StatementArguments = StatementArguments()) {
        do { try db.write { try $0.execute(sql: sql, arguments: args) } } catch { NSLog("LibraryDB: \(error)") }
    }

    private func rows(_ sql: String, _ args: StatementArguments = StatementArguments()) -> [Row] {
        do { return try db.read { try Row.fetchAll($0, sql: sql, arguments: args) } } catch { NSLog("LibraryDB: \(error)"); return [] }
    }

    private func watchRecord(_ r: Row) -> WatchRecord {
        WatchRecord(id: VideoID(page: r["page"], index: r["idx"]), title: r["title"], poster: r["poster"],
                    position: r["pos"], duration: r["dur"], updated: Date(timeIntervalSince1970: r["at"]))
    }

    private func savedPage(_ r: Row) -> SavedPage {
        SavedPage(page: r["page"], title: r["title"], poster: r["poster"], date: Date(timeIntervalSince1970: r["at"]))
    }

    // MARK: LibraryStore

    func record(for id: VideoID) -> WatchRecord? {
        rows("SELECT * FROM record WHERE page = ? AND idx = ?", [id.page, id.index]).first.map(watchRecord)
    }
    func records() -> [WatchRecord] { rows("SELECT * FROM record").map(watchRecord) }
    func save(_ r: WatchRecord) {
        run("INSERT OR REPLACE INTO record (page, idx, title, poster, pos, dur, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [r.id.page, r.id.index, r.title, r.poster, r.position, r.duration, r.updated.timeIntervalSince1970])
    }
    func deleteRecord(_ id: VideoID) { run("DELETE FROM record WHERE page = ? AND idx = ?", [id.page, id.index]) }
    func deleteRecords(before d: Date) { run("DELETE FROM record WHERE at < ?", [d.timeIntervalSince1970]) }

    func history() -> [SavedPage] { rows("SELECT * FROM history ORDER BY at DESC").map(savedPage) }
    func saveHistory(_ p: SavedPage) { savePage("history", p) }
    func deleteHistory(before d: Date) { run("DELETE FROM history WHERE at < ?", [d.timeIntervalSince1970]) }
    func deleteHistory(page: String) { run("DELETE FROM history WHERE page = ?", [page]) }
    func clearHistory() { run("DELETE FROM history") }

    func watchLater() -> [SavedPage] { rows("SELECT * FROM later ORDER BY at DESC").map(savedPage) }
    func saveLater(_ p: SavedPage) { savePage("later", p) }
    func deleteLater(page: String) { run("DELETE FROM later WHERE page = ?", [page]) }

    func queue() -> [String] { rows("SELECT page FROM queue ORDER BY n").map { $0["page"] } }
    func setQueue(_ pages: [String]) {
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM queue")
                for p in pages { try db.execute(sql: "INSERT INTO queue (page) VALUES (?)", arguments: [p]) }
            }
        } catch { NSLog("LibraryDB: \(error)") }
    }

    private func savePage(_ table: String, _ p: SavedPage) {
        run("INSERT OR REPLACE INTO \(table) (page, title, poster, at) VALUES (?, ?, ?, ?)",
            [p.page, p.title, p.poster, p.date.timeIntervalSince1970])
    }
}

// MARK: SiteStore (saved-sites launcher, issue #12)

extension LibraryDB {
    func sites() -> [SavedSite] {
        rows("SELECT * FROM site").map {
            SavedSite(url: $0["url"], name: $0["name"], opens: $0["opens"], lastOpened: Date(timeIntervalSince1970: $0["at"]))
        }
    }
    func saveSite(_ s: SavedSite) {
        run("INSERT OR REPLACE INTO site (url, name, opens, at) VALUES (?, ?, ?, ?)",
            [s.url, s.name, s.opens, s.lastOpened.timeIntervalSince1970])
    }
    func deleteSite(url: String) { run("DELETE FROM site WHERE url = ?", [url]) }
}
