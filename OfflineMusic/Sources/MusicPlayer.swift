import AVFoundation
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var currentTrackID: UUID?
    @Published var isPlaying = false
    @Published var repeatMode: RepeatMode = .off {
        didSet { savePlaybackState() }
    }
    @Published private(set) var isShuffleEnabled = false

    private let library: LibraryStore
    private let audioSession = AVAudioSession.sharedInstance()
    private let nowPlayingCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var player: AVAudioPlayer?
    private var shouldResumeAfterInterruption = false
    private var isPlaybackConfigured = false
    private var playbackHistory: [UUID] = []
    private var isNavigatingHistory = false

    /// Playlist the current queue was built from. It stays the same when the
    /// user browses another playlist while music plays.
    private var contextPlaylistID: UUID?
    /// Search results the user tapped in, in the order they were shown.
    private var contextResults: [UUID]?
    /// Tracks played since the user last started playback; each plays once
    /// per pass unless repeat is on.
    private var playedTrackIDs: Set<UUID> = []
    /// Per playlist: tracks already heard in the current shuffle round. Kept
    /// across launches so shuffle offers every track before repeating any.
    private var shuffleRounds: [UUID: Set<UUID>] = [:]
    /// Where the restored track stopped, applied when playback resumes.
    private var restoredPosition: TimeInterval?
    private var didRestoreState = false

    init(library: LibraryStore) {
        self.library = library
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        nowPlayingCenter.nowPlayingInfo = nil
    }

    var currentTrack: Track? {
        guard let currentTrackID else { return nil }
        return library.track(id: currentTrackID)
    }

    var playbackPosition: TimeInterval {
        player?.currentTime ?? restoredPosition ?? 0
    }

    var playbackDuration: TimeInterval {
        player?.duration ?? currentTrack?.duration ?? 0
    }

    func seek(to time: TimeInterval) {
        guard let player else {
            restoredPosition = max(time, 0)
            return
        }
        player.currentTime = min(max(time, 0), player.duration)
        updateNowPlayingInfo()
    }

    /// Plays the selected playlist from the top, or in shuffle order.
    /// `visibleTrackIDs` are the search results when a search is active.
    func playSelectedPlaylist(visibleTrackIDs: [UUID]? = nil) {
        startContext(visibleTrackIDs: visibleTrackIDs)
        let order = isShuffleEnabled ? shuffledQueue(excluding: nil) : linearOrder
        guard let first = order.first else { return }
        play(trackID: first, queue: Array(order.dropFirst()))
    }

    /// Plays a tapped track. Without shuffle the queue follows the list the
    /// user sees: the search results top to bottom, then the playlist after
    /// the last result.
    func playTrackFromSelectedPlaylist(_ trackID: UUID, visibleTrackIDs: [UUID]? = nil) {
        startContext(visibleTrackIDs: visibleTrackIDs)
        play(trackID: trackID, queue: upcomingTrackIDs(after: trackID))
    }

    func playQueueEntry(_ entryID: UUID) {
        guard let selectedIndex = library.queue.firstIndex(where: { $0.id == entryID }) else { return }

        let selectedEntry = library.queue[selectedIndex]
        let remainingTrackIDs = library.queue
            .dropFirst(selectedIndex + 1)
            .map(\.trackID)

        playedTrackIDs.removeAll()
        play(trackID: selectedEntry.trackID, queue: remainingTrackIDs)
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        defer { savePlaybackState() }

        guard let currentTrackID, contextTrackIDs.contains(currentTrackID) else { return }

        playedTrackIDs = [currentTrackID]
        playbackHistory.removeAll()
        library.replaceQueue(with: upcomingTrackIDs(after: currentTrackID))
    }

    func togglePlayPause() {
        if let player {
            if player.isPlaying {
                pausePlayback()
            } else {
                activateAudioSession()
                if player.play() {
                    isPlaying = true
                    updateNowPlayingInfo()
                }
            }
        } else if currentTrackID != nil {
            resumeRestoredTrack()
        } else {
            playSelectedPlaylist()
        }
    }

    func previousTrack() {
        if let player, player.currentTime > 4 {
            seek(to: 0)
            return
        }

        if isShuffleEnabled, let previousID = playbackHistory.popLast() {
            isNavigatingHistory = true
            play(trackID: previousID)
            isNavigatingHistory = false
            return
        }

        let order = linearOrder
        guard let currentTrackID,
              let index = order.firstIndex(of: currentTrackID),
              index > 0
        else {
            player?.currentTime = 0
            return
        }

        let previousID = order[index - 1]
        play(trackID: previousID, queue: PlaybackOrder.after(previousID, in: order))
    }

    func nextTrack() {
        playNextFromQueueOrStop()
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    func refreshNowPlayingInfo() {
        updateNowPlayingInfo()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.handleTrackFinished()
        }
    }

    // MARK: - Queue

    private var contextTrackIDs: [UUID] {
        guard let playlistID = contextPlaylistID ?? library.selectedPlaylist?.id else { return [] }
        return library.trackIDs(inPlaylist: playlistID)
    }

    private var linearOrder: [UUID] {
        PlaybackOrder.linear(playlist: contextTrackIDs, visible: contextResults)
    }

    private func startContext(visibleTrackIDs: [UUID]?) {
        contextPlaylistID = library.selectedPlaylist?.id
        let playlist = library.selectedTracks.map(\.id)
        contextResults = visibleTrackIDs == playlist ? nil : visibleTrackIDs
        playedTrackIDs.removeAll()
        playbackHistory.removeAll()
    }

    private func upcomingTrackIDs(after trackID: UUID) -> [UUID] {
        isShuffleEnabled
            ? shuffledQueue(excluding: trackID)
            : PlaybackOrder.after(trackID, in: linearOrder)
    }

    /// Shuffled order of the context. Search results come first, then the
    /// rest of the playlist; tracks not heard in this shuffle round lead.
    private func shuffledQueue(excluding trackID: UUID?) -> [UUID] {
        var generator = SystemRandomNumberGenerator()
        let artist: (UUID) -> String = { [library] in library.track(id: $0)?.artist ?? "" }
        let round = contextPlaylistID.flatMap { shuffleRounds[$0] } ?? []
        let all = contextTrackIDs.filter { $0 != trackID }

        guard let results = contextResults else {
            return PlaybackOrder.shuffled(all, playedInRound: round, artist: artist, using: &generator)
        }
        let resultSet = Set(results)
        let first = PlaybackOrder.shuffled(
            all.filter { resultSet.contains($0) }, playedInRound: [], artist: artist, using: &generator
        )
        let rest = PlaybackOrder.shuffled(
            all.filter { !resultSet.contains($0) }, playedInRound: round, artist: artist, using: &generator
        )
        return first + rest
    }

    private func markPlayedInShuffleRound(_ trackID: UUID) {
        guard let playlistID = contextPlaylistID else { return }
        let playlist = Set(contextTrackIDs)
        guard playlist.contains(trackID) else { return }

        var round = (shuffleRounds[playlistID] ?? []).intersection(playlist)
        round.insert(trackID)
        if playlist.isSubset(of: round) {
            // Everyone has been heard: the next round starts from scratch.
            round = []
        }
        shuffleRounds[playlistID] = round
    }

    private func play(trackID: UUID, queue: [UUID]? = nil) {
        guard let track = library.track(id: trackID) else { return }
        configurePlaybackIfNeeded()
        let url = library.audioFileURL(for: track)

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            activateAudioSession()
            player?.stop()
            player = newPlayer
            restoredPosition = nil
            guard newPlayer.play() else {
                isPlaying = false
                updateNowPlayingInfo()
                return
            }
            if !isNavigatingHistory,
               let currentTrackID,
               currentTrackID != trackID {
                playbackHistory.append(currentTrackID)
            }
            currentTrackID = trackID
            playedTrackIDs.insert(trackID)
            markPlayedInShuffleRound(trackID)
            isPlaying = true
            if let queue {
                library.replaceQueue(with: queue)
            }
            updateNowPlayingInfo()
            savePlaybackState()
        } catch {
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    /// Continues the track that was playing when the app was last closed.
    private func resumeRestoredTrack() {
        guard let currentTrackID else { return }
        let position = restoredPosition
        play(trackID: currentTrackID, queue: library.queue.map(\.trackID))
        if let position, position > 1, let player, position < player.duration - 1 {
            player.currentTime = position
            updateNowPlayingInfo()
        }
    }

    private func handleTrackFinished() {
        switch repeatMode {
        case .once:
            if let currentTrackID {
                play(trackID: currentTrackID, queue: library.queue.map(\.trackID))
            }
        case .off, .continuous:
            playNextFromQueueOrStop()
        }
    }

    private func playNextFromQueueOrStop() {
        while let nextID = library.popNextQueueTrackID() {
            guard !playedTrackIDs.contains(nextID) else { continue }
            play(trackID: nextID)
            return
        }

        let contextIDs = contextTrackIDs
        guard !contextIDs.isEmpty else {
            stopPlayback()
            return
        }

        var nextCycle = linearOrder.filter { !playedTrackIDs.contains($0) }
        if nextCycle.isEmpty, repeatMode == .continuous {
            playedTrackIDs.removeAll()
            nextCycle = linearOrder
        }

        if isShuffleEnabled, !nextCycle.isEmpty {
            let allowed = Set(nextCycle)
            nextCycle = shuffledQueue(excluding: nil).filter { allowed.contains($0) }
            avoidImmediateRepeat(in: &nextCycle)
        }

        guard let nextID = nextCycle.first else {
            stopPlayback()
            return
        }

        library.replaceQueue(with: Array(nextCycle.dropFirst()))
        play(trackID: nextID)
    }

    private func avoidImmediateRepeat(in trackIDs: inout [UUID]) {
        guard trackIDs.count > 1,
              let currentTrackID,
              trackIDs.first == currentTrackID,
              let differentIndex = trackIDs.firstIndex(where: { $0 != currentTrackID })
        else { return }

        trackIDs.swapAt(0, differentIndex)
    }

    // MARK: - Saved state

    private struct SavedState: Codable {
        var currentTrackID: UUID?
        var position: TimeInterval
        var isShuffleEnabled: Bool
        var repeatMode: RepeatMode
        var contextPlaylistID: UUID?
        var contextResults: [UUID]?
        var playedTrackIDs: [UUID]
        var shuffleRounds: [UUID: [UUID]]
    }

    private var stateURL: URL {
        library.supportURL.appendingPathComponent("playback.json")
    }

    /// Restores shuffle, repeat, the last track and the shuffle rounds.
    /// Call once the library has loaded.
    func restorePlaybackState() {
        guard !didRestoreState else { return }
        didRestoreState = true
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data)
        else { return }

        isShuffleEnabled = state.isShuffleEnabled
        repeatMode = state.repeatMode
        contextPlaylistID = state.contextPlaylistID
        contextResults = state.contextResults
        playedTrackIDs = Set(state.playedTrackIDs)
        shuffleRounds = state.shuffleRounds.mapValues(Set.init)
        if let trackID = state.currentTrackID, library.track(id: trackID) != nil {
            currentTrackID = trackID
            restoredPosition = state.position
        }
    }

    func savePlaybackState() {
        guard didRestoreState else { return }
        let state = SavedState(
            currentTrackID: currentTrackID,
            position: player?.currentTime ?? restoredPosition ?? 0,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            contextPlaylistID: contextPlaylistID,
            contextResults: contextResults,
            playedTrackIDs: Array(playedTrackIDs),
            shuffleRounds: shuffleRounds.mapValues(Array.init)
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        nowPlayingCenter.nowPlayingInfo = nil
    }

    private func configureAudioSession() {
        do {
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        } catch {
            // The player still works in the simulator without a configured session.
        }
    }

    private func configurePlaybackIfNeeded() {
        guard !isPlaybackConfigured else { return }
        isPlaybackConfigured = true
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSessionInterruptions()
    }

    private func activateAudioSession() {
        do {
            try audioSession.setActive(true)
        } catch {
            // Playback can still succeed in some simulator states.
        }
    }

    private func configureRemoteCommands() {
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.performRemoteCommand { $0.resumePlayback() } ?? .commandFailed
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.performRemoteCommand { $0.pausePlayback() } ?? .commandFailed
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.performRemoteCommand { $0.togglePlayPause() } ?? .commandFailed
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.performRemoteCommand { $0.nextTrack() } ?? .commandFailed
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.performRemoteCommand { $0.previousTrack() } ?? .commandFailed
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return self?.performRemoteCommand { $0.seek(to: event.positionTime) } ?? .commandFailed
        }
    }

    nonisolated private func performRemoteCommand(_ command: @escaping @MainActor (MusicPlayer) -> Void) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            command(self)
        }
        return .success
    }

    private func resumePlayback() {
        if let player {
            guard !player.isPlaying else { return }
            activateAudioSession()
            if player.play() {
                isPlaying = true
                updateNowPlayingInfo()
            }
        } else if currentTrackID != nil {
            resumeRestoredTrack()
        } else {
            playSelectedPlaylist()
        }
    }

    private func pausePlayback() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
        savePlaybackState()
    }

    private func observeAudioSessionInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
    }

    @objc private func audioSessionInterrupted(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.audioSessionInterrupted(notification)
            }
            return
        }

        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            shouldResumeAfterInterruption = isPlaying
            isPlaying = false
            updateNowPlayingInfo()
        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if shouldResumeAfterInterruption, options.contains(.shouldResume) {
                activateAudioSession()
                isPlaying = player?.play() == true
            }
            shouldResumeAfterInterruption = false
            updateNowPlayingInfo()
        @unknown default:
            break
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            nowPlayingCenter.nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let coverURL = library.coverFileURL(named: track.coverFileName),
           let image = UIImage(contentsOfFile: coverURL.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        nowPlayingCenter.nowPlayingInfo = info
    }
}
