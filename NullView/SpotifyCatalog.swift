import Combine
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
    @Published private(set) var albums: [SpotifyAlbum] = [] { didSet { shelves = SpotifyShelves(albums) } }
    @Published private(set) var shelves = SpotifyShelves([])
    @Published private(set) var albumTotal: Int?
    /// Which of the two grid lists is showing, and whether listened ones are hidden (issue #19). Kept here, not in
    /// the grid view, which is rebuilt every time an album is closed.
    @Published var shelf = Shelf.folgen
    @Published var hideListened = UserDefaults.standard.bool(forKey: "spotifyHideListened") {
        didSet { UserDefaults.standard.set(hideListened, forKey: "spotifyHideListened") }
    }
    /// Flips the picked list (Folgen then run from the latest down to 1). Remembered across launches.
    @Published var reversed = UserDefaults.standard.bool(forKey: "spotifyReversed") {
        didSet { UserDefaults.standard.set(reversed, forKey: "spotifyReversed") }
    }
    /// Album ids the user has heard: ticked by hand, or by the last chapter becoming the current track.
    @Published private(set) var listened: Set<String>

    enum Shelf: String, CaseIterable, Identifiable {
        case folgen = "Folgen", specials = "Specials"
        var id: String { rawValue }
    }
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
    private var artist = SpotifyArtistPage()   // everything read so far; the grid shows it newest first
    private var complete: [String: [SpotifyChapter]] = [:]   // chapter lists that reached their full count, by album id

    private var nowPlaying: SpotifyAlbum?   // the album last played from here; its last chapter marks it listened
    /// Play tasks still running (a cancelled one counts until it unwinds). With a fetch under way it means the page
    /// is in use, so the player does not release it (issue #23).
    private var working = 0
    var isBusy: Bool { working > 0 || grid.isLoading || detail.isLoading }
    private var titleWatch: AnyCancellable?

    init(player: SpotifyPlayer) {
        self.player = player
        listened = player.listened.listened()
        titleWatch = player.$title.removeDuplicates().sink { [weak self] title in
            MainActor.assumeIsolated { self?.trackChanged(title) }
        }
    }

    // MARK: Listened (issue #19)

    func isListened(_ album: SpotifyAlbum) -> Bool { listened.contains(album.id) }

    func setListened(_ album: SpotifyAlbum, _ on: Bool) {
        if on { listened.insert(album.id) } else { listened.remove(album.id) }
        player.listened.setListened(album.id, on)
    }

    /// The albums in the picked list. Not a stored copy: it follows `shelves`, `listened` and the toggle.
    var shown: [SpotifyAlbum] {
        let list = (shelf == .folgen ? shelves.folgen : shelves.specials).filter { !hideListened || !listened.contains($0.id) }
        return reversed ? list.reversed() : list
    }

    /// The cover of the album the player says it is playing, for the player capsule (issue #22): matched by name among
    /// the albums read so far. nil when unknown (the player only reports a title string), and the capsule shows a plain tile.
    func cover(forAlbum name: String?) -> URL? {
        guard let name else { return nil }
        return albums.first { $0.shortTitle == name }?.coverURL
    }

    /// Fires on a change of the player's title only, so unticking while the last chapter still plays sticks.
    /// Only albums whose full chapter list was read can be judged (a partial list has the wrong "last").
    private func trackChanged(_ title: String) {
        guard let album = nowPlaying, !listened.contains(album.id), let chapters = complete[album.id],
              SpotifyListened.endsAlbum(title: title, chapters: chapters) else { return }
        player.note("spotify listened: \(album.name)")
        setListened(album, true)
    }

    // MARK: Album grid

    private static let discographyURL = URL(string: "https://open.spotify.com/artist/\(SpotifyLink.artistID)/discography/all")!
    /// The page loads this many albums by itself (7 pages of 20); the rest only when the grid is scrolled to them.
    private var reloadNext = false   // set when the page stalled: the next attempt (Retry) starts from a fresh page
    private var onDiscography: Bool { player.webView.url?.path.contains("/discography") == true }

    /// First load: opens the discography in the hidden player and lets it settle. Does not scroll.
    func loadAlbums() {
        guard !grid.isLoading, grid != .ready else { return }
        task?.cancel()
        task = Task { await fetchAlbums() }
    }

    /// Positions the hidden page at the next unread albums. The grid calls it whenever it is showing and not
    /// complete, so all of them load (issue #19): the Folgen list starts at Folge 1, the oldest album, which
    /// Spotify lists last. Not while audio plays: moving the hidden page to the discography reloads it and would
    /// stop the album (decisions.md "Spotify"); it resumes the next time the grid appears with nothing playing.
    func loadMore() {
        guard album == nil, grid == .ready, !player.playing, !artist.albums.isEmpty, !artist.isComplete else { return }
        task?.cancel()
        task = Task { await fetchAlbums() }
    }

    private func fetchAlbums() async {
        let first = artist.albums.isEmpty
        grid = .loading(first ? "Opening Spotify…" : "Loading more albums…")
        _ = await drain()
        let reloaded = first || !onDiscography || reloadNext
        // Build marker and state, so a stalled run can be told apart from the log (issue #19, loading stalls).
        player.note("spotify albums fetch v2: have \(artist.albums.count)/\(artist.total ?? 0), first=\(first) reload=\(reloaded) hide=\(hideListened) reverse=\(reversed) \(shelf.rawValue) on=\(onDiscography)")
        reloadNext = false
        if reloaded { await player.load(Self.discographyURL) }
        let start = artist.albums.count
        var stale = 0, quiet = 0, lastScroll = ""
        var settled = !reloaded   // a page we did not just load already delivered its first batch
        for step in 0..<40 {
            let before = artist.albums.count
            var got = 0
            do {
                for r in await drain() where r.op != "getAlbum" { artist.add(try SpotifyDecoder.discography(Data(r.text.utf8))); got += 1 }
            } catch { return fail(&grid, error) }
            albums = artist.sorted
            albumTotal = artist.total
            if artist.isComplete { grid = .ready; return }
            // `quiet`: steps since the page last sent anything. A freshly loaded page delivers its first batch (about 140)
            // in bursts with pauses; moving it before it is quiet left it stuck at 60 of 313 (found on the phone, #19).
            quiet = got == 0 ? quiet + 1 : 0
            if quiet >= 6, !settled { settled = true; player.note("spotify albums page quiet at \(artist.albums.count)/\(artist.total ?? 0), step \(step)") }   // latched: later bursts are the answer to our own scrolls
            if settled { stale = artist.albums.count == before ? stale + 1 : 0 }
            if step >= 12, artist.total == nil { return fail(&grid, SpotifyFormatError(missing: "discography totalCount")) }
            if first {
                // The first batch comes by itself; once the page is quiet, show it and carry on from there.
                if !artist.albums.isEmpty, artist.total != nil, quiet >= 6 { grid = .ready; return }
                if stale >= 25 { grid = .failed("Spotify sent no albums."); return }
            } else {
                // Not "links stopped changing" as the end: Spotify's own total decides completeness (isComplete).
                if !settled { guard await pause(1.0) else { return }; continue }
                if artist.albums.count - start >= 40 { grid = .ready; return }
                if stale >= 8 { reloadNext = true; grid = .failed("No more albums came back (\(artist.albums.count) of \(artist.total ?? 0); last scroll: \(lastScroll))."); return }
                // The unread albums sit at about count/total of the way down the page's list.
                // Every other attempt goes a little back up: the same scrollTop again fires no scroll event, and the
                // page only pages in on one (the log showed the same position seven times and no new albums).
                let f = Double(artist.albums.count) / Double(max(artist.total ?? 1, 1))
                lastScroll = await scrollTo(stale % 2 == 1 ? max(0, f - 0.05) : f, "albums \(artist.albums.count)/\(artist.total ?? 0)")
            }
            guard await pause(1.0) else { return }
        }
        if first && !artist.albums.isEmpty { grid = .ready; return }
        reloadNext = true
        grid = .failed("Stopped after \(artist.albums.count) of \(artist.total ?? 0) albums.")
    }

    // MARK: Chapters

    func open(_ album: SpotifyAlbum) {
        self.album = album
        task?.cancel()
        if grid.isLoading { grid = .ready }   // the fetch just got cancelled; scrolling the grid resumes it
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
            // Last rendered row to the bottom first, then past it: what pages in chapters 51 and up is Spotify's business
            // (the spike never saw it), so the log says which rows the page has.
            let rows = await player.eval("window.__nvSpotify ? window.__nvSpotify.revealLast() : 'no recorder'") as? String ?? "?"
            player.note("spotify chapters \(chapters.count)/\(list.expected), \(rows)")
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
        nowPlaying = album
        working += 1   // before the task starts, so a Done right after the tap already sees the page in use
        task = Task {
            defer { working -= 1 }
            await showAlbumPage(album)
            for _ in 0..<40 {
                let r = await player.call("return window.__nvSpotify ? window.__nvSpotify.playChapter(uri, number) : 'no recorder'",
                                          ["uri": chapter.uri, "number": chapter.number])
                if r != "not rendered" {
                    player.note("spotify chapter \(chapter.number) -> \(r)")
                    await watchEnd(album)
                    player.refresh()
                    return
                }
                await scrollStep("find chapter \(chapter.number)")   // the row of a long album may be scrolled out of the virtualized list
                guard await pause(0.6) else { return }
            }
            player.note("spotify chapter \(chapter.number) -> its row never showed up")
        }
    }

    /// The album's own play button: Spotify resumes where it left off, which suits audiobooks.
    func playAlbum() {
        guard let album else { return }
        startAlbum(album)
    }

    /// The capsule's play after the player released its page (issue #23): the album last played from here, or the
    /// page that was open when it was released, which then has its own play button.
    func resume() {
        if let nowPlaying { startAlbum(nowPlaying) } else { player.restore() }
    }

    private func startAlbum(_ album: SpotifyAlbum) {
        task?.cancel()
        nowPlaying = album
        working += 1
        task = Task {
            defer { working -= 1 }
            await showAlbumPage(album)
            let r = await player.eval("window.__nvSpotify ? window.__nvSpotify.playAlbum() : 'no recorder'") as? String ?? "?"
            player.note("spotify album play -> \(r)")
            await watchEnd(album)
            player.refresh()
        }
    }

    /// Issue #20: hands the page the album's chapter titles so it pauses when the current track is no longer one
    /// of them (Spotify's autoplay would otherwise carry on). The page does the watching, so it works with the
    /// screen locked; the pause is logged as "spotify stop: left album ..." when `refresh` next collects it. Only
    /// for a chapter list read in full: a partial one would stop playback at its own end.
    private func watchEnd(_ album: SpotifyAlbum) async {
        guard let list = complete[album.id] else {
            player.note("spotify stop: not armed for \(album.name), chapter list incomplete")
            return
        }
        let r = await player.call("return window.__nvSpotify ? window.__nvSpotify.watchAlbum(name, titles) : 'no recorder'",
                                  ["name": album.name, "titles": list.map(\.title)])
        player.note("spotify stop: \(r)")
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

    /// Puts the page's list at `f` of its range; returns where it ended up (and logs it).
    @discardableResult
    private func scrollTo(_ f: Double, _ what: String) async -> String {
        let r = await player.eval("window.__nvSpotify ? window.__nvSpotify.scrollTo(\(f)) : 'no recorder'") as? String ?? "?"
        player.note("spotify \(what), scrollTo \(String(format: "%.2f", f)): \(r)")
        return r
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
