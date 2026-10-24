import Foundation

/// Pure ordering rules for the playback queue. No audio or UI here, so the
/// rules can be tested on their own.
enum PlaybackOrder {
    /// The order tracks play in without shuffle.
    ///
    /// Without a search this is the playlist itself. With a search it is the
    /// visible results, top to bottom, followed by the playlist from the track
    /// after the last result.
    static func linear(playlist: [UUID], visible: [UUID]?) -> [UUID] {
        guard let visible, visible != playlist,
              let last = visible.last,
              let lastIndex = playlist.firstIndex(of: last)
        else { return playlist }

        let results = Set(visible)
        let tail = playlist[(lastIndex + 1)...].filter { !results.contains($0) }
        return visible.filter { playlist.contains($0) } + tail
    }

    /// Tracks after `trackID` in `order`, or the whole order when it is absent.
    static func after(_ trackID: UUID, in order: [UUID]) -> [UUID] {
        guard let index = order.firstIndex(of: trackID) else { return order }
        return Array(order[(index + 1)...])
    }

    /// A shuffled queue for `candidates`.
    ///
    /// Tracks not yet heard in the current shuffle round come first, so every
    /// track is offered once before any repeats, across app launches too.
    /// Inside each group the tracks of one artist are spread out, so the same
    /// artist rarely plays twice in a row. Every track still has the same
    /// chance to land at any position.
    static func shuffled<G: RandomNumberGenerator>(
        _ candidates: [UUID],
        playedInRound: Set<UUID>,
        artist: (UUID) -> String,
        using generator: inout G
    ) -> [UUID] {
        let fresh = candidates.filter { !playedInRound.contains($0) }
        let heard = candidates.filter { playedInRound.contains($0) }
        return spread(fresh, artist: artist, using: &generator)
            + spread(heard, artist: artist, using: &generator)
    }

    /// Spotify-style artist spreading: each artist's tracks are shuffled and
    /// placed at even intervals with a random offset and a little jitter, then
    /// all tracks are merged by position.
    static func spread<G: RandomNumberGenerator>(
        _ trackIDs: [UUID],
        artist: (UUID) -> String,
        using generator: inout G
    ) -> [UUID] {
        guard trackIDs.count > 1 else { return trackIDs }

        let groups = Dictionary(grouping: trackIDs) { artistKey(artist($0)) }
        var placed: [(position: Double, id: UUID)] = []
        placed.reserveCapacity(trackIDs.count)

        for key in groups.keys.sorted() {
            let group = groups[key, default: []].shuffled(using: &generator)
            let step = 1.0 / Double(group.count)
            let offset = Double.random(in: 0..<step, using: &generator)
            for (index, id) in group.enumerated() {
                let jitter = Double.random(in: -0.15...0.15, using: &generator) * step
                placed.append((offset + Double(index) * step + jitter, id))
            }
        }

        return placed.sorted { $0.position < $1.position }.map(\.id)
    }

    private static func artistKey(_ artist: String) -> String {
        artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
