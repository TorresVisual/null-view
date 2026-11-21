import Foundation

/// Native Spotify screens (issue #18). Spotify's web player loads its data as private JSON; the app records the
/// responses and this file decodes them. Key names and paths come from the #17 spike log and can change without
/// notice, so every field is optional on the wire and a missing required one becomes `SpotifyFormatError`.

public struct SpotifyAlbum: Equatable, Hashable, Identifiable {
    public let id: String
    public let uri: String
    public let name: String
    public let year: Int
    public let releaseDate: String   // ISO string, sorts as text
    public let coverURL: URL         // the 300 px source
    public let trackCount: Int
}

public struct SpotifyChapter: Equatable, Identifiable {
    public var id: String { uri }
    public let uri: String
    public let number: Int
    public let disc: Int
    public let title: String
    public let durationMs: Int

    /// "1:35", or "1:02:05" from an hour up.
    public var durationText: String {
        let s = durationMs / 1000
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Which screen a `spotify.com` link opens: the native album grid, or Spotify's own page (the fallback view).
public enum SpotifyLink {
    public enum Destination: Equatable { case grid, page }

    /// Die drei ???, hard-coded (issue #18).
    public static let artistID = "3meJIgRw7YleJrmbpbJK6S"

    public static func destination(for url: URL) -> Destination {
        var parts = url.pathComponents.filter { $0 != "/" }
        if parts.first?.hasPrefix("intl-") == true { parts.removeFirst() }   // open.spotify.com/intl-de/...
        return parts.isEmpty || (parts.count >= 2 && parts[0] == "artist" && parts[1] == artistID) ? .grid : .page
    }
}

/// "Spotify changed its format": `missing` is the path of the first required key that was not there.
public struct SpotifyFormatError: Error, Equatable {
    public let missing: String
    public init(missing: String) { self.missing = missing }
}

public struct SpotifyDiscographyPage: Equatable {
    public let albums: [SpotifyAlbum]
    public let total: Int?
}

public struct SpotifyAlbumPage: Equatable {
    public let chapters: [SpotifyChapter]   // by disc, then track number
    public let total: Int?
}

/// Albums collected while the hidden player scrolls the artist's discography. Complete only when the count
/// reaches Spotify's own total: the list is virtualized, and a jump skipped offsets 140 to 180 in the spike.
public struct SpotifyArtistPage: Equatable {
    public private(set) var albums: [String: SpotifyAlbum] = [:]
    public private(set) var total: Int?
    public init() {}

    public mutating func add(_ page: SpotifyDiscographyPage) {
        for a in page.albums { albums[a.id] = a }
        if let t = page.total { total = t }   // an overview has a total and no items; a page without a total keeps it
    }

    public var isComplete: Bool { total.map { albums.count >= $0 } ?? false }
    public var missing: Int { max(0, (total ?? 0) - albums.count) }

    /// Newest first (Spotify's own order), then by name.
    public var sorted: [SpotifyAlbum] {
        albums.values.sorted { $0.releaseDate != $1.releaseDate ? $0.releaseDate > $1.releaseDate : $0.name < $1.name }
    }
}

/// One album's chapters. `expected` is the grid's track count; a response's own total wins once seen.
public struct SpotifyChapterList: Equatable {
    private var byUri: [String: SpotifyChapter] = [:]
    public private(set) var expected: Int
    public init(expected: Int) { self.expected = expected }

    public mutating func add(_ page: SpotifyAlbumPage) {
        for c in page.chapters { byUri[c.uri] = c }
        if let t = page.total { expected = t }
    }

    public var chapters: [SpotifyChapter] { byUri.values.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) } }
    public var isComplete: Bool { byUri.count >= expected }
}

public enum SpotifyDecoder {
    private struct AlbumRoot: Decodable { let data: AlbumData? }
    private struct AlbumData: Decodable { let albumUnion: AlbumUnion? }
    private struct AlbumUnion: Decodable { let tracksV2: TracksV2? }
    private struct TracksV2: Decodable { let totalCount: Int?; let items: [TrackItem]? }
    private struct TrackItem: Decodable { let track: Track? }
    private struct Track: Decodable {
        let uri: String?, name: String?, trackNumber: Int?, discNumber: Int?
        let duration: Duration?
    }
    private struct Duration: Decodable { let totalMilliseconds: Int? }

