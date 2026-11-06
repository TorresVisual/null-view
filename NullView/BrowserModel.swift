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
        blocker = Blocker(userContentController: cfg.userContentController, persistentScripts: videoScript.map { [$0] } ?? [])
        super.init()
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
    }

    private func sync() {
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

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
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
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let scheme = action.request.url?.scheme?.lowercased() else { return .allow }
        if action.targetFrame?.isMainFrame == true, scheme == "http" || scheme == "https" {
            blocker.apply(for: action.request.url)
        }
        switch scheme {
        case "http", "https", "about", "blob": return .allow
        case "data": return action.targetFrame?.isMainFrame == true ? .cancel : .allow
        default: return .cancel
        }
    }

    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { failure = nil }

    /// The new document replaces the old one: forget its videos (the new page's frames report afresh).
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { detector.reset() }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { fail(e) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { fail(e) }

    private func fail(_ e: Error) {
        let ns = e as NSError
        // Cancelled loads (a new navigation started, or the user hit stop) are not errors.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        // "Frame load interrupted": a download or a policy-cancelled navigation, nothing to show.
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        failure = (ns.localizedDescription, ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { w.reload() }

    // MARK: WKUIDelegate

    /// `target=_blank` and `window.open` load in the same view (decisions.md).
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { w.load(action.request) }
        return nil
    }
}
