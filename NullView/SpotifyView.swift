import SwiftUI
import WebKit
import NullViewCore

/// Spotify: its own WebView so the desktop user agent is fixed before the first load.
/// Putting it on the main view failed: after visiting another site, Spotify got the iPhone UA again.
/// Why: the free phone app only shuffles albums; the desktop web player plays them in order.
/// Shares cookies with the main browser (default data store). No content blocker here: Spotify's
/// ads are inserted into the audio stream, so the blocker cannot remove them anyway.
/// Since #18 the page is mostly hidden: `SpotifyCatalog` reads its JSON for the native screens and clicks its
/// play buttons, and the page itself is the fallback view (`showPage`).
@MainActor
final class SpotifyPlayer: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
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

    /// Hooks the web player: remembers the lock-screen handlers it registers (media session) and exposes
    /// cmd/state. Buttons are found by Spotify's `data-testid`s, the media-session handler is the fallback.
    /// FRAGILE: both depend on Spotify's page; a miss shows up as "no hook" or "none" in the log.
    private static let playerHook = """
        (() => {
          const handlers = {};
          if (window.MediaSession) {
            const orig = MediaSession.prototype.setActionHandler;
            MediaSession.prototype.setActionHandler = function (a, f) { handlers[a] = f; return orig.call(this, a, f); };
          }
          const ids = { playpause: 'control-button-playpause', nexttrack: 'control-button-skip-forward', previoustrack: 'control-button-skip-back' };
          const button = a => document.querySelector(`[data-testid="${ids[a]}"]`);
          window.__nv = {
            cmd(a) {
              const b = button(a);
              if (b) { b.click(); return 'button'; }
              const ms = navigator.mediaSession;
              const name = a === 'playpause' ? (ms.playbackState === 'playing' ? 'pause' : 'play') : a;
              if (handlers[name]) { handlers[name](); return 'handler ' + name; }
              return 'none';
            },
            state() {
              const b = button('playpause'), md = navigator.mediaSession.metadata;
              return JSON.stringify({
                playing: navigator.mediaSession.playbackState === 'playing' || /pause/i.test(b ? b.getAttribute('aria-label') || '' : ''),
                title: (md && md.title) || document.title || ''
              });
            }
          };
        })();
        """

    @Published private(set) var playing = false
    @Published private(set) var title = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    let webView: WKWebView
    let note: (String) -> Void
    let listened: ListenedStore   // which albums the user has heard (issue #19), read by `SpotifyCatalog`
    private var requested: URL?
    /// True while the web page itself is shown (fallback, or a link that is not the native grid's).
    @Published var showPage = false
    private(set) lazy var catalog = SpotifyCatalog(player: self)

    init(listened: ListenedStore, note: @escaping (String) -> Void) {
        self.listened = listened
        self.note = note
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Not .desktop: the log showed it never took effect (platform stayed iPhone); the Mac UA alone is what Spotify reads.
        cfg.userContentController.addUserScript(WKUserScript(source: Self.fitViewport, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: Self.playerHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // #18: records the page's own JSON for the album grid and chapter list (read by SpotifyCatalog) and
        // carries the scroll and click commands. Page world, no message handler.
        if let u = Bundle.main.url(forResource: "spotify-data", withExtension: "js"),
           let src = try? String(contentsOf: u, encoding: .utf8) {
            cfg.userContentController.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        } else {
            note("spotify-data.js missing from the app bundle")
        }
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

    /// The artist and home links show the native grid. Anything else (an album, a playlist, another artist)
    /// loads in the web page and shows it, unless it is already showing, so reopening never interrupts playback.
    func open(_ url: URL) {
        guard SpotifyLink.destination(for: url) == .page else { showPage = false; return }
        showPage = true
        guard url != requested else { return }
        requested = url
        webView.load(URLRequest(url: url))
    }

    /// Loads `url` and waits for the load to finish. The page fetches its data after that: callers poll the recorder.
    func load(_ url: URL) async {
        requested = url
        webView.load(URLRequest(url: url))
        try? await Task.sleep(for: .seconds(1))
        var waited = 0
        while webView.isLoading, waited < 40 { try? await Task.sleep(for: .seconds(0.5)); waited += 1 }
    }

    /// Evaluates a script that returns a string, or any JSON-like value; "?" when it threw.
    func eval(_ script: String) async -> Any? { try? await webView.evaluateJavaScript(script) }

    /// Calls a function body in the page world with named arguments (no string splicing). "?" when it threw.
    func call(_ body: String, _ args: [String: Any]) async -> String {
        let r = try? await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        return r as? String ?? "?"
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

    // MARK: Release (issue #23)

    /// The page last shown before `releaseIfPaused` blanked it, for `restore`.
    private var releasedURL: URL?
    var isReleased: Bool { webView.url?.absoluteString == "about:blank" }

    /// A paused page still runs a full desktop Spotify at 1950 px with throttling off, so on Done and on leaving the
    /// app it is blanked. Playing audio is never touched. A page that cannot say it is paused (no hook, still
    /// loading) or that a fetch or a play click is using is kept; the next event looks again.
    func releaseIfPaused(_ why: String) {
        guard let url = webView.url, !isReleased, !catalog.isBusy else { return }
        webView.evaluateJavaScript("window.__nv ? window.__nv.state() : ''") { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self, !self.catalog.isBusy, let s = (r as? String).flatMap({ SpotifyPlayerState(json: $0) }), !s.playing else { return }
                self.releasedURL = url
                self.requested = nil
                self.webView.load(URLRequest(url: URL(string: "about:blank")!))
                self.note("spotify released page (\(why))")
            }
        }
    }

    /// Reloads the page `releaseIfPaused` blanked, for playback that did not start from the native screens.
    func restore() {
        guard let url = releasedURL else { return }
        requested = url
        webView.load(URLRequest(url: url))
        note("spotify restored page")
    }

    // MARK: Controls

    /// "playpause", "nexttrack" or "previoustrack". Logged with the path taken, so a broken hook shows in the log.
    func send(_ action: String) {
        if action == "playpause", isReleased { catalog.resume(); return }   // nothing to click: bring the album back first
        webView.evaluateJavaScript("window.__nv ? window.__nv.cmd('\(action)') : 'no hook'") { [weak self] r, _ in
            MainActor.assumeIsolated {
                self?.note("spotify \(action) -> \(r as? String ?? "?")")
                self?.refresh()
            }
        }
    }

    /// Reads play state and chapter title back from the page. Called every second while the overlay is shown.
    func refresh() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        webView.evaluateJavaScript("window.__nv ? window.__nv.state() : ''") { [weak self] r, _ in
            MainActor.assumeIsolated {
                guard let self, let s = (r as? String).flatMap({ SpotifyPlayerState(json: $0) }) else { return }
                self.playing = s.playing
                self.title = s.title
            }
        }
        // Lines the page wrote while nobody was looking (the stop at an album's end, issue #20).
        webView.evaluateJavaScript("window.__nvSpotify ? window.__nvSpotify.takeLog() : []") { [weak self] r, _ in
            MainActor.assumeIsolated { for line in r as? [String] ?? [] { self?.note("spotify \(line)") } }
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
    @ObservedObject var player: SpotifyPlayer
    @ObservedObject var catalog: SpotifyCatalog   // observed here too: the top bar and player capsule read it
    @Binding var show: Bool
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // The page stays in the tree behind the native screens: it plays the audio and is what the screens read.
        // The glass controls are safe-area insets (issue #22), so the screens scroll under them instead of ending at a bar.
        ZStack {
            WebViewHost(webView: player.webView)
                .opacity(player.showPage ? 1 : 0)
                .allowsHitTesting(player.showPage)
            if !player.showPage { SpotifyScreens(catalog: catalog, playingTitle: player.title) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { playerCapsule }
        .background(Theme.ink.ignoresSafeArea())
        .environment(\.colorScheme, .dark)   // Spotify stays dark whatever the system says (design-baseline.md)
        .opacity(show ? 1 : 0)
        .allowsHitTesting(show)
        .accessibilityHidden(!show)
        .onReceive(tick) { _ in if show { player.refresh() } }
        .onChange(of: show) { _, now in
            guard now else { return }
            player.refresh()
            if !player.showPage { catalog.loadAlbums() }
        }
    }

    /// Floating glass buttons, no bar: back (an album, or the web page's history), then the page toggle and Done.
    private var topBar: some View {
        VStack(spacing: Theme.gap) {
            HStack(spacing: Theme.gap) {
                if player.showPage {
                    glassIcon("chevron.backward", "Page back") { player.webView.goBack(); player.refresh() }.disabled(!player.canGoBack)
                    glassIcon("chevron.forward", "Page forward") { player.webView.goForward(); player.refresh() }.disabled(!player.canGoForward)
                } else if catalog.album != nil {
                    glassIcon("chevron.backward", "Back to albums") { catalog.close() }
                }
                Spacer(minLength: 0)
                glassIcon(player.showPage ? "square.grid.2x2" : "globe", player.showPage ? "Show albums" : "Show Spotify page") { player.showPage.toggle() }
                Button { show = false; player.releaseIfPaused("done") } label: {
                    Text("Done").foregroundStyle(Color.accentColor).padding(.horizontal, Theme.gap).frame(minHeight: Theme.hit)
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule)
            }
            if let why = catalog.formatProblem {
                Banner(icon: "exclamationmark.triangle", text: "Spotify changed its format (\(why)). This is Spotify's own page instead.",
                       buttonTitle: "Retry", buttonAction: { player.showPage = false; catalog.retry() })
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, Theme.gap / 2)
    }

    /// The page's own controls are tiny at the fitted zoom, so these drive the player from outside. A floating glass
    /// capsule: what is playing (chapter, then album) and previous, play, next.
    private var playerCapsule: some View {
        let now = SpotifyNowPlaying(player.title)
        return HStack(spacing: Theme.gap) {
            Cover(url: catalog.cover(forAlbum: now.album)).frame(width: Theme.hit)
            VStack(alignment: .leading, spacing: 2) {
                Text(now.chapter.isEmpty ? "Nothing playing" : now.chapter).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let album = now.album { Text(album).font(.caption).foregroundStyle(Theme.paperDim).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            plainIcon("backward.fill", "Previous track") { player.send("previoustrack") }
            Button { player.send("playpause") } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").foregroundStyle(Theme.ink)
                    .frame(width: Theme.hit, height: Theme.hit).background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            plainIcon("forward.fill", "Next track") { player.send("nexttrack") }
        }
        .padding(.horizontal, Theme.gap).padding(.vertical, Theme.gap / 2)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, Theme.gap).padding(.bottom, Theme.gap / 2)
    }

    private func glassIcon(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).foregroundStyle(Theme.paper).frame(width: Theme.hit, height: Theme.hit) }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .accessibilityLabel(label)
    }

    private func plainIcon(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).foregroundStyle(Theme.paper).frame(width: Theme.hit, height: Theme.hit) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}
