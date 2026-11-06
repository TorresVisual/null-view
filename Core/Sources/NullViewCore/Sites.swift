import Foundation

/// A platform the user saved by hand (issue #12), shown as a tile that opens it.
public struct SavedSite: Equatable {
    public let url: String         // address as entered, normalised; also the identity
    public var name: String
    public var opens: Int
    public var lastOpened: Date

    /// The site's own `/favicon.ico`. No third-party icon service, so no host list leaves the device.
    public var iconURL: URL? {
        guard let u = URL(string: url), let scheme = u.scheme, let host = u.host else { return nil }
        let port = u.port.map { ":\($0)" } ?? ""
        return URL(string: "\(scheme)://\(host)\(port)/favicon.ico")
    }

    public init(url: String, name: String, opens: Int = 0, lastOpened: Date = .distantPast) {
        self.url = url; self.name = name; self.opens = opens; self.lastOpened = lastOpened
    }
}

/// Plain storage, no rules (`NullView/LibraryDB.swift` on device, `MemorySiteStore` in tests).
public protocol SiteStore: AnyObject {
    func sites() -> [SavedSite]
    func saveSite(_ site: SavedSite)
    func deleteSite(url: String)
}

/// Rules for the saved-sites launcher.
public final class Sites {
    public let store: SiteStore
    public init(store: SiteStore) { self.store = store }

    /// Most opened first; ties go to the most recently opened, then to the name.
    public func ordered() -> [SavedSite] {
        store.sites().sorted {
            if $0.opens != $1.opens { return $0.opens > $1.opens }
            if $0.lastOpened != $1.lastOpened { return $0.lastOpened > $1.lastOpened }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// `raw` must be an address ("youtube.com", "https://reddit.com"), never a search.
    /// A blank name falls back to the host. nil = not a web address, or already saved.
    @discardableResult
    public func add(_ raw: String, name: String = "") -> SavedSite? {
        guard let u = AddressInput.resolve(raw, searchTemplate: "") else { return nil }
        let url = u.absoluteString
        guard !store.sites().contains(where: { $0.url == url }) else { return nil }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = SavedSite(url: url, name: n.isEmpty ? Self.defaultName(u) : n)
        store.saveSite(site)
        return site
    }

    public func recordOpen(_ site: SavedSite, now: Date = Date()) {
        update(site) { $0.opens += 1; $0.lastOpened = now }
    }

    /// Edits the stored copy, so a stale `SavedSite` held by the UI cannot overwrite newer counts.
    private func update(_ site: SavedSite, _ change: (inout SavedSite) -> Void) {
        guard var s = store.sites().first(where: { $0.url == site.url }) else { return }
        change(&s)
        store.saveSite(s)
    }

    public func remove(_ site: SavedSite) { store.deleteSite(url: site.url) }

    private static func defaultName(_ u: URL) -> String {
        let h = u.host ?? u.absoluteString
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

public final class MemorySiteStore: SiteStore {
    private var all: [String: SavedSite] = [:]
    public init() {}
    public func sites() -> [SavedSite] { Array(all.values) }
    public func saveSite(_ site: SavedSite) { all[site.url] = site }
    public func deleteSite(url: String) { all[url] = nil }
}
