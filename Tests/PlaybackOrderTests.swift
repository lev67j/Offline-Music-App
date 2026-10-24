import XCTest

final class PlaybackOrderTests: XCTestCase {
    private let playlist = (0..<20).map { _ in UUID() }

    // MARK: Search order

    func testWithoutSearchTheOrderIsThePlaylist() {
        XCTAssertEqual(PlaybackOrder.linear(playlist: playlist, visible: nil), playlist)
        XCTAssertEqual(PlaybackOrder.linear(playlist: playlist, visible: playlist), playlist)
    }

    func testSearchResultsPlayFirstThenThePlaylistAfterTheLastResult() {
        let results = [playlist[2], playlist[7], playlist[11]]
        let order = PlaybackOrder.linear(playlist: playlist, visible: results)

        XCTAssertEqual(Array(order.prefix(3)), results)
        XCTAssertEqual(Array(order.dropFirst(3)), Array(playlist[12...]))
    }

    func testTappingAResultQueuesTheResultsBelowItThenTheAlbumTail() {
        let results = [playlist[2], playlist[7], playlist[11]]
        let order = PlaybackOrder.linear(playlist: playlist, visible: results)
        let queue = PlaybackOrder.after(playlist[7], in: order)

        XCTAssertEqual(queue, [playlist[11]] + Array(playlist[12...]))
    }

    func testTappingTheLastResultContinuesFromItsPlaceInTheAlbum() {
        let results = [playlist[4], playlist[19]]
        let order = PlaybackOrder.linear(playlist: playlist, visible: results)

        XCTAssertEqual(PlaybackOrder.after(playlist[4], in: order), [playlist[19]])
        XCTAssertEqual(PlaybackOrder.after(playlist[19], in: order), [])
    }

    func testSelectedTagsPlayOnlyTheirTracks() {
        let tagged = [playlist[3], playlist[8], playlist[15]]
        let order = PlaybackOrder.linear(playlist: playlist, visible: tagged, onlyVisible: true)
        XCTAssertEqual(order, tagged)
        XCTAssertEqual(PlaybackOrder.after(playlist[8], in: order), [playlist[15]])
    }

    // MARK: Shuffle

    func testShuffleContainsEveryTrackOnce() {
        var generator = SystemRandomNumberGenerator()
        let order = PlaybackOrder.shuffled(playlist, playedInRound: [], artist: { _ in "A" }, using: &generator)
        XCTAssertEqual(order.count, playlist.count)
        XCTAssertEqual(Set(order), Set(playlist))
    }

    func testTracksNotHeardInTheRoundComeFirst() {
        var generator = SystemRandomNumberGenerator()
        let heard = Set(playlist.prefix(15))
        let order = PlaybackOrder.shuffled(playlist, playedInRound: heard, artist: { _ in "A" }, using: &generator)
        XCTAssertEqual(Set(order.prefix(5)), Set(playlist.suffix(5)))
    }

    func testOneArtistIsSpreadOut() {
        var generator = SystemRandomNumberGenerator()
        // 5 tracks by "Solo", 15 by different artists.
        let artists = Dictionary(uniqueKeysWithValues: playlist.enumerated().map { index, id in
            (id, index < 5 ? "Solo" : "Artist \(index)")
        })
        var adjacentPairs = 0
        for _ in 0..<500 {
            let order = PlaybackOrder.spread(playlist, artist: { artists[$0]! }, using: &generator)
            adjacentPairs += zip(order, order.dropFirst()).filter { artists[$0] == "Solo" && artists[$1] == "Solo" }.count
        }
        // A plain shuffle puts "Solo" next to itself about once per order,
        // 500 times in all; spreading leaves about a fifth of that.
        XCTAssertLessThan(adjacentPairs, 160)
    }

    func testEveryPositionIsEquallyLikely() {
        var generator = SystemRandomNumberGenerator()
        let artists = Dictionary(uniqueKeysWithValues: playlist.enumerated().map { ($1, "Artist \($0 % 4)") })
        var firstCounts: [UUID: Int] = [:]
        let runs = 40_000
        for _ in 0..<runs {
            let order = PlaybackOrder.spread(playlist, artist: { artists[$0]! }, using: &generator)
            firstCounts[order[0], default: 0] += 1
        }
        let expected = Double(runs) / Double(playlist.count)
        for id in playlist {
            XCTAssertEqual(Double(firstCounts[id, default: 0]), expected, accuracy: expected * 0.15)
        }
    }

    /// Short listening sessions, each started fresh, as when the app is
    /// opened, a few songs are played and it is closed again.
    func testShuffleRoundsKeepPlayCountsEvenAcrossSessions() {
        var generator = SystemRandomNumberGenerator()
        let library = (0..<300).map { _ in UUID() }
        var round: Set<UUID> = []
        var plays: [UUID: Int] = [:]

        for _ in 0..<100 {
            let order = PlaybackOrder.shuffled(library, playedInRound: round, artist: { _ in "" }, using: &generator)
            for id in order.prefix(9) {
                plays[id, default: 0] += 1
                round.insert(id)
                if round.count == library.count { round = [] }
            }
        }

        let counts = library.map { plays[$0, default: 0] }
        // 900 plays over 300 tracks: every track exactly 3 times, give or take one.
        XCTAssertLessThanOrEqual(counts.max()! - counts.min()!, 1)
    }
}
