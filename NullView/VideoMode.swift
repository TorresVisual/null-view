import AVFoundation
import MediaPlayer
import NullViewCore
import SwiftUI
import WebKit

/// Video mode (decisions.md "Video"): the page's own `<video>` is pinned over the whole web view by
/// `video-detect.js`, the app rotates to landscape, and our controls and gestures sit on top.
/// There is no second web view or player: the same WKWebView is shown, so playback never restarts.
@MainActor
final class VideoMode: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var controlsVisible = true
    /// The pinned video's latest report. nil while not in video mode.
    @Published private(set) var video: VideoEntry?
    @Published private(set) var hud: String?
    @Published private(set) var hudLevel: HUDLevel?

    private let detector: VideoDetector
    private let webView: WKWebView
    private var target: (frame: String, index: Int)?
    private var savedBrightness: CGFloat?
    private var rateBeforeBoost: Double?
    private var hideTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    let volume = SystemVolume()
    private var remote: [(MPRemoteCommand, Any)] = []

    init(detector: VideoDetector, webView: WKWebView) {
        self.detector = detector
        self.webView = webView
        detector.onChange = { [weak self] in self?.refresh() }
        detector.onFullscreen = { [weak self] frame, index in self?.enter(frame: frame, index: index) }
    }

    // MARK: Enter and exit

    /// The floating button: the primary video.
    func enter() {
        guard let p = detector.tracker.primary else { detector.note("video mode: no controllable video"); return }
        enter(frame: p.frame, index: p.entry.i)
    }

    func enter(frame: String, index: Int) {
        guard !active, let v = detector.tracker.video(frame: frame, i: index) else { return }
        target = (frame, index)
        video = v.entry
        active = true
        savedBrightness = screen.brightness
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        send("enter")
        registerRemote()
        rotate(.landscape)
        poke()
        detector.note("video mode on: video \(index) in \(frame.prefix(4)), \(v.isMainFrame ? "main" : "iframe")")
    }

    /// The explicit back control. Navigation was locked meanwhile, so the page and position are untouched.
    func exit() {
        guard active else { return }
        if rateBeforeBoost != nil { setRate(rateBeforeBoost ?? 1); rateBeforeBoost = nil }
        send("exit")
        unregisterRemote()
        active = false
        video = nil
        hideTask?.cancel()
        if let b = savedBrightness { screen.brightness = b }
        savedBrightness = nil
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        rotate(.portrait)
        target = nil
        detector.note("video mode off")
    }

    /// A report arrived. The pinned video vanishing (page re-rendered it away) ends video mode.
    private func refresh() {
        guard active, let t = target else { return }
        guard let v = detector.tracker.video(frame: t.frame, i: t.index) else { exit(); return }
        if v.entry != video { video = v.entry }
    }

    // MARK: Commands

    /// The video video mode is pinned to, if any (progress is saved for this one).
    var pinned: TrackedVideo? { target.flatMap { detector.tracker.video(frame: $0.frame, i: $0.index) } }
    func play() { send("play") }

    var canSeek: Bool { video.map { !$0.live && ($0.dur ?? 0) > 0 } ?? false }
    var position: Double { video?.pos ?? 0 }
    var duration: Double { video?.dur ?? 0 }

    func togglePlay() { send(video?.playing == true ? "pause" : "play"); poke() }
    func seek(to t: Double) { guard canSeek else { return }; send("seek", min(max(t, 0), duration)); poke() }
    func seek(by d: Double) { seek(to: position + d); flash(d < 0 ? "−\(Int(-d)) s" : "+\(Int(d)) s") }
    func setRate(_ r: Double) { send("rate", r) }
    func togglePiP() { send("pip"); poke() }

    func boost(_ on: Bool) {
        if on, rateBeforeBoost == nil { rateBeforeBoost = video?.rate ?? 1; setRate(2); flash("2×") }
        else if !on, let r = rateBeforeBoost { setRate(r); rateBeforeBoost = nil }
    }

    /// Lock-screen / Control Center play and pause. The page (YouTube) pauses itself when the screen locks;
    /// in video mode WebKit's own play button did not bring it back, so these resume it through our command.
    private func registerRemote() {
        let c = MPRemoteCommandCenter.shared()
        for (cmd, name) in [(c.playCommand, "play"), (c.pauseCommand, "pause")] {
            cmd.isEnabled = true
            let token = cmd.addTarget { [weak self] _ in
                Task { @MainActor in self?.detector.note("remote \(name)"); self?.send(name) }
                return .success
            }
            remote.append((cmd, token))
        }
    }

    private func unregisterRemote() {
        remote.forEach { $0.0.removeTarget($0.1) }
        remote = []
    }

    private func send(_ cmd: String, _ arg: Double = 0) {
        guard let t = target else { return }
        detector.command(frame: t.frame, index: t.index, cmd, arg)
    }

    // MARK: Controls and feedback

    func toggleControls() {
        if controlsVisible { hideTask?.cancel(); controlsVisible = false } else { poke() }
    }

    /// Show the controls and hide them again after a few seconds of playback.
    func poke() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, let self, self.video?.playing == true else { return }
            self.controlsVisible = false
        }
    }

    func flash(_ text: String) { show(text, nil) }

    /// Brightness or volume while dragging: a filled bar instead of text. `value` is 0 to 1.
    func flash(level: HUDLevel) { show(nil, level) }

    private func show(_ text: String?, _ level: HUDLevel?) {
        hud = text
        hudLevel = level
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            if !Task.isCancelled { self?.hud = nil; self?.hudLevel = nil }
        }
    }

    var screen: UIScreen { webView.window?.windowScene?.screen ?? UIScreen.main }

    private func rotate(_ mask: UIInterfaceOrientationMask) {
        guard let scene = webView.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] e in
            Task { @MainActor in self?.detector.note("rotate failed: \(e.localizedDescription)") }
        }
    }
}

