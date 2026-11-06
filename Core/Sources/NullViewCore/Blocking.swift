import Foundation

/// Hosts where blocking is off. An entry covers the host and all its subdomains.
/// `blocked` holds exceptions under an allowed parent (blocking back on for one subdomain);
/// the most specific entry covering a host decides.
public struct AllowList: Codable, Equatable {
    public private(set) var hosts: [String] = []
    public private(set) var blocked: [String] = []

    public init(hosts: [String] = []) { hosts.forEach { add($0) } }

    private enum CodingKeys: String, CodingKey { case hosts, blocked }

    /// `blocked` is optional so lists saved before it existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decode([String].self, forKey: .hosts)
        blocked = try c.decodeIfPresent([String].self, forKey: .blocked) ?? []
    }

    /// Lowercased, without `www.`; nil for empty or non-host text.
    public static func normalize(_ host: String?) -> String? {
        var h = (host ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty || h.contains(where: { $0.isWhitespace || $0 == "/" }) ? nil : h
    }

    private static func covers(_ entry: String, _ host: String) -> Bool { host == entry || host.hasSuffix("." + entry) }

    /// True if blocking is off for `host`: its most specific covering entry (longest, since all are
    /// suffixes of `host`) is an allowed host, not a blocked exception.
    public func contains(_ host: String?) -> Bool {
        guard let h = Self.normalize(host) else { return false }
        let a = hosts.filter { Self.covers($0, h) }.map(\.count).max()
        guard let a else { return false }
        return a > (blocked.filter { Self.covers($0, h) }.map(\.count).max() ?? -1)
    }

    public mutating func add(_ host: String?) {
        guard let h = Self.normalize(host) else { return }
        blocked.removeAll { $0 == h }
        if !hosts.contains(h) { hosts = (hosts + [h]).sorted() }
    }

    /// Drops an allowed entry, plus exceptions that no allowed parent covers any more.
    public mutating func remove(_ host: String) {
        hosts.removeAll { $0 == host }
        blocked.removeAll { b in !hosts.contains { Self.covers($0, b) } }
    }

    /// Flip blocking for exactly this host (and its subdomains), leaving parents alone.
    /// Stores an entry only when the flip is not already implied by a parent.
    public mutating func toggle(_ host: String?) {
        guard let h = Self.normalize(host) else { return }
        let allow = !contains(h)
        hosts.removeAll { $0 == h }
        blocked.removeAll { $0 == h }
        if allow != contains(h) {
            if allow { hosts = (hosts + [h]).sorted() } else { blocked = (blocked + [h]).sorted() }
        }
    }
}

public struct FilterList: Codable, Equatable {
    public let id: String
    public let name: String
    public let url: URL
}

/// Which filter lists are on, plus the lists the user added by URL.
public struct FilterConfig: Codable, Equatable {
    public private(set) var enabled: Set<String>
    public private(set) var custom: [FilterList]

    public init(enabled: Set<String> = Set(Filters.defaults.map(\.id)), custom: [FilterList] = []) {
        self.enabled = enabled
        self.custom = custom
    }

    public var all: [FilterList] { Filters.builtIn + custom }
    public var active: [FilterList] { all.filter { enabled.contains($0.id) } }
    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) }
    public func isCustom(_ id: String) -> Bool { custom.contains { $0.id == id } }

    public mutating func setEnabled(_ id: String, _ on: Bool) {
        guard all.contains(where: { $0.id == id }) else { return }
        if on { enabled.insert(id) } else { enabled.remove(id) }
    }

    /// https only: a list over plain http could be swapped in transit, and lists inject rules into every page.
    /// Returns nil for a bad or duplicate URL. The new list starts enabled.
    @discardableResult
    public mutating func addCustom(name: String, urlText: String) -> FilterList? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              !all.contains(where: { $0.url == url }) else { return nil }
        let title = name.trimmingCharacters(in: .whitespaces)
        let list = FilterList(id: "url-" + Self.hash(url.absoluteString), name: title.isEmpty ? host : title, url: url)
        custom.append(list)
        enabled.insert(list.id)
        return list
    }

    public mutating func removeCustom(_ id: String) {
        custom.removeAll { $0.id == id }
        enabled.remove(id)
    }

    /// FNV-1a: stable across launches and platforms (`hashValue` is not).
    private static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// Windows a page opens: `target=_blank` links and `window.open`.
public enum PopupPolicy {
    /// Whether to load a page-opened window in the view. A tapped link is the user's own doing. A script
    /// opening a window is how popunder ads work, so it only gets through to the page's own site (and an
    /// allowlisted site is decided by the caller). ponytail: a script that clicks a hidden `<a target=_blank>`
    /// looks like a link tap to WebKit and passes. Upgrade path: the AdGuard Popups list, or a private
    /// `_userInitiated` check.
    public static func allows(linkTap: Bool, from page: URL?, to target: URL?) -> Bool {
        linkTap || sameSite(page?.host, target?.host)
    }

    /// The same host, or one is a subdomain of the other (`m.example.com` and `example.com`).
    public static func sameSite(_ a: String?, _ b: String?) -> Bool {
        guard let x = AllowList.normalize(a), let y = AllowList.normalize(b) else { return false }
        return x == y || x.hasSuffix("." + y) || y.hasSuffix("." + x)
    }
}

/// A "hide this element" rule built from the picker's selector.
public enum ElementRule {
    /// Plain CSS selectors only (tags, ids, classes, `>`, `:nth-of-type`). The picker never produces more, and
    /// the charset keeps a stray `+js(`, `#%#` or newline from turning one rule into a script rule.
    public static func line(host: String?, selector: String) -> String? {
        guard let h = AllowList.normalize(host), !selector.isEmpty, selector.count <= 400,
              let f = selector.first, f.isLetter || f == "#" || f == ".",
              selector.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || "_-#.>:() ".contains($0) })
        else { return nil }
        return "\(h)##\(selector)"
    }
}

public enum Filters {
    /// decisions.md: EasyList, EasyPrivacy, AdGuard Mobile Ads. Each compiles to its own
    /// `WKContentRuleList`, so the 150,000-rule cap applies per list.
    public static let defaults: [FilterList] = [
        FilterList(id: "easylist", name: "EasyList", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        FilterList(id: "adguard-mobile", name: "AdGuard Mobile Ads",
                   url: URL(string: "https://filters.adtidy.org/ios/filters/11_optimized.txt")!),
    ]

    /// Off until the user turns them on. Separate lists, so a site that breaks can be traced to one of them.
    public static let optional: [FilterList] = [
        FilterList(id: "adguard-cookies", name: "AdGuard Cookie Notices",
                   url: URL(string: "https://filters.adtidy.org/ios/filters/18_optimized.txt")!),
        FilterList(id: "adguard-popups", name: "AdGuard Popups",
                   url: URL(string: "https://filters.adtidy.org/ios/filters/19_optimized.txt")!),
    ]

    public static let builtIn = defaults + optional

    /// Lists are refreshed at launch and when the app returns to the front, if older than this.
    public static let maxAge: TimeInterval = 24 * 3600

    /// A missing date (never updated) counts as stale.
    public static func isStale(_ updated: Date?, now: Date = Date()) -> Bool {
        guard let updated else { return true }
        return now.timeIntervalSince(updated) > maxAge
    }

    /// Splits the custom-rules text box into rule lines.
    public static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
