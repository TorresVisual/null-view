import Foundation

/// How the native Spotify screens word titles (issue #22). Presentation only; the data layer is untouched.

extension SpotifyAlbum {
    /// The name without the "Folge 213:" or "111/" lead-in, which the cover and `metaLine` already show.
    /// A Special, or a name with nothing after the lead-in, keeps its whole name.
    public var shortTitle: String {
        guard folge != nil else { return name }
        var rest = Substring(name.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("Folge ") { rest = rest.dropFirst(6) }
        rest = rest.drop { $0.isASCII && $0.isNumber }
        rest = rest.drop { $0 == ":" || $0 == "/" || $0 == " " }
        return rest.isEmpty ? name : String(rest)
    }

    /// "225 · 2024" under a grid title; just the year for a Special.
    public var metaLine: String { folge.map { "\($0) · \(year)" } ?? String(year) }
}

private let dashes = [" - ", " – "]

private func dropDash(_ s: Substring) -> Substring? {
    dashes.first { s.hasPrefix($0) }.map { s.dropFirst($0.count) }
}

/// The player reports one string, "215 - und die verlorene Zeit - Inhaltsangabe". Split on the dashes: the last
/// part is the chapter, the rest (minus a leading Folge number) is the album. FRAGILE: a guess about how these
/// audiobooks are titled; anything else comes back as a chapter with no album, which the UI shows as it is.
public struct SpotifyNowPlaying: Equatable {
    public let chapter: String
    public let album: String?

    public init(_ title: String) {
        let parts = title.replacingOccurrences(of: " – ", with: " - ")
            .components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        chapter = parts.last ?? ""
        var album = parts.dropLast()
        if let first = album.first, !first.isEmpty, first.allSatisfy({ $0.isASCII && $0.isNumber }) { album = album.dropFirst() }
        self.album = album.isEmpty ? nil : album.joined(separator: " - ")
    }
}

extension SpotifyChapter {
    /// The title without the album's name in front, as Spotify lists these: "223 - und der Knochenmann - Teil 01"
    /// becomes "Teil 01". Only when the title starts with this album's name (and its number, if any) followed by a
    /// dash and something more; otherwise the whole title.
    public func displayTitle(in album: SpotifyAlbum) -> String {
        var rest = Substring(title)
        if let n = album.folge, rest.hasPrefix(String(n)), let after = dropDash(rest.dropFirst(String(n).count)) { rest = after }
        guard rest.hasPrefix(album.shortTitle), let tail = dropDash(rest.dropFirst(album.shortTitle.count)), !tail.isEmpty else { return title }
        return String(tail)
    }
}
