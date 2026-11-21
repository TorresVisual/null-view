import SwiftUI
import NullViewCore

/// The native Spotify screens (issue #18): album grid, then one album's chapters. Shown over the hidden
/// web player by `SpotifyOverlay`, which keeps the page itself as the fallback view.
struct SpotifyScreens: View {
    @ObservedObject var catalog: SpotifyCatalog

    var body: some View {
        Group {
            if let album = catalog.album { ChapterListView(catalog: catalog, album: album) } else { AlbumGridView(catalog: catalog) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .environment(\.colorScheme, .dark)
    }
}

private struct AlbumGridView: View {
    @ObservedObject var catalog: SpotifyCatalog
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: Theme.gap)]

    var body: some View {
        VStack(spacing: 0) {
            status
            if catalog.albums.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Theme.gap) {
                        ForEach(catalog.albums) { album in
                            Button { catalog.open(album) } label: { tile(album) }
                                .buttonStyle(.plain)
                                .disabled(catalog.grid.isLoading)   // the fetch owns the hidden page until it is done
                                .accessibilityLabel("\(album.name), \(album.year)")
                        }
                    }
                    .padding(Theme.pad)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch catalog.grid {
        case .loading(let text):
            HStack(spacing: Theme.gap) { ProgressView(); Text(text).font(.subheadline) }
                .frame(maxWidth: .infinity, minHeight: Theme.hit).background(.bar)
        case .failed(let text):
            Banner(icon: "exclamationmark.triangle", text: text, buttonTitle: "Retry", buttonAction: { catalog.retry() })
        case .idle, .ready, .formatChanged:
            EmptyView()
        }
    }

    private func tile(_ album: SpotifyAlbum) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Cover(url: album.coverURL)
            Text(album.name).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
            Text(String(album.year)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct Cover: View {
    let url: URL
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFit()
            case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
            default: ProgressView()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .accessibilityHidden(true)
    }
}

private struct ChapterListView: View {
    @ObservedObject var catalog: SpotifyCatalog
    let album: SpotifyAlbum

    var body: some View {
        List {
            HStack(spacing: Theme.gap) {
                Cover(url: album.coverURL).frame(width: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.name).font(.headline)
                    Text(String(album.year)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)

            Button { catalog.playAlbum() } label: {
                Label("Play, or resume where you left off", systemImage: "play.fill").frame(minHeight: Theme.hit)
            }
            .listRowBackground(Color.clear)

            switch catalog.detail {
            case .loading(let text):
                HStack(spacing: Theme.gap) { ProgressView(); Text(text).font(.subheadline) }.listRowBackground(Color.clear)
            case .failed(let text):
                Banner(icon: "exclamationmark.triangle", text: text, buttonTitle: "Retry", buttonAction: { catalog.retry() }).listRowBackground(Color.clear)
            case .idle, .ready, .formatChanged:
                EmptyView()
            }

            ForEach(catalog.chapters) { chapter in
                Button { catalog.play(chapter) } label: {
                    HStack(spacing: Theme.gap) {
                        Text(String(chapter.number)).monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                        Text(chapter.title).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Text(chapter.durationText).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(minHeight: Theme.hit)
                }
                .listRowBackground(Color.clear)
                .accessibilityLabel("Chapter \(chapter.number), \(chapter.title), \(chapter.durationText)")
            }

            if !catalog.detailNote.isEmpty {
                Text(catalog.detailNote).font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }
}
