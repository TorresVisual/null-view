import NullViewCore
import UIKit
import WebKit

/// Receives `<video>` reports from `js/src/video-detect.js` (isolated content world, all frames)
/// and keeps a `VideoTracker`. Only one fixed message handler; messages are parsed and validated
/// in `VideoMessage.parse`, anything else is dropped (decisions.md "JS bridge and security").
@MainActor
final class VideoDetector: NSObject, ObservableObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "nullview.video")
    static let handlerName = "nvVideo"

    /// What the floating button needs. Published only when it changes, so the browser view does
    /// not redraw on every position update.
    enum ButtonState: Equatable { case hidden, disabled, enabled }
    @Published private(set) var button: ButtonState = .hidden

    /// Video mode hooks in here: a report arrived / the page asked for fullscreen on a video.
    var onChange: (() -> Void)?
    /// Watching state hooks in here (every report).
    var onReport: (() -> Void)?
    var onFullscreen: ((_ frame: String, _ index: Int) -> Void)?
    weak var webView: WKWebView?

    private(set) var tracker = VideoTracker()
    /// Where each reporting frame lives, so a command can run in the frame that holds the video.
    private var frames: [String: WKFrameInfo] = [:]
    private(set) var log: [String] = []
    private var pageURL: URL?
    private var netSeen = Set<String>()  // diagnostic lines already logged for this page
    private var lastLogKey = ""
    private var lastLogTime = Date.distantPast

    /// The user script for every frame. nil (and a log line) if the file is missing from the bundle.
    static func makeScript() -> WKUserScript? {
        guard let u = Bundle.main.url(forResource: "video-detect", withExtension: "js"),
              let src = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        return WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    /// Page-world hook that turns the page's fullscreen requests into a DOM event (see the file).
    static func makeFullscreenHook() -> WKUserScript? {
        guard let u = Bundle.main.url(forResource: "fullscreen-hook", withExtension: "js"),
              let src = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        return WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    func attach(to ucc: WKUserContentController, scriptLoaded: Bool) {
        ucc.add(self, contentWorld: Self.world, name: Self.handlerName)
        if !scriptLoaded { note("video-detect.js missing from the app bundle") }
    }

    /// A new document was committed in the main frame. Same-document (SPA) changes do not reset:
    /// the script keeps reporting and only the page URL, hence the video identity, changes.
    func reset() {
        tracker.reset()
        frames = [:]
        netSeen = []
        publish()
    }

    func setURL(_ url: URL?) { pageURL = url }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, let json = message.body as? String,
              let msg = VideoMessage.parse(json) else { return }
        switch msg {
        case let .videos(frame, _): frames[frame] = message.frameInfo
        case let .gone(frame): frames[frame] = nil
        case let .fullscreen(frame, index):
            note("page asked for fullscreen (video \(index) in \(frame.prefix(4)))")
            onFullscreen?(frame, index)
            return
        case let .net(_, lines):
            for l in lines where netSeen.insert(l).inserted { note("net \(l)") }
            return
        }
        tracker.apply(msg, isMainFrame: message.frameInfo.isMainFrame)
        publish()
        onChange?()
        onReport?()
        logPrimary(nil)
    }

    /// Runs one of the fixed commands of `video-detect.js` (`window.__nvCmd`) in the video's frame.
    /// Only the command name is a string; the argument is a number.
    func command(frame: String, index: Int, _ cmd: String, _ arg: Double = 0) {
        guard let info = frames[frame], let webView, arg.isFinite else { note("\(cmd): frame is gone"); return }
        webView.evaluateJavaScript("window.__nvCmd(\(index), '\(cmd)', \(arg))", in: info, in: Self.world) { [weak self] r in
            switch r {
            case .failure(let e): self?.note("\(cmd) failed: \(e.localizedDescription)")
            case .success(let ok): if (ok as? Bool) == false { self?.note("\(cmd): video is gone") }
            }
        }
    }

    private func publish() {
        let new: ButtonState = !tracker.hasCandidate ? .hidden : tracker.primary == nil ? .disabled : .enabled
        if new != button { button = new }
    }

    func logPrimary(_ why: String?, force: Bool = false) {
        guard let p = tracker.primary else {
            if force { note("no controllable video (\(tracker.videos.count) found)") }
            return
        }
        let e = p.entry
        let id = pageURL.map { VideoID(url: $0, index: p.index) }
        // One line per change, plus a position update every 5 s while playing.
        let key = "\(id?.page ?? "?")|\(p.index)|\(e.dur ?? -1)|\(e.playing)|\(e.pj ?? false)|\(tracker.videos.count)"
        guard force || why != nil || key != lastLogKey || Date().timeIntervalSince(lastLogTime) >= 5 else { return }
        lastLogKey = key
        lastLogTime = Date()
        let dur = e.live ? "live" : e.dur.map { String(format: "%.1f", $0) } ?? "?"
        note("\(why.map { $0 + ": " } ?? "")video #\(p.index) of \(tracker.videos.count) "
             + "\(p.isMainFrame ? "main" : "iframe") \(Int(e.w))x\(Int(e.h)) "
             + "\(e.playing ? "playing" : e.pj == true ? "paused-by-page" : "paused") pos=\(String(format: "%.1f", e.pos)) dur=\(dur)\n    \(id?.page ?? "?")")
    }

    func note(_ s: String) {
        let t = Date().formatted(date: .omitted, time: .standard)
        log.append("\(t) \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    var logText: String { log.suffix(15).joined(separator: "\n") }
}
