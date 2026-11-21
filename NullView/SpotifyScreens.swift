import SwiftUI
import NullViewCore

/// The native Spotify screens (issue #18): album grid, then one album's chapters. Shown over the hidden
/// web player by `SpotifyOverlay`, which keeps the page itself as the fallback view and floats the glass controls
/// (top buttons, player capsule) over these screens as safe-area insets, so the content scrolls under them (issue #22).
struct SpotifyScreens: View {
    @ObservedObject var catalog: SpotifyCatalog
    /// The player's current track title, passed as a value so the playing chapter's row follows it.
    let playingTitle: String

    var body: some View {
        Group {
            if let album = catalog.album { ChapterListView(catalog: catalog, album: album, playingTitle: playingTitle) } else { AlbumGridView(catalog: catalog) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .environment(\.colorScheme, .dark)
    }
}

private struct AlbumGridView: View {
    @ObservedObject var catalog: SpotifyCatalog
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: Theme.gap, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            status
            if catalog.albums.isEmpty {
                Spacer()
                if catalog.grid.isLoading { ProgressView().controlSize(.large) }
                Spacer()
            } else {
                // Pinned, not the scroll view's first row: there it rendered as nothing on the phone (issue #22).
                filters
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.pad) {
                        ForEach(catalog.shown) { album in
                            let heard = catalog.isListened(album)
                            Button { catalog.open(album) } label: { tile(album, heard: heard) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(album.name), \(album.year)" + (heard ? ", listened" : ""))
                                .contextMenu {
                                    Button { catalog.setListened(album, !heard) } label: {
                                        Label(heard ? "Mark as not listened" : "Mark as listened", systemImage: heard ? "circle" : "checkmark.circle")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, Theme.pad)
                }
            }
        }
        // All albums load by themselves: the Folgen list has to reach Folge 1, which Spotify lists last.
        .onAppear { catalog.loadMore() }
        .onChange(of: catalog.grid) { _, now in if now == .ready { catalog.loadMore() } }
    }

    private var filters: some View {
        VStack(spacing: 0) {
            Picker("List", selection: $catalog.shelf) {
                Text("Folgen \(catalog.shelves.folgen.count)").tag(SpotifyCatalog.Shelf.folgen)
                Text("Specials \(catalog.shelves.specials.count)").tag(SpotifyCatalog.Shelf.specials)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.pad)
            .padding(.vertical, Theme.gap)
            // Side by side, or stacked when the text size is too large for one line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.gap) { chips; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 0) { chips }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.pad)
        }
        // [DEBUG-f1] where the filter block ends up; remove once the phone log shows it laid out.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { catalog.debugLog("[DEBUG-f1] filters frame \($0) albums \(catalog.albums.count)") }
    }

    @ViewBuilder private var chips: some View {
        Chip(title: "Hide listened", on: $catalog.hideListened)
        // Folgen run oldest first and Specials newest first, so "reversed" means the opposite on each.
        Chip(title: catalog.shelf == .folgen ? "Newest first" : "Oldest first", on: $catalog.reversed)
    }

    @ViewBuilder private var status: some View {
        switch catalog.grid {
        case .loading(let text):
            HStack(spacing: Theme.gap) { ProgressView(); Text(text).font(.subheadline) }
                .frame(maxWidth: .infinity, minHeight: Theme.hit)
        case .failed(let text):
            Banner(icon: "exclamationmark.triangle", text: text, buttonTitle: "Retry", buttonAction: { catalog.retry() })
        case .idle, .ready, .formatChanged:
            EmptyView()
        }
    }

    /// Every title reserves two lines, so the covers of one row always start at the same height.
    private func tile(_ album: SpotifyAlbum, heard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Cover(url: album.coverURL)
                .overlay(alignment: .topTrailing) {
                    if heard {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Theme.ink)
                            .padding(Theme.gap / 2).background(Color.accentColor, in: Circle()).padding(Theme.gap / 2)
                    }
                }
            Text(album.shortTitle).font(.subheadline).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                .foregroundStyle(heard ? Theme.paperDim : Theme.paper)
            Text(album.metaLine).font(.caption).foregroundStyle(Theme.paperDim)
        }
    }
}

