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
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        VStack(spacing: 0) {
            if !videoMode.active { addressBar }
            ZStack {
                WebViewHost(webView: model.webView)
                if videoMode.active { VideoModeView(mode: videoMode) }
                else if let f = model.failure { errorView(f.message) }
                else if showSites || (model.url == nil && !model.isLoading) { startView }
                else if detector.button == .enabled { videoButton }
            }
            banner
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
        .overlay { SpotifyOverlay(player: model.spotify, catalog: model.spotify.catalog, show: $model.showSpotify) }
        .sheet(isPresented: $showSettings) { SettingsView(model: model, blocker: blocker, detector: detector) }
        .onChange(of: model.url) { _, new in if !editing { text = new?.absoluteString ?? "" } }
        // Any navigation (site tile, address bar, deep link, clipboard) leaves the Sites page.
        .onChange(of: model.isLoading) { _, loading in if loading { showSites = false } }
        .onChange(of: editing) { _, now in if !now { text = model.url?.absoluteString ?? "" } }
        .onChange(of: scenePhase) { _, p in
            detector.note("app \(p)")
            if p != .active { watch.flush() }
            // Issue #23. Not .inactive: Control Center and alerts pass through it. On return, the page may have been paused
            // from the lock screen after the background check; with the overlay open the user is looking at it, so leave it.
            if p == .background || (p == .active && !model.showSpotify) { model.spotify.releaseIfPaused(p == .background ? "background" : "foreground") }
            if p == .active { checkClipboard(); Task { await blocker.refreshIfStale() } }
        }
        .onAppear { checkClipboard() }
        .task { await blocker.start() }
    }

    private let bar = AnyTransition.opacity.combined(with: .move(edge: .bottom))

    /// Icon-only toolbar button: 44 pt hit area (Apple's minimum) and a VoiceOver name.
    /// Primary colour; only the shield takes the accent, so it reads as the one stateful control.
    private func tool(_ symbol: String, _ label: String, tint: Color = .primary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: Theme.hit, minHeight: Theme.hit) }
            .tint(tint)
            .accessibilityLabel(label)
    }

    /// At most one banner at a time. Priority: popup, toast, clipboard, resume (docs/design-baseline.md).
    @ViewBuilder private var banner: some View {
        if videoMode.active {
            EmptyView()
        } else if model.blockedPopup != nil {
            Banner(icon: "xmark.rectangle", text: "Blocked a popup", buttonTitle: "Open",
                   buttonAction: { model.openBlockedPopup() }, dismiss: { model.blockedPopup = nil }).transition(bar)
        } else if let t = model.toast {
            Banner(icon: "checkmark.circle", text: t).transition(bar)
        } else if clipboardOffer {
            Banner(icon: "doc.on.clipboard", text: "Link on clipboard", buttonTitle: "Open",
                   buttonAction: { openClipboard() }, dismiss: { dismissClipboard() }).transition(bar)
        } else if watch.resumeOffer != nil {
            Banner(icon: "play.circle", text: "Resume where you left off", buttonTitle: "Resume",
                   buttonAction: { watch.enterVideoWhenReady() }, dismiss: { watch.resumeOffer = nil }).transition(bar)
        }
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
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: Theme.hit, minHeight: Theme.hit) }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear address")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .padding(.horizontal, Theme.gap).padding(.vertical, 8)
            ProgressView(value: model.progress)
                .opacity(model.isLoading ? 1 : 0)
                .scaleEffect(y: 0.5)
        }
    }

    private var toolbar: some View {
        let blocking = blocker.isBlocking(on: model.url)
        return HStack {
            tool("chevron.backward", "Back") { model.goBack() }.disabled(!model.canGoBack)
            Spacer()
            if model.isLoading {
                tool("xmark", "Stop loading") { model.stop() }
            } else {
                tool("arrow.clockwise", "Reload") { model.reload() }
                    .disabled(model.url == nil && model.failure == nil)
            }
            Spacer()
            tool(blocking ? "shield.lefthalf.filled" : "shield.slash",
                 blocking ? "Blocking on, turn off for this site" : "Blocking off, turn on for this site",
                 tint: blocking ? .accentColor : .secondary) {
                model.toggleBlocking()
            }
            .disabled(model.url == nil)
            Spacer()
            tool("square.grid.2x2", "Sites", tint: showSites ? .accentColor : .primary) { showSites.toggle() }
            Spacer()
            tool("books.vertical", "Library") { showLibrary = true }
            Spacer()
            moreMenu
        }
        .font(.title3)
        .padding(.horizontal, Theme.pad)
        .background(.bar)
    }

    /// Forward, Hide an element, Settings. Carries the warning when a filter update failed.
    private var moreMenu: some View {
        Menu {
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                .disabled(!model.canGoForward)
            Button { model.pickElement() } label: { Label("Hide an element…", systemImage: "eye.slash") }
                .disabled(model.url == nil || !blocker.isBlocking(on: model.url))
            Button { showSettings = true } label: {
                Label("Settings", systemImage: blocker.hasError ? "exclamationmark.triangle" : "gearshape")
            }
        } label: {
            Image(systemName: blocker.hasError ? "exclamationmark.triangle" : "ellipsis.circle")
                .frame(minWidth: Theme.hit, minHeight: Theme.hit)
        }
        .tint(blocker.hasError ? Color.orange : Color.primary)
        .accessibilityLabel(blocker.hasError ? "More, filter update failed" : "More")
    }

    /// Floating button: opens video mode on the primary video. Shown only when a controllable video exists,
    /// so the page stays a plain browser otherwise. Bottom left: sites keep their tab bars on the right.
    private var videoButton: some View {
        VStack {
            Spacer()
            HStack {
                Button { videoMode.enter() } label: {
                    Image(systemName: "play.rectangle.fill").font(.title2).frame(width: Theme.hit + 8, height: Theme.hit + 8)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Open video mode")
                Spacer()
            }
            .padding(Theme.pad)
        }
    }

    private var startView: some View {
        VStack(spacing: Theme.gap) {
            if vSize != .compact {
                BrandMark().padding(.top, Theme.pad)
                Text("Null View").font(.title2.weight(.semibold))
            }
            SitesGrid(model: model, onOpen: { showSites = false })
            Button("To open links from other apps, set up the Shortcut in Settings") { showSettings = true }
                .font(.footnote).multilineTextAlignment(.center)
                .padding(.horizontal, 32).padding(.bottom, Theme.gap)
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

    // MARK: Clipboard (backup path for the nullview:// Shortcut)

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
