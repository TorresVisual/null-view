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

    /// Page world on purpose (it patches page APIs); no message handler.
    private static let alwaysVisible = """
        for (const [k, v] of [['hidden', false], ['webkitHidden', false], ['visibilityState', 'visible'], ['webkitVisibilityState', 'visible']]) {
          Object.defineProperty(Document.prototype, k, { get: () => v, configurable: true });
        }
        document.addEventListener('visibilitychange', e => e.stopImmediatePropagation(), true);
        """

    /// Spotify's own viewport tag pins the scale and blocks zoom, so replace it (and re-replace when the page
    /// rewrites it). W = layout width in CSS px, also the fully zoomed-out view: 1950 matches what the owner
    /// picked on the phone (zoomed out to scale 0.2, full desktop layout with the right panel). Raise W to
    /// start smaller, lower it to start bigger (the page then drops the right panel).
    private static let fitViewport = """
        (() => {
          // screen.width read 844 (the phone's height) in this WebView, so take the shorter side: the portrait width.
          const W = 1950, s = (Math.min(screen.width, screen.height) / W).toFixed(3), content = `width=${W}, initial-scale=${s}, minimum-scale=${s}, maximum-scale=4, user-scalable=yes`;
          const fix = () => {
            let ms = document.querySelectorAll('meta[name=viewport]');
            if (!ms.length && document.head) { const m = document.createElement('meta'); m.name = 'viewport'; document.head.appendChild(m); ms = [m]; }
            ms.forEach(m => { if (m.content !== content) m.content = content; });
          };
          fix();
          new MutationObserver(fix).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['content'] });
        })();
        """

    /// FRAGILE: private WKPreferences setter, called only if it exists. Returns whether it was applied.
    private static func setPrivateBool(_ selector: String, _ value: Bool, on obj: NSObject) -> Bool {
        let sel = NSSelectorFromString(selector)
        guard obj.responds(to: sel), let imp = obj.method(for: sel) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Setter.self)(obj, sel, value)
        return true
    }

    let webView: WKWebView
    private let note: (String) -> Void
    private var requested: URL?

    init(note: @escaping (String) -> Void) {
        self.note = note
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Not .desktop: the log showed it never took effect (platform stayed iPhone); the Mac UA alone is what Spotify reads.
        cfg.userContentController.addUserScript(WKUserScript(source: Self.fitViewport, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Track changes are driven by page timers; a page that thinks it is hidden gets them throttled,
        // which stalls the hop to the next track (locked screen, closed overlay).
        cfg.userContentController.addUserScript(WKUserScript(source: Self.alwaysVisible, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for name in ["_setHiddenPageDOMTimerThrottlingEnabled:", "_setPageVisibilityBasedProcessSuppressionEnabled:"] {
            note("spotify private pref \(name) " + (Self.setPrivateBool(name, false, on: cfg.preferences) ? "applied" : "missing"))
        }
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
        report(w, "loaded")
        // Layout debugging: the viewport the page really got, now and once Spotify's scripts have settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak w] in
            MainActor.assumeIsolated { if let w { self?.report(w, "+3s") } }
        }
    }

    private func report(_ w: WKWebView, _ tag: String) {
        let sv = w.scrollView
        let native = "native zoom=\(sv.zoomScale) min=\(sv.minimumZoomScale) max=\(sv.maximumZoomScale) content=\(Int(sv.contentSize.width))x\(Int(sv.contentSize.height)) view=\(Int(w.bounds.width))x\(Int(w.bounds.height))"
        w.evaluateJavaScript("[navigator.platform, navigator.maxTouchPoints, 'inner ' + innerWidth + 'x' + innerHeight, 'scale ' + (visualViewport ? visualViewport.scale : '?'), 'doc ' + document.documentElement.scrollWidth + 'x' + document.documentElement.scrollHeight, 'meta ' + (document.querySelector('meta[name=viewport]')?.content ?? 'none')].join(' | ')") { [weak self] r, _ in
            MainActor.assumeIsolated { self?.note("spotify \(tag) \(w.url?.path.prefix(30) ?? "?") \(native) js: \(r as? String ?? "?")") }
        }
    }

    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { w.load(action.request) }
        return nil
    }
}

/// Always in the view tree, shown or faded out: a web view removed from the window stops running the
/// page's timers, so closing a sheet stopped playback at the end of the current track.
struct SpotifyOverlay: View {
    let player: SpotifyPlayer
    @Binding var show: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Spotify").font(.headline)
                Spacer()
                Button("Done") { show = false }.frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16)
            .background(.bar)
            WebViewHost(webView: player.webView)
        }
        .background(Color.black.ignoresSafeArea())
        .opacity(show ? 1 : 0)
        .allowsHitTesting(show)
        .accessibilityHidden(!show)
    }
}
