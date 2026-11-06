import NullViewCore
import WebKit

/// "Hide an element" (js/src/element-picker.js). The script is evaluated on demand in its own content
/// world, so the page cannot see the `nvPicker` handler. The only message accepted is one rule for
/// the page the user is looking at, and `ElementRule.line` checks the selector's charset.
@MainActor
final class ElementPicker: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "nullview.picker")
    static let handlerName = "nvPicker"

    weak var webView: WKWebView?
    /// A validated `host##selector` line.
    var onRule: ((String) -> Void)?
    var log: (String) -> Void = { _ in }

    func attach(to ucc: WKUserContentController) {
        ucc.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    func start() {
        guard let u = Bundle.main.url(forResource: "element-picker", withExtension: "js"),
              let src = try? String(contentsOf: u, encoding: .utf8) else {
            log("element-picker.js missing from the app bundle")
            return
        }
        webView?.evaluateJavaScript(src, in: nil, in: Self.world) { [weak self] result in
            if case let .failure(e) = result { self?.log("picker: \(e.localizedDescription)") }
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, message.frameInfo.isMainFrame,
              let json = message.body as? String,
              let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              d["type"] as? String == "rule",
              let host = d["host"] as? String, let selector = d["selector"] as? String,
              AllowList.normalize(host) == AllowList.normalize(webView?.url?.host),
              let line = ElementRule.line(host: host, selector: selector) else { return }
        onRule?(line)
    }
}
