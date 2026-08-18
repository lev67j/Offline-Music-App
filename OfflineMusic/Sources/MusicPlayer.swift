import AVFoundation
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class MusicPlayer: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published var currentTrackID: UUID?
    @Published var isPlaying = false
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var isShuffleEnabled = false

    private let library: LibraryStore
    private let audioSession = AVAudioSession.sharedInstance()
    private let nowPlayingCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var player: AVAudioPlayer?
    private var shouldResumeAfterInterruption = false
    private var isPlaybackConfigured = false
    private var playedTrackIDs: Set<UUID> = []
    private var playbackHistory: [UUID] = []
    private var isNavigatingHistory = false

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
        player?.currentTime ?? 0
    }

    var playbackDuration: TimeInterval {
        player?.duration ?? currentTrack?.duration ?? 0
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), player.duration)
        updateNowPlayingInfo()
    }

    func playSelectedPlaylist() {
        var tracks = library.selectedTracks
        if isShuffleEnabled {
            tracks.shuffle()
        }

        guard let firstTrack = tracks.first else { return }
        playedTrackIDs.removeAll()
        playbackHistory.removeAll()
        play(trackID: firstTrack.id, queue: Array(tracks.dropFirst()).map(\.id))
    }

    func playTrackFromSelectedPlaylist(_ trackID: UUID) {
        playedTrackIDs.removeAll()
        playbackHistory.removeAll()
        let queue = upcomingTrackIDs(afterSelecting: trackID)
        play(trackID: trackID, queue: queue)
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

        guard let currentTrackID,
              library.selectedTracks.contains(where: { $0.id == currentTrackID })
        else { return }

        playedTrackIDs = [currentTrackID]
        playbackHistory.removeAll()
        library.replaceQueue(with: upcomingTrackIDs(afterSelecting: currentTrackID))
    }

    func togglePlayPause() {
        if let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                updateNowPlayingInfo()
            } else {
                activateAudioSession()
                if player.play() {
                    isPlaying = true
                    updateNowPlayingInfo()
                }
            }
        } else if let currentTrackID {
            play(trackID: currentTrackID, queue: library.queue.map(\.trackID))
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

        guard let currentTrackID,
              let index = library.selectedTracks.firstIndex(where: { $0.id == currentTrackID }),
              index > 0
        else {
            player?.currentTime = 0
            return
        }

        let previousID = library.selectedTracks[index - 1].id
        let queue = library.queueTrackIDs(after: previousID)
        play(trackID: previousID, queue: queue)
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

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.handleTrackFinished()
        }
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
            isPlaying = true
            if let queue {
                library.replaceQueue(with: queue)
            }
            updateNowPlayingInfo()
        } catch {
            isPlaying = false
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

        let playlistTrackIDs = library.selectedTracks.map(\.id)
        guard !playlistTrackIDs.isEmpty else {
            stopPlayback()
            return
        }

        var nextCycle = playlistTrackIDs.filter { !playedTrackIDs.contains($0) }
        if nextCycle.isEmpty, repeatMode == .continuous {
            playedTrackIDs.removeAll()
            nextCycle = playlistTrackIDs
        }

        if isShuffleEnabled {
            nextCycle.shuffle()
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

    private func upcomingTrackIDs(afterSelecting trackID: UUID) -> [UUID] {
        guard isShuffleEnabled else {
            return library.queueTrackIDs(after: trackID)
        }

        var trackIDs = library.selectedTracks.map(\.id).filter { $0 != trackID }
        trackIDs.shuffle()
        return trackIDs
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
        } else if let currentTrackID {
            play(trackID: currentTrackID, queue: library.queue.map(\.trackID))
        } else {
            playSelectedPlaylist()
        }
    }

    private func pausePlayback() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
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
