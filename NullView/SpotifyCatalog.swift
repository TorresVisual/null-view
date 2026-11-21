import Foundation
import NullViewCore

enum SpotifyPhase: Equatable {
    case idle
    case loading(String)
    case ready
    /// A required key was missing from Spotify's JSON: the native screens give way to Spotify's own page.
    case formatChanged(String)
    case failed(String)

    var isLoading: Bool { if case .loading = self { return true } else { return false } }
}

/// The native Spotify screens' data (issue #18): the album grid and one album's chapter list.
/// Passive on the wire: the hidden web player makes every request itself, `js/src/spotify-data.js` keeps the
/// JSON, and `Core`'s `SpotifyDecoder` reads it. We only open pages, scroll in steps and click the page's own
/// buttons. FRAGILE: operation names, response shapes and `data-testid`s are Spotify's private business; a
/// miss shows up as `formatChanged` or as a line in the in-app log.
@MainActor
final class SpotifyCatalog: ObservableObject {
    @Published private(set) var grid: SpotifyPhase = .idle
    @Published private(set) var albums: [SpotifyAlbum] = []
    @Published private(set) var album: SpotifyAlbum?
    @Published private(set) var detail: SpotifyPhase = .idle
    @Published private(set) var chapters: [SpotifyChapter] = []
    /// Set when the list is shorter than Spotify's own count, e.g. "Showing 50 of 54 chapters".
    @Published private(set) var detailNote = ""

    /// Why the native screens gave up, or nil. The overlay shows the web page and a banner while this is set.
    var formatProblem: String? {
        for p in [grid, detail] { if case .formatChanged(let why) = p { return why } }
        return nil
    }

    private unowned let player: SpotifyPlayer
    private var task: Task<Void, Never>?
    private var complete: [String: [SpotifyChapter]] = [:]   // chapter lists that reached their full count, by album id

    init(player: SpotifyPlayer) { self.player = player }

    // MARK: Album grid

    /// Opens the artist's discography in the hidden player and scrolls it until every album has been seen.
    func loadAlbums() {
        guard !grid.isLoading, grid != .ready else { return }
        task?.cancel()
        task = Task { await fetchAlbums() }
    }

    private func fetchAlbums() async {
        grid = .loading("Opening Spotify…")
        _ = await drain()
        await player.load(URL(string: "https://open.spotify.com/artist/\(SpotifyLink.artistID)/discography/all")!)
        var artist = SpotifyArtistPage()
        var stale = 0
        var lastScroll = ""
        for step in 0..<200 {
            let before = artist.albums.count
            do {
                for r in await drain() where r.op != "getAlbum" { artist.add(try SpotifyDecoder.discography(Data(r.text.utf8))) }
            } catch { return fail(&grid, error) }
            albums = artist.sorted
            // Stop only on Spotify's own count: the page list is virtualized, and "links stopped changing" lost 40 albums in the spike.
            if artist.isComplete { grid = .ready; return }
            stale = artist.albums.count == before ? stale + 1 : 0
            if step >= 10, artist.total == nil { return fail(&grid, SpotifyFormatError(missing: "discography totalCount")) }
            if stale >= 25 { grid = .failed("Got \(artist.albums.count) of \(artist.total ?? 0) albums (last scroll: \(lastScroll))."); return }
            grid = .loading(artist.total.map { "Loading albums \(artist.albums.count) of \($0)" } ?? "Loading albums…")
            lastScroll = await scrollStep("albums \(artist.albums.count)/\(artist.total ?? 0)")
            guard await pause(1.2) else { return }
        }
        grid = .failed("Got \(artist.albums.count) of \(artist.total ?? 0) albums.")
    }

    // MARK: Chapters

    func open(_ album: SpotifyAlbum) {
        self.album = album
        task?.cancel()
        detailNote = ""
        if let done = complete[album.id] { chapters = done; detail = .ready; return }
        chapters = []
        task = Task { await fetchChapters(album) }
    }

    /// Back to the grid. Playback keeps going: the web page is left where it is.
    func close() {
        task?.cancel()
        album = nil
        detail = .idle
    }

    /// Reloads whatever failed: the open album's chapters, or the grid.
    func retry() {
        task?.cancel()
        if let album { complete[album.id] = nil; open(album) } else { grid = .idle; loadAlbums() }
    }

