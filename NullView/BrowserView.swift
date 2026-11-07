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
    @ObservedObject var watch: WatchState
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @FocusState private var editing: Bool
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var showSites = false
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
            if let u = watch.resumeOffer, !videoMode.active { resumeBar(u).transition(bar) }
            if clipboardOffer && !videoMode.active { clipboardBar.transition(bar) }
            if model.blockedPopup != nil && !videoMode.active { popupBar.transition(bar) }
            if let t = model.toast, !videoMode.active { toastBar(t).transition(bar) }
            if !videoMode.active { toolbar }
        }
        .animation(.easeInOut(duration: 0.2), value: clipboardOffer)
        .animation(.easeInOut(duration: 0.2), value: model.blockedPopup)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .animation(.easeInOut(duration: 0.2), value: watch.resumeOffer)
        .ignoresSafeArea(videoMode.active ? .all : [])
        .statusBarHidden(videoMode.active)
        .persistentSystemOverlays(videoMode.active ? .hidden : .automatic)
        .sheet(isPresented: $showLibrary) { LibraryView(model: model) }
        .sheet(isPresented: $showSites) { SitesSheet(model: model) }
        .overlay { SpotifyOverlay(player: model.spotify, show: $model.showSpotify) }
        .sheet(isPresented: $showSettings) { SettingsView(model: model, blocker: blocker, detector: detector) }
        .onChange(of: model.url) { _, new in if !editing { text = new?.absoluteString ?? "" } }
        .onChange(of: editing) { _, now in if !now { text = model.url?.absoluteString ?? "" } }
        .onChange(of: scenePhase) { _, p in
            detector.note("app \(p)")
            if p != .active { watch.flush() }
            if p == .active { checkClipboard(); Task { await blocker.refreshIfStale() } }
        }
        .onAppear { checkClipboard() }
        .task { await blocker.start() }
    }

    private let bar = AnyTransition.opacity.combined(with: .move(edge: .bottom))

    /// Icon-only toolbar button: 44 pt hit area (Apple's minimum) and a VoiceOver name.
    private func tool(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel(label)
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
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear address")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.vertical, 8)
            ProgressView(value: model.progress)
                .opacity(model.isLoading ? 1 : 0)
                .scaleEffect(y: 0.5)
        }
    }

    private var toolbar: some View {
        HStack {
            tool("chevron.backward", "Back") { model.goBack() }.disabled(!model.canGoBack)
            Spacer()
            tool("chevron.forward", "Forward") { model.goForward() }.disabled(!model.canGoForward)
            Spacer()
            if model.isLoading {
                tool("xmark", "Stop loading") { model.stop() }
            } else {
                tool("arrow.clockwise", "Reload") { model.reload() }
                    .disabled(model.url == nil && model.failure == nil)
            }
            Spacer()
            tool(blocker.isBlocking(on: model.url) ? "shield.lefthalf.filled" : "shield.slash",
                 blocker.isBlocking(on: model.url) ? "Blocking on, turn off for this site" : "Blocking off, turn on for this site") {
                model.toggleBlocking()
            }
            .disabled(model.url == nil)
            .contextMenu {
                Button { model.pickElement() } label: { Label("Hide an element…", systemImage: "eye.slash") }
                    .disabled(model.url == nil || !blocker.isBlocking(on: model.url))
            }
            Spacer()
            tool("square.grid.2x2", "Sites") { showSites = true }
            Spacer()
            tool("books.vertical", "Library") { showLibrary = true }
            Spacer()
            tool(blocker.hasError ? "exclamationmark.triangle" : "gearshape",
                 blocker.hasError ? "Settings, filter update failed" : "Settings") { showSettings = true }
        }
        .font(.title3)
        .padding(.horizontal, 16)
        .background(.bar)
    }

    /// Floating button: opens video mode on the primary video.
    /// Disabled when nothing is controllable (no source): the page stays a plain browser.
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
                .accessibilityLabel("Open video mode")
                .padding(16)
            }
        }
    }

    private var startView: some View {
        VStack(spacing: 0) {
            SitesGrid(model: model)
            Text("Add the sites you use most, then open them in one tap. To open links from other apps, set up the Shortcut described in Settings under Sharing.")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.horizontal, 32).padding(.vertical, 12)
        }
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

    private func resumeBar(_ u: URL) -> some View {
        HStack {
            Image(systemName: "play.circle")
            Text("Resume where you left off").font(.subheadline)
            Spacer()
            Button("Resume") { watch.enterVideoWhenReady() }.buttonStyle(.borderedProminent)
            Button { watch.resumeOffer = nil } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    private func toastBar(_ text: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle")
            Text(text).font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var popupBar: some View {
        HStack {
            Image(systemName: "xmark.rectangle")
            Text("Blocked a popup").font(.subheadline)
            Spacer()
            Button("Open") { model.openBlockedPopup() }.buttonStyle(.borderedProminent)
            Button { model.blockedPopup = nil } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Clipboard (backup path for the nullview:// Shortcut)

    private var clipboardBar: some View {
        HStack {
            Image(systemName: "doc.on.clipboard")
            Text("Link on clipboard").font(.subheadline)
            Spacer()
            Button("Open") { openClipboard() }.buttonStyle(.borderedProminent)
            Button { dismissClipboard() } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Dismiss")
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
