import NullViewCore
import SwiftUI
import WebKit

struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var blocker: Blocker
    @ObservedObject var detector: VideoDetector
    @ObservedObject var videoMode: VideoMode
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @FocusState private var editing: Bool
    @State private var showSettings = false
    /// Pasteboard change count we already offered or dismissed.
    @State private var handledPasteboard = UIPasteboard.general.changeCount
    @State private var clipboardOffer = false

    var body: some View {
        VStack(spacing: 0) {
            if !videoMode.active { addressBar }
            ZStack {
                WebViewHost(webView: model.webView)
                if videoMode.active { VideoModeView(mode: videoMode) }
                else if let f = model.failure { errorView(f.message) }
                else if model.url == nil && !model.isLoading { startView }
                else if detector.button != .hidden { videoButton }
            }
            if clipboardOffer && !videoMode.active { clipboardBar }
            if !videoMode.active { toolbar }
        }
        .ignoresSafeArea(videoMode.active ? .all : [])
        .statusBarHidden(videoMode.active)
        .persistentSystemOverlays(videoMode.active ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) { SettingsView(model: model, blocker: blocker, detector: detector) }
        .onChange(of: model.url) { _, new in if !editing { text = new?.absoluteString ?? "" } }
        .onChange(of: editing) { _, now in if !now { text = model.url?.absoluteString ?? "" } }
        .onChange(of: scenePhase) { _, p in if p == .active { checkClipboard() } }
        .onAppear { checkClipboard() }
        .task { await blocker.start() }
    }

    // MARK: Pieces

    private var addressBar: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search or enter address", text: $text)
                    .focused($editing)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { model.go(text); editing = false }
                if editing && !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.vertical, 8)
            ProgressView(value: model.progress)
                .opacity(model.isLoading ? 1 : 0)
                .scaleEffect(y: 0.5)
        }
    }

    private var toolbar: some View {
        HStack {
            Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack)
            Spacer()
            Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward)
            Spacer()
            if model.isLoading {
                Button { model.stop() } label: { Image(systemName: "xmark") }
            } else {
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.url == nil && model.failure == nil)
            }
            Spacer()
            Button { model.toggleBlocking() } label: {
                Image(systemName: blocker.isBlocking(on: model.url) ? "shield.lefthalf.filled" : "shield.slash")
            }
            .disabled(model.url == nil)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: blocker.hasError ? "exclamationmark.triangle" : "gearshape")
            }
        }
        .font(.title3)
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(.bar)
    }

    /// Floating button: opens video mode on the primary video.
    /// Disabled when nothing is controllable (DRM, no source): the page stays a plain browser.
    private var videoButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { videoMode.enter() } label: {
                    Image(systemName: "play.rectangle.fill").font(.title2).padding(14)
                        .background(.regularMaterial, in: Circle())
                }
                .disabled(detector.button != .enabled)
                .padding(16)
            }
        }
    }

    private var startView: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 44))
            Text("Enter an address or search").font(.headline)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 44))
            Text("Can't open page").font(.headline)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
            Button("Try again") { model.reload() }.buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: Clipboard (backup path for the nullview:// Shortcut)

    private var clipboardBar: some View {
        HStack {
            Image(systemName: "doc.on.clipboard")
            Text("Link on clipboard").font(.subheadline)
            Spacer()
            Button("Open") { openClipboard() }.buttonStyle(.borderedProminent)
            Button { dismissClipboard() } label: { Image(systemName: "xmark") }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    /// `hasURLs` does not trigger the iOS paste prompt; reading `.url` does, so only on tap.
    private func checkClipboard() {
        let pb = UIPasteboard.general
        clipboardOffer = pb.changeCount != handledPasteboard && pb.hasURLs
    }

    private func dismissClipboard() {
        handledPasteboard = UIPasteboard.general.changeCount
        clipboardOffer = false
    }

    private func openClipboard() {
        if let u = UIPasteboard.general.url, AddressInput.webURL(u.absoluteString) != nil { model.load(u) }
        dismissClipboard()
    }
}
