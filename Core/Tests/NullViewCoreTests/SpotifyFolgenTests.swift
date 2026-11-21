import XCTest
@testable import NullViewCore

/// Folgen and Specials lists, and "listened" (issue #19). Titles are the forms seen in the #17/#18 spike.
final class SpotifyFolgenTests: XCTestCase {
    private func album(_ name: String, id: String? = nil, date: String = "2020-01-01T00:00:00Z") -> SpotifyAlbum {
        let id = id ?? name
        return SpotifyAlbum(id: id, uri: "spotify:album:" + id, name: name, year: Int(date.prefix(4))!, releaseDate: date,
                            coverURL: URL(string: "https://i.scdn.co/" + id)!, trackCount: 1)
    }

    func testFolgeNumberFromTheTitleForms() {
        XCTAssertEqual(album("Folge 213: Das Grab der Ahnen").folge, 213)
        XCTAssertEqual(album("Folge 1: Der Super-Papagei").folge, 1)
        XCTAssertEqual(album("111/Die Höhle des Grauens").folge, 111)
        XCTAssertEqual(album("  Folge 7: Mit Leerzeichen").folge, 7)
    }

    func testNoNumberMeansSpecial() {
        XCTAssertNil(album("Die drei ??? und die singende Schlange").folge)
        XCTAssertNil(album("Die drei ??? Adventskalender").folge)
        XCTAssertNil(album("Die drei ??? Box 1 (Folgen 1-3)").folge)
        XCTAssertNil(album("Folgen 1-3").folge)
        XCTAssertNil(album("3 Fragezeichen: Das Hörspiel").folge, "a leading number is a Folge only before a slash")
        XCTAssertNil(album("Folge: ohne Zahl").folge)
    }

    func testShelvesSplitSortAndDropReReleases() {
        let albums = [
            album("Folge 3: C", id: "c"),
            album("Die drei ??? Adventskalender", id: "adv"),
            album("1/A", id: "a"),
            album("Folge 2: B (Neuauflage)", id: "b2", date: "2022-01-01T00:00:00Z"),
            album("Folge 2: B", id: "b1", date: "2010-01-01T00:00:00Z"),
            album("Die drei ??? und die singende Schlange", id: "snake"),
        ]
        let s = SpotifyShelves(albums)
        XCTAssertEqual(s.folgen.map(\.id), ["a", "b1", "c"], "ascending, one per number, the oldest release stands for it")
        XCTAssertEqual(s.specials.map(\.id), ["adv", "snake"], "every unnumbered album, in the order given")
        XCTAssertEqual(s.folgen.count + s.specials.count, albums.count - 1, "counts add up to the total minus duplicates")
    }

    private func chapter(_ n: Int, _ title: String) -> SpotifyChapter {
        SpotifyChapter(uri: "spotify:track:\(n)", number: n, disc: 1, title: title, durationMs: 1000)
    }

    func testOnlyTheLastChapterEndsTheAlbum() {
        let cs = [chapter(1, "Teil 01"), chapter(2, "Teil 02"), chapter(3, "Teil 03")]
        XCTAssertTrue(SpotifyListened.endsAlbum(title: "Teil 03", chapters: cs))
        XCTAssertTrue(SpotifyListened.endsAlbum(title: " Teil 03 ", chapters: cs))
        XCTAssertFalse(SpotifyListened.endsAlbum(title: "Teil 02", chapters: cs))
        XCTAssertFalse(SpotifyListened.endsAlbum(title: "", chapters: cs))
        XCTAssertFalse(SpotifyListened.endsAlbum(title: "Teil 03", chapters: []))
    }

    func testARepeatedLastTitleCannotBeTold() {
        let cs = [chapter(1, "Hörspiel"), chapter(2, "Hörspiel")]
        XCTAssertFalse(SpotifyListened.endsAlbum(title: "Hörspiel", chapters: cs), "it would also fire on chapter 1")
    }

    func testMemoryStoreTicksAndUnticks() {
        let s = MemoryListenedStore()
        s.setListened("a", true); s.setListened("b", true); s.setListened("a", true)
        XCTAssertEqual(s.listened(), ["a", "b"])
        s.setListened("a", false)
        XCTAssertEqual(s.listened(), ["b"])
    }
}
