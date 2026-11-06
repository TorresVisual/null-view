import SwiftUI
import WebKit

struct WebHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

/// Phase 0 harness: one button per gate item. Throwaway UI.
struct SpikeView: View {
    @ObservedObject var spike: Spike

    var body: some View {
        VStack(spacing: 6) {
            WebHost(webView: spike.webView)
            ScrollView {
                Text(spike.log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 220)
            HStack {
                Button("1 Compile lists") { Task { await spike.installLists() } }
                Button("1+2 Block/cosmetic test") { Task { await spike.runPageTest() } }
            }
            HStack {
                Button("3+4 Video page") { spike.loadVideoPage() }
                Button("Clear log") { spike.log = "" }
            }
        }
        .buttonStyle(.bordered)
        .padding(6)
    }
}