struct HUDLevel: Equatable {
    let symbol: String, label: String, value: Double
    /// Brightness sits on the left edge, volume on the right, matching the half of the screen being dragged.
    let leading: Bool
}

/// System volume through a hidden `MPVolumeView` slider.
/// FRAGILE WORKAROUND: Apple offers no API to set the volume. This finds the slider inside the
/// MPVolumeView's private view tree and moves it. It works only while the view is in a window and
/// can break with any iOS release (decisions.md: "check early" on iOS 26). If `slider` is nil the
/// gesture does nothing and says so in the HUD.
@MainActor
final class SystemVolume {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    init() { view.alpha = 0.01 } // not hidden: a hidden MPVolumeView stops responding
    var slider: UISlider? { view.subviews.compactMap { $0 as? UISlider }.first }
    var level: Double { Double(AVAudioSession.sharedInstance().outputVolume) }
    @discardableResult func set(_ v: Double) -> Bool {
        guard let s = slider else { return false }
        s.value = Float(v)
        return true
    }
}

// MARK: - Views

struct VideoModeView: View {
    @ObservedObject var mode: VideoMode
    @State private var scrub = 0.0
    @State private var scrubbing = false

    var body: some View {
        ZStack {
            GestureSurface(mode: mode)
            if mode.controlsVisible { controls }
            if let hud = mode.hud {
                Text(hud).font(.title3.monospacedDigit().bold()).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).allowsHitTesting(false)
            }
            if let l = mode.hudLevel { levelBar(l) }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: mode.video?.pos) { _, p in if !scrubbing { scrub = p ?? 0 } }
    }

    private var controls: some View {
        VStack {
            HStack {
                circleButton("chevron.backward", "Exit video mode") { mode.exit() }
                Spacer()
                circleButton(mode.video?.pip == true ? "pip.exit" : "pip.enter", "Picture in picture") { mode.togglePiP() }
            }
            Spacer()
            Button { mode.togglePlay() } label: {
                Image(systemName: mode.video?.playing == true ? "pause.fill" : "play.fill")
                    .font(.system(size: 34)).frame(width: 76, height: 76)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(mode.video?.playing == true ? "Pause" : "Play")
            Spacer()
            scrubber
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var scrubber: some View {
        if mode.canSeek {
            HStack {
                Text(VideoGestures.clock(scrubbing ? scrub : mode.position)).monospacedDigit()
                Slider(value: $scrub, in: 0...max(mode.duration, 1)) { editing in
                    scrubbing = editing
                    if editing { mode.poke() } else { mode.seek(to: scrub) }
                }
                Text(VideoGestures.clock(mode.duration)).monospacedDigit()
            }
            .font(.footnote)
        } else if mode.video?.live == true {
            Text("LIVE").font(.footnote.bold())
        }
    }

    private func levelBar(_ l: HUDLevel) -> some View {
        VStack(spacing: 10) {
            Image(systemName: l.symbol).font(.title3)
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(height: 120 * min(max(l.value, 0), 1))
            }
            .frame(width: 6, height: 120)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l.label)
        .accessibilityValue("\(Int(l.value * 100)) percent")
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: l.leading ? .leading : .trailing)
        .allowsHitTesting(false)
    }

    private func circleButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

/// Catches every touch over the page: tap toggles controls, double-tap seeks 10 s, long-press plays at 2×,
/// horizontal drag seeks, vertical drag changes brightness (left half) or volume (right half).
struct GestureSurface: UIViewRepresentable {
    let mode: VideoMode
    func makeUIView(context: Context) -> SurfaceView { SurfaceView(mode: mode) }
    func updateUIView(_ v: SurfaceView, context: Context) {}
}

@MainActor
final class SurfaceView: UIView {
    private let mode: VideoMode
    private var axis: VideoGestures.Axis?
    private var startPos = 0.0, startLevel = 0.0
    private var onLeft = true
    private var seekTarget: Double?

    init(mode: VideoMode) {
        self.mode = mode
        super.init(frame: .zero)
        backgroundColor = .clear
        addSubview(mode.volume.view)
        let single = UITapGestureRecognizer(target: self, action: #selector(tap))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.maximumNumberOfTouches = 1
        [single, double, press, pan].forEach(addGestureRecognizer)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap() { mode.toggleControls() }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        mode.seek(by: VideoGestures.doubleTapDelta(x: g.location(in: self).x, width: bounds.width))
    }

    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { mode.boost(true) }
        else if g.state == .ended || g.state == .cancelled || g.state == .failed { mode.boost(false) }
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            axis = nil
            seekTarget = nil
            startPos = mode.position
            onLeft = g.location(in: self).x - t.x < bounds.midX
            startLevel = onLeft ? Double(mode.screen.brightness) : mode.volume.level
        case .changed:
            if axis == nil { axis = VideoGestures.axis(dx: t.x, dy: t.y) }
            switch axis {
            case .horizontal where mode.canSeek:
                let to = VideoGestures.seekTarget(start: startPos, duration: mode.duration, dx: t.x, width: bounds.width)
                seekTarget = to
                mode.flash("\(VideoGestures.clock(to)) / \(VideoGestures.clock(mode.duration))")
            case .vertical:
                let v = VideoGestures.level(start: startLevel, dy: t.y, height: bounds.height)
                if onLeft {
                    mode.screen.brightness = CGFloat(v)
                    mode.flash(level: HUDLevel(symbol: "sun.max.fill", label: "Brightness", value: v, leading: true))
                } else if mode.volume.set(v) {
                    mode.flash(level: HUDLevel(symbol: "speaker.wave.2.fill", label: "Volume", value: v, leading: false))
                } else {
                    mode.flash("Volume control unavailable")
                }
            default: break
            }
        case .ended:
            if let to = seekTarget { mode.seek(to: to) } // commit once, not on every move
            seekTarget = nil
        default: seekTarget = nil
        }
    }
}
