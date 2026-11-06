import AVFoundation
import NullViewCore
import SwiftUI

@main
struct NullViewApp: App {
    @StateObject private var browser = BrowserModel()

    init() {
        // .playback lets video audio play with the silent switch on and in the background.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        // Phase 0 (where background audio passed) also activated the session up front; Phase 1 dropped that.
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            BrowserView(model: browser, blocker: browser.blocker, detector: browser.detector, videoMode: browser.videoMode, watch: browser.watch)
                .onOpenURL { if let u = DeepLink.parse($0) { browser.load(u) } }
        }
    }
}