/// A toggle that reads as a pill: accent-filled when on, outlined when off. 44 pt tall to touch, slimmer to look at.
private struct Chip: View {
    let title: String
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            Text(title).font(.subheadline)
                .padding(.horizontal, Theme.gap).padding(.vertical, Theme.gap / 2)
                .foregroundStyle(on ? Theme.ink : Theme.paper)
                .background(on ? Color.accentColor : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.paper.opacity(0.3)))
                .frame(minHeight: Theme.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct Cover: View {
    let url: URL?
    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                    default: ProgressView()
                    }
                }
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)   // the player capsule, when the playing album is not known
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
    let playingTitle: String

    private var rowInsets: EdgeInsets { EdgeInsets(top: 0, leading: Theme.pad, bottom: 0, trailing: Theme.pad) }

    var body: some View {
        let nowPlaying = playingTitle.trimmingCharacters(in: .whitespaces)
        return List {
            header
            switch catalog.detail {
            case .loading(let text):
                HStack(spacing: Theme.gap) { ProgressView(); Text(text).font(.subheadline) }.plainRow(rowInsets)
            case .failed(let text):
                Banner(icon: "exclamationmark.triangle", text: text, buttonTitle: "Retry", buttonAction: { catalog.retry() }).plainRow(rowInsets)
            case .idle, .ready, .formatChanged:
                EmptyView()
            }

            ForEach(catalog.chapters) { chapter in
                let playing = chapter.title == nowPlaying
                let title = chapter.displayTitle(in: album)
                Button { catalog.play(chapter) } label: {
                    HStack(spacing: Theme.gap) {
                        Text(String(chapter.number)).monospacedDigit().frame(width: 32, alignment: .trailing)
                            .foregroundStyle(playing ? Color.accentColor : Theme.paperDim)
                        Text(title).lineLimit(2).multilineTextAlignment(.leading)
                            .foregroundStyle(playing ? Color.accentColor : Theme.paper)
                        Spacer(minLength: 0)
                        Text(chapter.durationText).monospacedDigit().foregroundStyle(Theme.paperDim)
                    }
                    .frame(minHeight: Theme.hit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(rowInsets)
                .accessibilityLabel("Chapter \(chapter.number), \(title), \(chapter.durationText)" + (playing ? ", playing" : ""))
            }

            if !catalog.detailNote.isEmpty {
                Text(catalog.detailNote).font(.footnote).foregroundStyle(Theme.paperDim).plainRow(rowInsets)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Big centred cover, name, year and chapter count, then Play and "listened".
    private var header: some View {
        let heard = catalog.isListened(album)
        return VStack(spacing: Theme.gap) {
            Cover(url: album.coverURL).frame(width: 190)
            VStack(spacing: 2) {
                Text(album.name).font(.title3.bold()).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                Text("\(album.year) · \(album.trackCount == 1 ? "1 chapter" : "\(album.trackCount) chapters")")
                    .font(.subheadline).foregroundStyle(Theme.paperDim)
            }
            HStack(spacing: Theme.gap) {
                Button { catalog.playAlbum() } label: {
                    Label("Play", systemImage: "play.fill").font(.headline).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: Theme.hit)
                }
                .buttonStyle(.glassProminent).tint(Color.accentColor)
                .accessibilityHint("Resumes where you left off")
                Button { catalog.setListened(album, !heard) } label: {
                    Image(systemName: heard ? "checkmark.circle.fill" : "checkmark")
                        .foregroundStyle(heard ? Color.accentColor : Theme.paper)
                        .frame(width: Theme.hit, height: Theme.hit)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .accessibilityLabel(heard ? "Listened. Tap to untick" : "Mark as listened")
            }
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.gap)
        .plainRow(rowInsets)
    }
}

private extension View {
    /// A list row that is not a chapter: no background, no separator.
    func plainRow(_ insets: EdgeInsets) -> some View {
        listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(insets)
    }
}
