import AVFoundation
import NullViewCore
import SwiftUI

@main
struct NullViewApp: App {
    @StateObject private var browser = BrowserModel()

    init() {
        // .playback lets video audio play with the silent switch on and in the background.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        // Phase 0 (where background audio passed) activated the session up front; commit 1b7e8b0 put that back.
        // It may keep the app awake while locked (battery investigation), so Settings > Advanced can switch it off
        // (takes effect on the next launch). Default on = the old behaviour.
        if UserDefaults.standard.object(forKey: IdleProbe.activateKey) as? Bool ?? true {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    var body: some Scene {
        WindowGroup {
            BrowserView(model: browser, blocker: browser.blocker, detector: browser.detector, videoMode: browser.videoMode, watch: browser.watch)
                .onOpenURL { if let u = DeepLink.parse($0) { browser.load(u) } }
        }
    }
}
