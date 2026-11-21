import XCTest
@testable import NullViewCore

/// Fixtures are trimmed to the shapes recorded in the #17 spike (paths and key names as logged).
final class SpotifyTests: XCTestCase {
    /// `queryArtistDiscographyAll`: one page, two groups of releases.
    static let discographyPage = """
    {"data":{"artistUnion":{"discography":{"all":{"totalCount":313,"items":[
      {"releases":{"items":[
        {"id":"7b9OiVsktCZyldiAnjkVDx","uri":"spotify:album:7b9OiVsktCZyldiAnjkVDx","name":"Folge 212: Das Grab der Ahnen",
         "date":{"year":2024,"isoString":"2024-03-15T00:00:00Z"},
         "coverArt":{"sources":[{"url":"https://i.scdn.co/image/c64","width":64,"height":64},{"url":"https://i.scdn.co/image/c300","width":300,"height":300},{"url":"https://i.scdn.co/image/c640","width":640,"height":640}]},
         "tracks":{"totalCount":40}}
      ]}},
      {"releases":{"items":[
        {"id":"1111111111111111111111","uri":"spotify:album:1111111111111111111111","name":"111/Die Höhle des Grauens",
         "date":{"year":1979,"isoString":"1979-01-01T00:00:00Z"},
         "coverArt":{"sources":[{"url":"https://i.scdn.co/image/d640","width":640,"height":640},{"url":"https://i.scdn.co/image/d64","width":64,"height":64}]},
         "tracks":{"totalCount":54}}
      ]}}
    ]}}}}}
    """

    func testDecodesAlbumsWithTheThreeHundredPixelCover() throws {
        let page = try SpotifyDecoder.discography(Data(Self.discographyPage.utf8))
        XCTAssertEqual(page.total, 313)
        XCTAssertEqual(page.albums.map(\.id), ["7b9OiVsktCZyldiAnjkVDx", "1111111111111111111111"])
        let a = page.albums[0]
        XCTAssertEqual(a.uri, "spotify:album:7b9OiVsktCZyldiAnjkVDx")
        XCTAssertEqual(a.name, "Folge 212: Das Grab der Ahnen")
        XCTAssertEqual(a.year, 2024)
        XCTAssertEqual(a.releaseDate, "2024-03-15T00:00:00Z")
        XCTAssertEqual(a.coverURL.absoluteString, "https://i.scdn.co/image/c300")
        XCTAssertEqual(a.trackCount, 40)
        XCTAssertEqual(page.albums[1].coverURL.absoluteString, "https://i.scdn.co/image/d640", "no 300 px: the next size up")
    }

