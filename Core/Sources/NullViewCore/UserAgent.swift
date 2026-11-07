import Foundation

/// The user agent of Safari on iPhone. WKWebView's default lacks `Version/x … Safari/604.1`, which many
/// players read as "in-app browser" and then take another path (Joyn stalled ~29 s there, Safari did not).
public enum UserAgent {
    /// `systemVersion` is `UIDevice.current.systemVersion`, e.g. "18.6.2". Safari shows major and minor only.
    public static func safari(systemVersion: String) -> String {
        let p = systemVersion.split(separator: ".").map(String.init)
        let major = p.first ?? "18", minor = p.count > 1 ? p[1] : "0"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(major)_\(minor) like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/\(major).\(minor) Mobile/15E148 Safari/604.1"
    }
}
