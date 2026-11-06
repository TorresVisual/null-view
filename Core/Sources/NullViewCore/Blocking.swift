import Foundation

/// Hosts where blocking is off. An entry covers the host and all its subdomains.
public struct AllowList: Codable, Equatable {
    public private(set) var hosts: [String] = []

    public init(hosts: [String] = []) { hosts.forEach { add($0) } }

    /// Lowercased, without `www.`; nil for empty or non-host text.
    public static func normalize(_ host: String?) -> String? {
        var h = (host ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty || h.contains(where: { $0.isWhitespace || $0 == "/" }) ? nil : h
    }

    /// The entry that covers `host` (the host itself or a parent domain), if any.
    public func entry(covering host: String?) -> String? {
        guard let h = Self.normalize(host) else { return nil }
        return hosts.first { h == $0 || h.hasSuffix("." + $0) }
    }

    public func contains(_ host: String?) -> Bool { entry(covering: host) != nil }

    public mutating func add(_ host: String?) {
        if let h = Self.normalize(host), !hosts.contains(h) { hosts = (hosts + [h]).sorted() }
    }

    public mutating func remove(_ host: String) { hosts.removeAll { $0 == host } }
}

public struct FilterList: Equatable {
    public let id: String
    public let name: String
    public let url: URL
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

    /// Lists are refreshed at launch when older than this (no background refresh).
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
