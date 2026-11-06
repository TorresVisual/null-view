import Foundation

/// Turns address-bar text into a URL to load.
public enum AddressInput {
    public static let defaultSearchTemplate = "https://duckduckgo.com/?q=%s"

    /// A search template must contain `%s` and expand to an http(s) URL with a host.
    public static func isValidSearchTemplate(_ t: String) -> Bool {
        t.contains("%s") && webURL(t.replacingOccurrences(of: "%s", with: "x")) != nil
    }

    /// nil = nothing to load (empty input, or an invalid search template).
    /// Anything that is not clearly a web address becomes a search, including
    /// `javascript:`, `data:` and `file:` text, so the address bar can never run them.
    public static func resolve(_ raw: String, searchTemplate: String = defaultSearchTemplate) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains(where: \.isWhitespace) {
            if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil {
                if let u = webURL(text) { return u }
            } else if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:(?![0-9])", options: .regularExpression) == nil,
                      let u = webURL("https://" + text), looksLikeHost(u.host) {
                return u
            }
        }
        return search(text, template: searchTemplate)
    }

    /// `u` only if it is an http(s) URL with a host.
    public static func webURL(_ s: String) -> URL? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let h = u.host, !h.isEmpty else { return nil }
        return u
    }

    private static func search(_ q: String, template: String) -> URL? {
        guard isValidSearchTemplate(template),
              let enc = q.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return webURL(template.replacingOccurrences(of: "%s", with: enc))
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `localhost`, an IPv6 literal, a dotted IPv4 address, or a name with a dot.
    private static func looksLikeHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        if h == "localhost" || h.contains(":") { return true }  // host drops brackets from [::1]
        if h.hasSuffix(".") || h.hasPrefix(".") || !h.contains(".") { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        if labels.contains(where: \.isEmpty) { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return labels.count == 4 && labels.allSatisfy { Int($0).map { $0 <= 255 } ?? false }
        }
        return true
    }
}

/// `nullview://open?url=<http(s) URL>`
public enum DeepLink {
    public static func parse(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "nullview", url.host?.lowercased() == "open",
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
        return AddressInput.webURL(target)
    }
}
