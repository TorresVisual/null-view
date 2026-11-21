import XCTest
@testable import NullViewCore

/// How the native Spotify screens word titles (issue #22): shorter grid titles, chapter rows without the repeated
/// album name, and the player's combined title split into chapter and album.
final class SpotifyDisplayTests: XCTestCase {
    private func album(_ name: String, year: Int = 2023, tracks: Int = 12) -> SpotifyAlbum {
        SpotifyAlbum(id: name, uri: "spotify:album:" + name, name: name, year: year, releaseDate: "\(year)-01-01T00:00:00Z",
                     coverURL: URL(string: "https://i.scdn.co/x")!, trackCount: tracks)
    }

    func testGridTitleDropsTheFolgePrefixThatTheCoverAlreadyShows() {
        XCTAssertEqual(album("Folge 223: und der Knochenmann").shortTitle, "und der Knochenmann")
        XCTAssertEqual(album("208/Kelch des Schicksals").shortTitle, "Kelch des Schicksals")
        XCTAssertEqual(album("Folge 1: Der Super-Papagei").shortTitle, "Der Super-Papagei")
        XCTAssertEqual(album("Die drei ??? Adventskalender").shortTitle, "Die drei ??? Adventskalender", "a Special keeps its name")
        XCTAssertEqual(album("Folge 5").shortTitle, "Folge 5", "nothing left after the prefix: keep the whole name")
    }

    func testMetaLineIsNumberThenYear() {
        XCTAssertEqual(album("Folge 225: und der Puppenmacher", year: 2024).metaLine, "225 · 2024")
        XCTAssertEqual(album("Die drei ??? Adventskalender", year: 2019).metaLine, "2019", "a Special has no number")
    }

    private func chapter(_ title: String) -> SpotifyChapter {
        SpotifyChapter(uri: "spotify:track:" + title, number: 1, disc: 1, title: title, durationMs: 1000)
    }

    func testChapterRowDropsTheRepeatedAlbumName() {
        let a = album("Folge 223: und der Knochenmann")
        XCTAssertEqual(chapter("223 - und der Knochenmann - Teil 01").displayTitle(in: a), "Teil 01")
        XCTAssertEqual(chapter("und der Knochenmann - Teil 01").displayTitle(in: a), "Teil 01", "without the number")
        XCTAssertEqual(chapter("223 – und der Knochenmann – Inhaltsangabe").displayTitle(in: a), "Inhaltsangabe", "en dash")
        XCTAssertEqual(album("Die drei ??? Adventskalender").folge, nil)
        XCTAssertEqual(chapter("Die drei ??? Adventskalender - Tür 1").displayTitle(in: album("Die drei ??? Adventskalender")), "Tür 1", "a Special")
    }

    func testPlayerTitleSplitsIntoChapterAndAlbum() {
        let a = SpotifyNowPlaying("215 - und die verlorene Zeit - Inhaltsangabe")
        XCTAssertEqual(a.chapter, "Inhaltsangabe")
        XCTAssertEqual(a.album, "und die verlorene Zeit", "the leading Folge number is dropped")
        XCTAssertEqual(SpotifyNowPlaying("215 – und die verlorene Zeit – Teil 01").album, "und die verlorene Zeit", "en dash")
        XCTAssertEqual(SpotifyNowPlaying("215 - A - B - Teil 01").album, "A - B", "a dash inside the album name stays")
        XCTAssertEqual(SpotifyNowPlaying("Foo - Bar").chapter, "Bar")
        XCTAssertEqual(SpotifyNowPlaying("Foo - Bar").album, "Foo")
    }

    func testPlayerTitleWithoutAnAlbumPartIsJustTheChapter() {
        for t in ["Teil 01", "223 - Teil 01", ""] {
            XCTAssertNil(SpotifyNowPlaying(t).album, t)
        }
        XCTAssertEqual(SpotifyNowPlaying("Teil 01").chapter, "Teil 01")
        XCTAssertEqual(SpotifyNowPlaying("223 - Teil 01").chapter, "Teil 01")
        XCTAssertEqual(SpotifyNowPlaying("").chapter, "")
    }

    /// Issue #23: the page's `__nv.state()` string. An empty or broken one (no hook, page not loaded) is nil, which the
    /// release check reads as "not known to be paused", so the page is kept.
    func testPlayerStateReadsPlayingAndTitleAndRejectsAnythingElse() {
        let paused = SpotifyPlayerState(json: #"{"playing":false,"title":"Teil 01"}"#)
        XCTAssertEqual(paused?.playing, false)
        XCTAssertEqual(paused?.title, "Teil 01")
        XCTAssertEqual(SpotifyPlayerState(json: #"{"playing":true,"title":""}"#)?.playing, true)
        XCTAssertEqual(SpotifyPlayerState(json: #"{"playing":true}"#)?.title, "", "a missing title is empty")
        for bad in ["", "no hook", "[]", #"{"title":"x"}"#] {
            XCTAssertNil(SpotifyPlayerState(json: bad), bad)
        }
    }

    func testChapterTitleStaysWholeWhenItDoesNotStartWithTheAlbumName() {
        let a = album("Folge 223: und der Knochenmann")
        XCTAssertEqual(chapter("Teil 01").displayTitle(in: a), "Teil 01")
        XCTAssertEqual(chapter("224 - und die Totenmaske - Teil 01").displayTitle(in: a), "224 - und die Totenmaske - Teil 01", "another album's name")
        XCTAssertEqual(chapter("223 - und der Knochenmann").displayTitle(in: a), "223 - und der Knochenmann", "nothing left over")
        XCTAssertEqual(chapter("und der Knochenmannsgrab - Teil 01").displayTitle(in: a), "und der Knochenmannsgrab - Teil 01", "a longer word is not the name")
    }
}
