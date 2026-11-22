import Foundation
import SwiftUI
import WebKit

/// Temporary diagnostics for the "drain while locked, nothing playing" investigation.
/// While the app is in the background it beats every 30 s; when the app comes back it writes ONE line to the
/// detection log: how long it was away, the longest gap between beats (a gap means the process was suspended),
/// the CPU time the process used, and how many times the detector's 1.5 s page timer ticked in the main frame.
/// Remove once the cause is found.
@MainActor
final class IdleProbe {
    /// `UserDefaults` key of the Settings toggle read in `NullViewApp.init`. Default on (the old behaviour).
    nonisolated static let activateKey = "activateAudioAtLaunch"

    private weak var webView: WKWebView?
    private let note: (String) -> Void
    private var start: Date?
    private var cpuAtStart = 0.0
    private var ticksAtStart = -1
    private var beats = 0
    private var lastBeat = Date()
    private var maxGap = 0.0
    private var timer: Timer?

    init(webView: WKWebView, note: @escaping (String) -> Void) {
        self.webView = webView
        self.note = note
    }

    func phase(_ p: ScenePhase) {
        switch p {
        case .background: begin()
        case .active: end()
        default: break
        }
    }

    private func begin() {
        guard start == nil else { return }
        let now = Date()
        start = now
        lastBeat = now
        beats = 0
        maxGap = 0
        cpuAtStart = Self.cpuSeconds()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        Task { ticksAtStart = await ticks() }
    }

    private func beat() {
        let now = Date()
        maxGap = max(maxGap, now.timeIntervalSince(lastBeat))
        lastBeat = now
        beats += 1
    }

    private func end() {
        guard let start else { return }
        self.start = nil
        timer?.invalidate()
        beat()   // a long gap since the last beat is the suspension
        let away = Date().timeIntervalSince(start)
        let cpu = Self.cpuSeconds() - cpuAtStart
        let t0 = ticksAtStart
        Task {
            let t1 = await ticks()
            let js = t0 >= 0 && t1 >= 0 ? "+\(t1 - t0) (running: ~\(Int(away / 1.5)))" : "n/a"
            let activate = UserDefaults.standard.object(forKey: Self.activateKey) as? Bool ?? true
            let pct = away > 0 ? cpu / away * 100 : 0
            note("idle probe: away \(Int(away))s, beats \(beats - 1), max gap \(Int(maxGap))s, "
                 + "cpu \(String(format: "%.1f", cpu))s (\(String(format: "%.2f", pct))%), page ticks \(js), "
                 + "audio session at launch \(activate ? "on" : "off")")
        }
    }

    /// The detector script's tick counter in the main frame; -1 when the page has none.
    private func ticks() async -> Int {
        guard let webView else { return -1 }
        let r = try? await webView.evaluateJavaScript("window.__nvTicks ?? -1", in: nil, contentWorld: VideoDetector.world)
        return (r as? Int) ?? -1
    }

    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let s = Double(u.ru_utime.tv_sec) + Double(u.ru_stime.tv_sec)
        let us = Double(u.ru_utime.tv_usec) + Double(u.ru_stime.tv_usec)
        return s + us / 1e6
    }
}
