import AVFoundation
import SwiftUI

@main
struct NullViewApp: App {
    @StateObject private var spike = Spike()

    init() {
        // Phase 0 gate 4: background audio needs a .playback session + UIBackgroundModes=audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            SpikeView(spike: spike)
                .onOpenURL { spike.handleOpen($0) } // gate 5: nullview://open?url=...
        }
    }
}