    /// `queryArtistDiscographyOverview`: the total, no albums.
    func testOverviewCarriesOnlyTheTotal() throws {
        let page = try SpotifyDecoder.discography(Data(#"{"data":{"artistUnion":{"discography":{"all":{"totalCount":313}}}}}"#.utf8))
        XCTAssertEqual(page.total, 313)
        XCTAssertEqual(page.albums, [])
    }

    func testMissingRequiredKeyNamesThePath() {
        func missing(_ json: String) -> String? {
            do { _ = try SpotifyDecoder.discography(Data(json.utf8)); return nil }
            catch let e as SpotifyFormatError { return e.missing }
            catch { return "other: \(error)" }
        }
        XCTAssertEqual(missing(#"{"data":{"artistUnion":{"discography":{}}}}"#), "data.artistUnion.discography.all")
        XCTAssertEqual(missing(#"{"errors":[{"message":"PersistedQueryNotFound"}]}"#), "data.artistUnion.discography.all")
        XCTAssertEqual(missing(Self.discographyPage.replacingOccurrences(of: "\"coverArt\"", with: "\"cover\"")), "releases.items[].coverArt.sources")
        XCTAssertEqual(missing(Self.discographyPage.replacingOccurrences(of: "\"uri\"", with: "\"u\"")), "releases.items[].uri")
        XCTAssertNil(missing(Self.discographyPage))
    }

    /// `getAlbum`: the first 50 chapters of one album.
    static let albumPage = """
    {"data":{"albumUnion":{"name":"Folge 212","tracksV2":{"totalCount":3,"items":[
      {"track":{"uri":"spotify:track:bbbbbbbbbbbbbbbbbbbbbb","name":"Teil 02","trackNumber":2,"discNumber":1,"duration":{"totalMilliseconds":120500},"playability":{"playable":true},"playcount":"12"}},
      {"track":{"uri":"spotify:track:aaaaaaaaaaaaaaaaaaaaaa","name":"Teil 01","trackNumber":1,"discNumber":1,"duration":{"totalMilliseconds":95000},"playcount":"30"}},
      {"track":{"uri":"spotify:track:cccccccccccccccccccccc","name":"Teil 01 (Bonus)","trackNumber":1,"discNumber":2,"duration":{"totalMilliseconds":60000}}}
    ]}}}}
    """

    func testDecodesChaptersInDiscAndTrackOrder() throws {
        let page = try SpotifyDecoder.album(Data(Self.albumPage.utf8))
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.chapters.map(\.title), ["Teil 01", "Teil 02", "Teil 01 (Bonus)"])
        XCTAssertEqual(page.chapters[0], SpotifyChapter(uri: "spotify:track:aaaaaaaaaaaaaaaaaaaaaa", number: 1, disc: 1, title: "Teil 01", durationMs: 95000))
    }

    func testAlbumMissingTrackUriIsAFormatChange() {
        let json = Self.albumPage.replacingOccurrences(of: "\"uri\"", with: "\"u\"")
        XCTAssertThrowsError(try SpotifyDecoder.album(Data(json.utf8))) {
            XCTAssertEqual($0 as? SpotifyFormatError, SpotifyFormatError(missing: "tracksV2.items[].track.uri"))
        }
        XCTAssertThrowsError(try SpotifyDecoder.album(Data("{}".utf8))) {
            XCTAssertEqual($0 as? SpotifyFormatError, SpotifyFormatError(missing: "data.albumUnion.tracksV2"))
        }
    }

    // MARK: Collecting pages

    private func album(_ id: String, _ date: String, name: String = "x") -> SpotifyAlbum {
        SpotifyAlbum(id: id, uri: "spotify:album:" + id, name: name, year: Int(date.prefix(4))!, releaseDate: date,
                     coverURL: URL(string: "https://i.scdn.co/" + id)!, trackCount: 1)
    }

    func testArtistPageIsCompleteOnlyAtTheTotalNotWhenLinksStopGrowing() {
        var a = SpotifyArtistPage()
        XCTAssertFalse(a.isComplete, "no total yet")
        a.add(SpotifyDiscographyPage(albums: [album("a", "2020-01-01")], total: nil))
        a.add(SpotifyDiscographyPage(albums: [album("a", "2020-01-01"), album("c", "2022-01-01")], total: 3))
        XCTAssertEqual(a.albums.count, 2, "a repeated page adds nothing")
        XCTAssertFalse(a.isComplete)
        XCTAssertEqual(a.missing, 1)
        a.add(SpotifyDiscographyPage(albums: [album("b", "2021-01-01")], total: nil))
        XCTAssertTrue(a.isComplete, "an overview without items must not erase the total")
        a.add(SpotifyDiscographyPage(albums: [], total: nil))
        XCTAssertTrue(a.isComplete)
    }

    func testAlbumsAreSortedNewestFirstThenByName() {
        var a = SpotifyArtistPage()
        a.add(SpotifyDiscographyPage(albums: [album("1", "2020-01-01", name: "B"), album("2", "2022-05-01"), album("3", "2020-01-01", name: "A")], total: 3))
        XCTAssertEqual(a.sorted.map(\.id), ["2", "3", "1"])
    }

    private func chapter(_ n: Int) -> SpotifyChapter {
        SpotifyChapter(uri: "spotify:track:\(n)", number: n, disc: 1, title: "Teil \(n)", durationMs: 1000)
    }

    func testChaptersOverFiftyArriveInTwoResponses() {
        var c = SpotifyChapterList(expected: 54)
        c.add(SpotifyAlbumPage(chapters: (1...50).map(chapter), total: 54))
        XCTAssertFalse(c.isComplete)
        c.add(SpotifyAlbumPage(chapters: (51...54).map(chapter), total: 54))
        XCTAssertTrue(c.isComplete)
        XCTAssertEqual(c.chapters.map(\.number), Array(1...54))
        c.add(SpotifyAlbumPage(chapters: (1...50).map(chapter), total: 54))
        XCTAssertEqual(c.chapters.count, 54, "a response seen twice adds nothing")
    }

    func testDurationText() {
        func text(_ ms: Int) -> String { SpotifyChapter(uri: "u", number: 1, disc: 1, title: "t", durationMs: ms).durationText }
        XCTAssertEqual(text(95_000), "1:35")
        XCTAssertEqual(text(9_400), "0:09")
        XCTAssertEqual(text(3_725_000), "1:02:05")
        XCTAssertEqual(text(0), "0:00")
    }

    func testOnlyTheArtistAndTheHomeLinkOpenTheNativeGrid() {
        func dest(_ s: String) -> SpotifyLink.Destination { SpotifyLink.destination(for: URL(string: s)!) }
        XCTAssertEqual(dest("https://open.spotify.com"), .grid)
        XCTAssertEqual(dest("https://open.spotify.com/"), .grid)
        XCTAssertEqual(dest("https://open.spotify.com/artist/3meJIgRw7YleJrmbpbJK6S"), .grid)
        XCTAssertEqual(dest("https://open.spotify.com/artist/3meJIgRw7YleJrmbpbJK6S/discography/all?si=x"), .grid)
        XCTAssertEqual(dest("https://open.spotify.com/intl-de/artist/3meJIgRw7YleJrmbpbJK6S"), .grid)
        XCTAssertEqual(dest("https://open.spotify.com/artist/0000000000000000000000"), .page, "another artist: the web page")
        XCTAssertEqual(dest("https://open.spotify.com/album/6UN8m07SmIzyDe63H0oljL"), .page)
        XCTAssertEqual(dest("https://open.spotify.com/playlist/abc"), .page)
    }

    func testChapterTotalFromTheResponseBeatsTheGridCount() {
        var c = SpotifyChapterList(expected: 1)
        c.add(SpotifyAlbumPage(chapters: [chapter(1)], total: 2))
        XCTAssertFalse(c.isComplete)
    }
}
