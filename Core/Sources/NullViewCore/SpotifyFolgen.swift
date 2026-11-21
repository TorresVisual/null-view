import Foundation

/// Folgen and Specials lists, and "listened" for the native Spotify grid (issue #19).

extension SpotifyAlbum {
    /// The Folge number from the title: "Folge 213: ..." or "111/Die Höhle des Grauens". nil = a Special.
    public var folge: Int? {
        var rest = Substring(name.trimmingCharacters(in: .whitespaces))
        let prefixed = rest.hasPrefix("Folge ")
        if prefixed { rest = rest.dropFirst(6) }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let n = Int(digits) else { return nil }
        // "Folge 5" ends there or goes on after a colon or space; a bare number only counts before a slash.
        let next = rest.dropFirst(digits.count).first
        return prefixed ? n : (next == "/" ? n : nil)
    }
}

/// The grid split in two: numbered Folgen ascending (one per number), and everything else.
public struct SpotifyShelves: Equatable {
    public let folgen: [SpotifyAlbum]
    public let specials: [SpotifyAlbum]   // in the order given

    /// A re-release shares its number with the original: the oldest release stands for the Folge.
    public init(_ albums: [SpotifyAlbum]) {
        var byNumber: [Int: SpotifyAlbum] = [:]
        var specials: [SpotifyAlbum] = []
        for a in albums {
            guard let n = a.folge else { specials.append(a); continue }
            if let old = byNumber[n], (old.releaseDate, old.id) <= (a.releaseDate, a.id) { continue }
            byNumber[n] = a
        }
        folgen = byNumber.sorted { $0.key < $1.key }.map(\.value)
        self.specials = specials
    }
}

/// Plain storage of album ids the user has listened to (`NullView/LibraryDB.swift` on device).
public protocol ListenedStore: AnyObject {
    func listened() -> Set<String>
    func setListened(_ albumID: String, _ on: Bool)
}

public final class MemoryListenedStore: ListenedStore {
    private var ids: Set<String> = []
    public init() {}
    public func listened() -> Set<String> { ids }
    public func setListened(_ albumID: String, _ on: Bool) {
        if on { ids.insert(albumID) } else { ids.remove(albumID) }
    }
}

public enum SpotifyListened {
    /// True when `title` (the player's current track) is the album's last chapter. A last title that another
    /// chapter shares cannot be told apart, so it never matches: a missed tick (untick/tick by hand) beats a wrong one.
    public static func endsAlbum(title: String, chapters: [SpotifyChapter]) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let last = chapters.last, !t.isEmpty, last.title.trimmingCharacters(in: .whitespaces) == t else { return false }
        return chapters.filter { $0.title == last.title }.count == 1
    }
}
