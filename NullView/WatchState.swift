import Foundation
import NullViewCore
import WebKit

/// Glue between the video detector and `NullViewCore.Library` (rules are tested there): saves playback
/// position, resumes it once the video's metadata has loaded, and runs the queue and the relaunch banner.
@MainActor
final class WatchState: ObservableObject {
    let library: Library
    private let detector: VideoDetector
    private let videoMode: VideoMode
    private weak var webView: WKWebView?

    /// Set on relaunch when the restored page has a saved position; the browser shows "Resume where you left off".
    @Published var resumeOffer: URL?
    /// Navigate to a page (queue advance). Set by `BrowserModel`.
    var onNavigate: ((URL) -> Void)?

    private var seeked: Set<VideoID> = []        // resume seek already done for this page load
    private var ended: Set<VideoID> = []         // `ended` already handled (queue advance fires once)
    private var lastSave: [VideoID: Date] = [:]
    private var wasPlaying = false
    private var posters: [String: String] = [:]  // page -> poster URL ("" = looked, none found)
    private var autoEnter = false
    private var awaitCommit = false              // a load was just started: the old page's video must not count
    private var autoEnterTask: Task<Void, Never>?

    init(library: Library, detector: VideoDetector, videoMode: VideoMode, webView: WKWebView) {
        self.library = library
        self.detector = detector
        self.videoMode = videoMode
        self.webView = webView
    }

    /// A new document was committed: allow one resume seek per video again.
    func pageChanged() {
        awaitCommit = false
        seeked = []
        ended = []
        wasPlaying = false
    }

    /// Open video mode on the page's video as soon as it is found. `afterLoad`: a navigation was just
    /// started, so wait for its new document instead of grabbing the old page's video.
    func enterVideoWhenReady(afterLoad: Bool = false) {
        resumeOffer = nil
        if !afterLoad, detector.tracker.primary != nil { enterNow(); return }
        autoEnter = true
        awaitCommit = afterLoad
        autoEnterTask?.cancel()
        autoEnterTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled { self?.autoEnter = false }
        }
    }

    private func enterNow() {
        autoEnter = false
        autoEnterTask?.cancel()
        videoMode.enter()
        videoMode.play()
    }

    /// Every detector report (position updates arrive about once a second while playing).
    func onReport() {
        guard let page = webView?.url, let v = videoMode.pinned ?? detector.tracker.primary else { return }
        let id = VideoID(url: page, index: v.index)
        let e = v.entry

        // Resume: metadata is loaded once the duration is known. Only if the page left it at the start.
        if !seeked.contains(id), let dur = e.dur, dur > 0, !e.live {
            seeked.insert(id)
            if e.pos < 2, let p = library.resumePosition(for: id), p < dur {
                detector.command(frame: v.frame, index: e.i, "seek", p)
            }
        }

        if autoEnter, !awaitCommit, !videoMode.active { enterNow() }

        if e.ended {
            guard ended.insert(id).inserted else { return }
            persist(id, v)
            if let next = library.popNext() {
                detector.note("queue: next \(next.absoluteString.prefix(80))")
                onNavigate?(next)
                enterVideoWhenReady(afterLoad: true)
            }
            return
        }
        ended.remove(id)

        let due = lastSave[id].map { Date().timeIntervalSince($0) >= 5 } ?? true
        if due || (wasPlaying && !e.playing) { persist(id, v) }
        wasPlaying = e.playing
    }

    /// The app left the foreground: write the position now (it may be killed in the background).
    func flush() {
        guard let page = webView?.url, let v = videoMode.pinned ?? detector.tracker.primary else { return }
        persist(VideoID(url: page, index: v.index), v)
    }

    private func persist(_ id: VideoID, _ v: TrackedVideo) {
        lastSave[id] = Date()
        let e = v.entry
        library.reportProgress(id, title: webView?.title ?? "", poster: poster(for: id.page),
                               position: e.pos, duration: e.live ? nil : e.dur, ended: e.ended)
    }

    /// Thumbnail: the page's og:image, else a `<video poster>`. Fetched once per page, used from the next save on.
    private func poster(for page: String) -> String? {
        if let p = posters[page] { return p.isEmpty ? nil : p }
        posters[page] = ""
        let js = """
        (() => { const m = document.querySelector('meta[property="og:image"]')?.content
                 || document.querySelector('video[poster]')?.poster || '';
                 if (!m) return ''; try { return new URL(m, location.href).href } catch { return '' } })()
        """
        webView?.evaluateJavaScript(js) { [weak self] r, _ in
            // Untrusted page content: accept only a plain http(s) address of sane length.
            guard let s = r as? String, s.count < 2000, AddressInput.webURL(s) != nil else { return }
            Task { @MainActor in self?.posters[page] = s }
        }
        return nil
    }
}
