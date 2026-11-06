import ContentBlockerConverter
import FilterEngine
import SwiftUI
import WebKit

/// Phase 0 feasibility spike (docs/decisions.md "Phase 0"). Not the real app architecture.
@MainActor
final class Spike: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var log = "Tap '1 Compile lists' first (downloads EasyList + EasyPrivacy).\n"
    let webView: WKWebView
    private var engine: WebExtension?
    private var navDone: CheckedContinuation<Void, Never>?
    private let bundleJS: String = {
        guard let u = Bundle.main.url(forResource: "adblock-content", withExtension: "js") else { return "" }
        return (try? String(contentsOf: u, encoding: .utf8)) ?? ""
    }()

    // Gate 2 fixtures: advanced-only rules (CSS injection + scriptlet) targeting example.com.
    private static let testRules = [
        "example.com#$#body { background-color: rgb(255, 0, 0) !important; }",
        "example.com#%#//scriptlet('set-constant', 'nvScriptletTest', 'true')",
    ]
    private static let lists: [(id: String, url: String)] = [
        ("easylist", "https://easylist.to/easylist/easylist.txt"),
        ("easyprivacy", "https://easylist.to/easylist/easyprivacy.txt"),
    ]

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.isInspectable = true
    }

    private func say(_ s: String) { log += s + "\n" }

    // MARK: Gate 1 + 2 setup: convert lists, compile rule lists, build the advanced-rules engine

    func installLists() async {
        if bundleJS.isEmpty { say("WARNING: adblock-content.js missing from bundle; cosmetic/scriptlets will not run") }
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        var advanced: [String] = []
        var sources: [(id: String, url: String?)] = Self.lists.map { ($0.id, $0.url) }
        sources.append(("nv-test", nil))
        for (id, url) in sources {
            do {
                var text = Self.testRules.joined(separator: "\n")
                if let url {
                    let t0 = Date()
                    let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
                    text = String(decoding: data, as: UTF8.self)
                    say("\(id): downloaded \(data.count / 1024) KB in \(Self.secs(t0))s")
                }
                text.makeContiguousUTF8()
                let lines = text.split(whereSeparator: \.isNewline).map(String.init)
                let t1 = Date()
                let r = await Task.detached(priority: .userInitiated) {
                    ContentBlockerConverter().convertArray(
                        rules: lines, safariVersion: SafariVersion.autodetect(),
                        advancedBlocking: true, maxJsonSizeBytes: nil, progress: nil)
                }.value
                say("\(id): converted in \(Self.secs(t1))s src=\(r.sourceRulesCount) safari=\(r.safariRulesCount) advanced=\(r.advancedRulesCount) discarded=\(r.discardedSafariRules) errors=\(r.errorsCount)")
                if let a = r.advancedRulesText { advanced.append(a) }
                if r.safariRulesCount > 0 {
                    let t2 = Date()
                    let list = try await WKContentRuleListStore.default().compileContentRuleList(
                        forIdentifier: id, encodedContentRuleList: r.safariRulesJSON)
                    if let list { ucc.add(list) }
                    say("\(id): compiled WKContentRuleList in \(Self.secs(t2))s")
                }
            } catch { say("\(id): FAILED \(error)") }
        }
        do {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("engine", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = try WebExtension(containerURL: dir)
            let rules = advanced.joined(separator: "\n")
            let t = Date()
            _ = try await Task.detached { try ext.buildFilterEngine(rules: rules) }.value
            engine = ext
            say("advanced engine built in \(Self.secs(t))s")
        } catch { say("engine FAILED \(error)") }
    }

    // MARK: Gate 1 + 2 check: load example.com, probe blocked requests, cosmetic CSS, scriptlet

    func runPageTest() async {
        await load(URL(string: "https://example.com")!)
        let js = """
        const ads = ['https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js',
          'https://securepubads.g.doubleclick.net/tag/js/gpt.js',
          'https://static.doubleclick.net/instream/ad_status.js',
          'https://www.googletagmanager.com/gtag/js?id=G-TEST'];
        const out = {};
        for (const u of ads) {
          try { await fetch(u, {mode: 'no-cors', cache: 'no-store'}); out[u] = 'LOADED (not blocked)'; }
          catch (e) { out[u] = 'blocked'; }
        }
        try { await fetch('https://example.org/', {mode: 'no-cors', cache: 'no-store'}); out.control = 'ok'; }
        catch (e) { out.control = 'FAILED (network?)'; }
        out.page_title = document.title;
        out.style_tags = document.querySelectorAll('style').length;
        out.cosmetic_body_bg = document.body ? getComputedStyle(document.body).backgroundColor : 'no body';
        out.scriptlet_nvScriptletTest = String(window.nvScriptletTest);
        return out;
        """
        do {
            let res = try await webView.callAsyncJavaScript(js, contentWorld: .page)
            let data = try JSONSerialization.data(withJSONObject: res ?? [:], options: [.prettyPrinted, .sortedKeys])
            say(String(decoding: data, as: UTF8.self))
            say("expect: ads=blocked, control=ok, body bg rgb(255, 0, 0), scriptlet=true")
        } catch { say("page test FAILED \(error)") }
    }

    // MARK: Gate 3 + 4: PiP and background audio on a custom-controlled <video>

    func loadVideoPage() {
        guard let u = Bundle.main.url(forResource: "video-test", withExtension: "html"),
              let html = try? String(contentsOf: u, encoding: .utf8) else { return say("video-test.html missing") }
        webView.loadHTMLString(html, baseURL: URL(string: "https://null-view.test"))
        say("3: tap play, then the PiP button. 4: while playing, lock the screen / switch apps.")
    }

    // MARK: Gate 5: nullview://open?url=...

    func handleOpen(_ url: URL) {
        say("5: received \(url.absoluteString)")
        guard url.scheme == "nullview", url.host == "open",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: q), ["http", "https"].contains(target.scheme) else { return say("5: rejected (bad shape)") }
        webView.load(URLRequest(url: target))
    }

    // MARK: Navigation: per-page lookup, inject cosmetic/scriptlet config as a page-world user script

    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // ponytail: main frame only; subframes would need their own lookup(pageUrl:topUrl:).
        if action.targetFrame?.isMainFrame == true {
            let ucc = w.configuration.userContentController
            ucc.removeAllUserScripts()
            if let url = action.request.url, ["http", "https"].contains(url.scheme),
               let c = engine?.lookup(pageUrl: url, topUrl: nil) {
                let cfg: [String: Any] = [
                    "css": c.css, "extendedCss": c.extendedCss, "js": c.js,
                    "scriptlets": c.scriptlets.map { ["name": $0.name, "args": $0.args] },
                    "engineTimestamp": c.engineTimestamp,
                ]
                if let d = try? JSONSerialization.data(withJSONObject: cfg) {
                    let src = "window.__nvConfig = \(String(decoding: d, as: UTF8.self));\n" + bundleJS
                    ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart,
                                                   forMainFrameOnly: true, in: .page))
                }
            }
        }
        return .allow
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { navDone?.resume(); navDone = nil }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        say("nav failed: \(e.localizedDescription)"); navDone?.resume(); navDone = nil
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        say("load failed: \(e.localizedDescription)"); navDone?.resume(); navDone = nil
    }

    private func load(_ url: URL) async {
        await withCheckedContinuation { c in navDone = c; webView.load(URLRequest(url: url)) }
    }

    private static func secs(_ t: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(t)) }
}
