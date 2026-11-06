import SwiftUI
import WebKit

/// SPIKE (Spotify): its own WebView so the desktop user agent is fixed before the first load.
/// Putting it on the main view failed: after visiting another site, Spotify got the iPhone UA again.
/// Why: the free phone app only shuffles albums; the desktop web player plays them in order.
/// Shares cookies with the main browser (default data store). No content blocker here: Spotify's
/// ads are inserted into the audio stream, so the blocker cannot remove them anyway.
@MainActor
final class SpotifyPlayer: NSObject, WKNavigationDelegate, WKUIDelegate {
    nonisolated static func isSpotify(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        return h == "spotify.com" || h.hasSuffix(".spotify.com")
    }

    private static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let webView: WKWebView
    private let note: (String) -> Void
    private var requested: URL?

    init(note: @escaping (String) -> Void) {
        self.note = note
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = Self.desktopUA
        webView.isInspectable = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Loads `url` unless it is already showing, so reopening the sheet never interrupts playback.
    func open(_ url: URL) {
        guard url != requested else { return }
        requested = url
        webView.load(URLRequest(url: url))
    }

    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        let main = action.targetFrame?.isMainFrame ?? true
        if main { note("spotify nav \(url?.absoluteString.prefix(100) ?? "?")") }
        guard let scheme = url?.scheme?.lowercased() else { return .allow }
        // Fail closed like the main view; also drops Spotify's "open in the app" bounce (app.link, spotify://, App Store).
        if main, url?.host?.lowercased().hasSuffix("app.link") == true { return .cancel }
        return ["http", "https", "about", "blob"].contains(scheme) ? .allow : .cancel
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        w.evaluateJavaScript("[navigator.platform, navigator.maxTouchPoints, navigator.userAgent.slice(0, 50)].join(' | ')") { [weak self] r, _ in
            MainActor.assumeIsolated { self?.note("spotify loaded \(w.url?.absoluteString.prefix(60) ?? "?") ua: \(r as? String ?? "?")") }
        }
    }

    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { w.load(action.request) }
        return nil
    }
}

struct SpotifySheet: View {
    let player: SpotifyPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebViewHost(webView: player.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Spotify")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