    private struct Root: Decodable { let data: Data? }
    private struct Data: Decodable { let artistUnion: Artist? }
    private struct Artist: Decodable { let discography: Discography? }
    private struct Discography: Decodable { let all: All? }
    private struct All: Decodable { let totalCount: Int?; let items: [Group]? }
    private struct Group: Decodable { let releases: Releases? }
    private struct Releases: Decodable { let items: [Release]? }
    private struct Release: Decodable {
        let id: String?, uri: String?, name: String?
        let date: DateInfo?
        let coverArt: Cover?
        let tracks: Tracks?
    }
    private struct DateInfo: Decodable { let year: Int?; let isoString: String? }
    private struct Cover: Decodable { let sources: [Source]? }
    private struct Source: Decodable { let url: String?; let width: Int? }
    private struct Tracks: Decodable { let totalCount: Int? }

    private static func need<T>(_ v: T?, _ path: String) throws -> T {
        guard let v else { throw SpotifyFormatError(missing: path) }
        return v
    }

    /// `queryArtistDiscographyAll` (one page of albums) and `queryArtistDiscographyOverview` (the total) share
    /// `data.artistUnion.discography.all`; the overview has no items.
    public static func discography(_ json: Foundation.Data) throws -> SpotifyDiscographyPage {
        let root = try JSONDecoder().decode(Root.self, from: json)
        let all = try need(root.data?.artistUnion?.discography?.all, "data.artistUnion.discography.all")
        let releases = (all.items ?? []).flatMap { $0.releases?.items ?? [] }
        return SpotifyDiscographyPage(albums: try releases.map(makeAlbum), total: all.totalCount)
    }

    private static func makeAlbum(_ r: Release) throws -> SpotifyAlbum {
        let p = "releases.items[]."
        let sources = try need(r.coverArt?.sources, p + "coverArt.sources").compactMap { s in
            s.url.flatMap(URL.init(string:)).map { ($0, s.width ?? 0) }
        }
        // Smallest source of at least 300 px, else the largest there is.
        guard let cover = sources.filter({ $0.1 >= 300 }).min(by: { $0.1 < $1.1 }) ?? sources.max(by: { $0.1 < $1.1 }) else {
            throw SpotifyFormatError(missing: p + "coverArt.sources[].url")
        }
        let iso = try need(r.date?.isoString, p + "date.isoString")
        return SpotifyAlbum(
            id: try need(r.id, p + "id"), uri: try need(r.uri, p + "uri"), name: try need(r.name, p + "name"),
            year: r.date?.year ?? Int(iso.prefix(4)) ?? 0, releaseDate: iso, coverURL: cover.0,
            trackCount: try need(r.tracks?.totalCount, p + "tracks.totalCount"))
    }

    /// `getAlbum`: up to 50 chapters per response; the rest come in a second response (offset 50).
    public static func album(_ json: Foundation.Data) throws -> SpotifyAlbumPage {
        let root = try JSONDecoder().decode(AlbumRoot.self, from: json)
        let tracks = try need(root.data?.albumUnion?.tracksV2, "data.albumUnion.tracksV2")
        let p = "tracksV2.items[].track."
        let chapters = try need(tracks.items, "data.albumUnion.tracksV2.items").map { item -> SpotifyChapter in
            let t = try need(item.track, "tracksV2.items[].track")
            return SpotifyChapter(
                uri: try need(t.uri, p + "uri"), number: try need(t.trackNumber, p + "trackNumber"),
                disc: t.discNumber ?? 1, title: try need(t.name, p + "name"),
                durationMs: try need(t.duration?.totalMilliseconds, p + "duration.totalMilliseconds"))
        }
        return SpotifyAlbumPage(chapters: chapters.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }, total: tracks.totalCount)
    }
}
