import AVFoundation
import Combine
import NullViewCore
import UIKit
import WebKit

/// Owns the single WebView. The data model is "one tab for now": when tabs arrive,
/// this becomes a per-tab object and a session holds a list of them.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    nonisolated static let searchTemplateKey = "searchTemplate"

    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    /// Set when a navigation fails; cleared when the next one starts.
    @Published private(set) var failure: (message: String, url: URL?)?

    let webView: WKWebView
    let blocker: Blocker
    let detector: VideoDetector
    let videoMode: VideoMode
    let watch: WatchState
    let sites: Sites
    nonisolated static let lastURLKey = "lastURL"
    /// Spotify spike: its web player plays albums in order, the phone app shuffles on free accounts, and its
    /// mobile page sends you to the app. So spotify.com gets a desktop UA. Content mode alone was ignored on
    /// some loads (the log showed an iPhone UA), so the UA is also pinned, per navigation.
    private static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        let videoScript = VideoDetector.makeScript()
        let det = VideoDetector()
        det.attach(to: cfg.userContentController, scriptLoaded: videoScript != nil)
        detector = det
        let scripts = [videoScript, VideoDetector.makeFullscreenHook()].compactMap { $0 }
        blocker = Blocker(userContentController: cfg.userContentController, persistentScripts: scripts)
        det.webView = webView
        videoMode = VideoMode(detector: det, webView: webView)
        let db = try? LibraryDB()
        let store: LibraryStore = db ?? MemoryLibraryStore()
        let siteStore: SiteStore = db ?? MemorySiteStore()
        sites = Sites(store: siteStore)
        let ws = WatchState(library: Library(store: store), detector: det, videoMode: videoMode, webView: webView)
        watch = ws
        det.onReport = { [weak ws] in ws?.onReport() }
        super.init()
        ws.onNavigate = { [weak self] in self?.load($0) }
        // Diagnostics for the background-audio bug: why does the system stop playback?
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let t = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 99
            MainActor.assumeIsolated { self?.detector.note("audio interruption type=\(t)") }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let r = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 99
            MainActor.assumeIsolated { self?.detector.note("audio route change reason=\(r)") }
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true

        let w = webView
        Publishers.MergeMany([
            w.publisher(for: \.url).map { _ in }.eraseToAnyPublisher(),
            w.publisher(for: \.canGoBack).map { _ in }.eraseToAnyPublisher(),
            w.publisher(for: \.canGoForward).map { _ in }.eraseToAnyPublisher(),
            w.publisher(for: \.isLoading).map { _ in }.eraseToAnyPublisher(),
            w.publisher(for: \.estimatedProgress).map { _ in }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in MainActor.assumeIsolated { self?.sync() } }
        .store(in: &cancellables)

        // Relaunch: reopen the last page. Nothing is played until the user taps the banner.
        watch.library.prune()
        if let s = UserDefaults.standard.string(forKey: Self.lastURLKey), let u = AddressInput.webURL(s) {
            webView.load(URLRequest(url: u))
            if watch.library.hasRecord(onPage: u) { watch.resumeOffer = u }
        }
    }

    private func sync() {
        if let u = webView.url, u != url, AddressInput.webURL(u.absoluteString) != nil {
            UserDefaults.standard.set(u.absoluteString, forKey: Self.lastURLKey)
        }
        url = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
        detector.setURL(webView.url)
    }

    // MARK: Actions

    /// Address-bar text: a URL, or a search.
    func go(_ text: String) {
        let stored = UserDefaults.standard.string(forKey: Self.searchTemplateKey) ?? ""
        let template = AddressInput.isValidSearchTemplate(stored) ? stored : AddressInput.defaultSearchTemplate
        if let u = AddressInput.resolve(text, searchTemplate: template) { load(u) }
    }

    /// An explicit load (address bar, deep link) ends video mode first: the lock only stops pages from navigating.
    func load(_ url: URL) {
        videoMode.exit()
        watch.resumeOffer = nil
        webView.load(URLRequest(url: url))
    }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func stop() { webView.stopLoading() }

    /// Shield button: allowlist (or un-allowlist) this site and reload without blocking.
    func toggleBlocking() {
        guard webView.url != nil else { return }
        blocker.toggleAllow(for: webView.url)
        webView.reloadFromOrigin()
    }

    func reload() {
        if let f = failure?.url { load(f) } else if webView.url != nil { webView.reload() }
    }

    func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // MARK: WKNavigationDelegate

    /// Fail closed: only web pages load. `tel:`, `file:`, app-store schemes and the like are
    /// cancelled, and a page cannot navigate the top frame to a `data:` document.
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.targetFrame?.isMainFrame ?? true {
            let desktop = action.request.url?.host?.hasSuffix("spotify.com") == true
            preferences.preferredContentMode = desktop ? .desktop : .recommended
            w.customUserAgent = desktop ? Self.desktopUA : nil
        }
        return (policy(for: action), preferences)
    }

    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        // Video mode lock: the page cannot navigate the main frame or open windows (popups, redirects).
        if videoMode.active, action.targetFrame?.isMainFrame ?? true {
            detector.note("locked: cancelled \(action.request.url?.absoluteString.prefix(80) ?? "?")")
            return .cancel
        }
        guard let scheme = action.request.url?.scheme?.lowercased() else { return .allow }
        if action.targetFrame?.isMainFrame ?? true {
            detector.note("nav type=\(action.navigationType.rawValue) \(action.request.url?.absoluteString.prefix(100) ?? "?")")
        }
        if action.targetFrame?.isMainFrame == true, scheme == "http" || scheme == "https" {
            blocker.apply(for: action.request.url)
            // iOS hands tapped links to the domain's installed app (Universal Links, e.g. x.com).
            // WebKit's private "allow without trying app link" policy (Allow + 2, in
            // WKNavigationDelegatePrivate.h) keeps the tap in this view. Cancel + manual load does
            // not work: the cancel also kills the load started inside the callback (issue #10).
            if action.navigationType == .linkActivated {
                let noAppLink: WKNavigationActionPolicy? = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2)
                return noAppLink ?? .allow
            }
        }
        switch scheme {
        case "http", "https", "about", "blob": return .allow
        case "data": return action.targetFrame?.isMainFrame == true ? .cancel : .allow
        default: return .cancel
        }
    }

    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { failure = nil }

    func webView(_ w: WKWebView, didReceiveServerRedirectForProvisionalNavigation n: WKNavigation!) {
        detector.note("redirect -> \(w.url?.absoluteString.prefix(100) ?? "?")")
    }

    /// The new document replaces the old one: forget its videos (the new page's frames report afresh).
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        detector.note("commit \(w.url?.absoluteString.prefix(100) ?? "?")")
        detector.reset()
        watch.pageChanged()
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if let u = w.url { watch.library.visit(u, title: w.title ?? "") }
        // Spotify spike: does this WebView expose encrypted-media APIs, and which UA did the page get?
        if w.url?.host?.hasSuffix("spotify.com") == true {
            w.evaluateJavaScript("[typeof navigator.requestMediaKeySystemAccess, typeof window.WebKitMediaKeys, navigator.platform, navigator.maxTouchPoints, navigator.userAgent.slice(0, 70)].join(' | ')") { [weak self] r, _ in
                MainActor.assumeIsolated { self?.detector.note("spotify eme: \(r as? String ?? "js failed")") }
            }
        }
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { fail(e) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { fail(e) }

    private func fail(_ e: Error) {
        let ns = e as NSError
        detector.note("fail \(ns.domain) \(ns.code) \(ns.userInfo[NSURLErrorFailingURLErrorKey] ?? "")")
        // Cancelled loads (a new navigation started, or the user hit stop) are not errors.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        // "Frame load interrupted": a download or a policy-cancelled navigation, nothing to show.
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        failure = (ns.localizedDescription, ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        videoMode.exit()
        w.reload()
    }

    // MARK: WKUIDelegate

    /// `target=_blank` and `window.open` load in the same view (decisions.md).
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil && !videoMode.active { w.load(action.request) }
        return nil
    }
}