    private static func url(_ album: SpotifyAlbum) -> URL { URL(string: "https://open.spotify.com/album/\(album.id)")! }

    private func fetchChapters(_ album: SpotifyAlbum) async {
        detail = .loading("Loading chapters…")
        _ = await drain()
        await player.load(Self.url(album))
        var list = SpotifyChapterList(expected: album.trackCount)
        var stale = 0
        for _ in 0..<80 {
            let before = list.chapters.count
            do {
                for r in await drain() where r.op == "getAlbum" { list.add(try SpotifyDecoder.album(Data(r.text.utf8))) }
            } catch { return fail(&detail, error) }
            chapters = list.chapters
            if list.isComplete, !chapters.isEmpty { break }
            stale = chapters.count == before ? stale + 1 : 0
            if stale >= 25 { break }
            // An album over 50 chapters: the page asks for the rest (offset 50) as its list is scrolled.
            if !chapters.isEmpty { detail = .loading("Loading chapters \(chapters.count) of \(list.expected)") }
            await scrollStep("chapters \(chapters.count)/\(list.expected)")
            guard await pause(1.2) else { return }
        }
        guard !chapters.isEmpty else { detail = .failed("Spotify sent no chapters for this album."); return }
        if list.isComplete { complete[album.id] = chapters } else { detailNote = "Showing \(chapters.count) of \(list.expected) chapters." }
        detail = .ready
    }

    // MARK: Play

    /// Plays one chapter by clicking its row on the album page (reloaded first if the page is elsewhere).
    func play(_ chapter: SpotifyChapter) {
        guard let album else { return }
        task?.cancel()
        task = Task {
            await showAlbumPage(album)
            for _ in 0..<40 {
                let r = await player.call("return window.__nvSpotify ? window.__nvSpotify.playChapter(uri, number) : 'no recorder'",
                                          ["uri": chapter.uri, "number": chapter.number])
                if r != "not rendered" { player.note("spotify chapter \(chapter.number) -> \(r)"); player.refresh(); return }
                await scrollStep("find chapter \(chapter.number)")   // the row of a long album may be scrolled out of the virtualized list
                guard await pause(0.6) else { return }
            }
            player.note("spotify chapter \(chapter.number) -> its row never showed up")
        }
    }

    /// The album's own play button: Spotify resumes where it left off, which suits audiobooks.
    func playAlbum() {
        guard let album else { return }
        task?.cancel()
        task = Task {
            await showAlbumPage(album)
            let r = await player.eval("window.__nvSpotify ? window.__nvSpotify.playAlbum() : 'no recorder'") as? String ?? "?"
            player.note("spotify album play -> \(r)")
            player.refresh()
        }
    }

    /// Browsing to another album reloads the page, which stops what is playing (accepted, decisions.md "Spotify").
    private func showAlbumPage(_ album: SpotifyAlbum) async {
        guard player.webView.url?.path.hasSuffix("/album/\(album.id)") != true else { return }
        await player.load(Self.url(album))
        _ = await pause(3)   // the rows render after the load
    }

    // MARK: Helpers

    private func drain() async -> [(op: String, text: String)] {
        let raw = await player.eval("window.__nvSpotify ? window.__nvSpotify.drain() : []") as? [[String: String]] ?? []
        return raw.compactMap { r in
            guard let op = r["op"], let text = r["text"] else { return nil }
            return (op, text)
        }
    }

    /// One scroll step; returns where the scroller is (see `scrollStep` in spotify-data.js) and logs it with the counts.
    @discardableResult
    private func scrollStep(_ what: String) async -> String {
        let r = await player.eval("window.__nvSpotify ? window.__nvSpotify.scrollStep() : 'no recorder'") as? String ?? "?"
        player.note("spotify \(what), \(r)")
        return r
    }

    /// False when the task was cancelled (back to the grid, another album).
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private func fail(_ phase: inout SpotifyPhase, _ error: Error) {
        let why = (error as? SpotifyFormatError).map { "missing \($0.missing)" } ?? "unreadable response"
        player.note("spotify format changed: \(why)")
        phase = .formatChanged(why)
        player.showPage = true
    }
}
