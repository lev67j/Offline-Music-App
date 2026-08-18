import AVFoundation
import Foundation
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var selectedPlaylistID: UUID?
    @Published var queue: [QueueEntry] = []
    @Published private(set) var syncStatus = "Connecting…"
    @Published private(set) var mcpLinkCode: MCPLinkCode?
    @Published private(set) var mcpConnections: [MCPConnection] = []

    let supportURL: URL
    private let audioURL: URL
    private let coversURL: URL
    private let libraryURL: URL
    private let fileManager = FileManager.default
    private let persistenceQueue = DispatchQueue(
        label: "com.levvlasov.OfflineMusic.persistence",
        qos: .utility
    )
    private var tracksByID: [UUID: Track] = [:]
    private var trackTombstones: [DeletionTombstone] = []
    private var albumTombstones: [DeletionTombstone] = []
    private let cloud = OfflineMusicCloudClient()
    private var syncTask: Task<Void, Never>?
    private var isApplyingCloudSnapshot = false
    private var isSyncing = false

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportURL = baseURL.appendingPathComponent("OfflineMusic", isDirectory: true)
        audioURL = supportURL.appendingPathComponent("Audio", isDirectory: true)
        coversURL = supportURL.appendingPathComponent("Covers", isDirectory: true)
        libraryURL = supportURL.appendingPathComponent("library.json")

        createFolders()
        load()
        ensureDefaultPlaylist()
        Task { await syncNow() }
    }

    var selectedPlaylist: Playlist? {
        playlists.first { $0.id == selectedPlaylistID } ?? playlists.first
    }

    var selectedTracks: [Track] {
        guard let playlist = selectedPlaylist else { return [] }
        return playlist.trackIDs.compactMap { tracksByID[$0] }
    }

    func track(id: UUID) -> Track? {
        tracksByID[id]
    }

    func audioFileURL(for track: Track) -> URL {
        audioURL.appendingPathComponent(track.audioFileName)
    }

    func coverFileURL(named fileName: String?) -> URL? {
        guard let fileName else { return nil }
        return coversURL.appendingPathComponent(fileName)
    }

    func playlistCoverURL(for playlist: Playlist?) -> URL? {
        guard let playlist else { return nil }
        if let cover = coverFileURL(named: playlist.coverFileName) {
            return cover
        }
        let firstCoverName = playlist.trackIDs.compactMap { track(id: $0)?.coverFileName }.first
        return coverFileURL(named: firstCoverName)
    }

    func importAudioFiles(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let audioURL = audioURL
        let coversURL = coversURL
        let destinationPlaylistID = selectedPlaylistID

        Task {
            let importedTracks = await Task.detached(priority: .userInitiated) {
                urls.compactMap { sourceURL in
                    Self.importAudioFile(
                        from: sourceURL,
                        audioURL: audioURL,
                        coversURL: coversURL
                    )
                }
            }.value

            guard !importedTracks.isEmpty else { return }
            tracks.append(contentsOf: importedTracks)
            for track in importedTracks {
                tracksByID[track.id] = track
            }

            if let destinationPlaylistID,
               let playlistIndex = playlists.firstIndex(where: { $0.id == destinationPlaylistID }) {
                playlists[playlistIndex].trackIDs.append(contentsOf: importedTracks.map(\.id))
                playlists[playlistIndex].updatedAt = Date()
            }
            save()
        }
    }

    func selectPlaylist(_ playlistID: UUID) {
        selectedPlaylistID = playlistID
        save()
    }

    func deletePlaylist(_ playlistID: UUID) {
        guard playlists.count > 1,
              let index = playlists.firstIndex(where: { $0.id == playlistID })
        else { return }

        let wasSelected = selectedPlaylistID == playlistID
        albumTombstones.append(DeletionTombstone(id: playlistID, updatedAt: Date()))
        playlists.remove(at: index)

        if wasSelected {
            selectedPlaylistID = playlists[min(index, playlists.count - 1)].id
        }

        save()
    }

    func renamePlaylist(_ playlistID: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = playlists.firstIndex(where: { $0.id == playlistID })
        else { return }

        playlists[index].name = trimmedName
        playlists[index].updatedAt = Date()
        save()
    }

    @discardableResult
    func createPlaylist(named name: String) -> Playlist {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmedName.isEmpty ? "New Playlist" : trimmedName)
        playlists.append(playlist)
        selectedPlaylistID = playlist.id
        save()
        return playlist
    }

    func add(_ trackID: UUID, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[index].trackIDs.contains(trackID)
        else { return }

        playlists[index].trackIDs.append(trackID)
        playlists[index].updatedAt = Date()
        save()
    }

    func remove(_ trackID: UUID, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == trackID }
        playlists[index].updatedAt = Date()
        save()
    }

    func shuffleSelectedPlaylistOrder() {
        guard let playlistID = selectedPlaylist?.id,
              let index = playlists.firstIndex(where: { $0.id == playlistID }),
              playlists[index].trackIDs.count > 1
        else { return }

        let previousOrder = playlists[index].trackIDs
        playlists[index].trackIDs.shuffle()
        if playlists[index].trackIDs == previousOrder {
            playlists[index].trackIDs.swapAt(0, 1)
        }
        playlists[index].updatedAt = Date()
        save()
    }

    func sortSelectedPlaylistNewestFirst() {
        guard let playlistID = selectedPlaylist?.id,
              let index = playlists.firstIndex(where: { $0.id == playlistID }),
              playlists[index].trackIDs.count > 1
        else { return }

        let originalOrder = playlists[index].trackIDs
        let originalPositions = Dictionary(
            uniqueKeysWithValues: originalOrder.enumerated().map { ($0.element, $0.offset) }
        )

        playlists[index].trackIDs.sort { firstID, secondID in
            let firstDate = tracksByID[firstID]?.dateAdded
            let secondDate = tracksByID[secondID]?.dateAdded

            if firstDate != secondDate {
                return (firstDate ?? .distantPast) > (secondDate ?? .distantPast)
            }

            // Imports have historically been appended, so reversing their
            // existing positions is the best fallback for legacy tracks.
            return originalPositions[firstID, default: 0] > originalPositions[secondID, default: 0]
        }
        playlists[index].updatedAt = Date()
        save()
    }

    func setLyrics(_ lyrics: String, for trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let trimmedLyrics = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        tracks[index].lyrics = trimmedLyrics.isEmpty ? nil : trimmedLyrics
        tracks[index].updatedAt = Date()
        tracksByID[trackID] = tracks[index]
        save()
    }

    func setCover(data: Data, for trackID: UUID) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }),
              let coverFileName = writeCoverImage(data: data)
        else { return }

        let previousCoverFileName = tracks[trackIndex].coverFileName
        tracks[trackIndex].coverFileName = coverFileName
        tracks[trackIndex].remoteCoverURL = nil
        tracks[trackIndex].updatedAt = Date()
        tracksByID[trackID] = tracks[trackIndex]
        save()

        if let previousCoverFileName,
           !tracks.contains(where: { $0.coverFileName == previousCoverFileName }),
           !playlists.contains(where: { $0.coverFileName == previousCoverFileName }) {
            try? fileManager.removeItem(at: coversURL.appendingPathComponent(previousCoverFileName))
        }
    }

    func setSelectedPlaylistCover(data: Data) {
        guard let selectedPlaylistID,
              let playlistIndex = playlists.firstIndex(where: { $0.id == selectedPlaylistID }),
              let coverFileName = writeCoverImage(data: data)
        else { return }

        playlists[playlistIndex].coverFileName = coverFileName
        playlists[playlistIndex].remoteCoverURL = nil
        playlists[playlistIndex].updatedAt = Date()
        save()
    }

    func addToQueue(_ trackID: UUID) {
        queue.removeAll { $0.trackID == trackID }
        queue.append(QueueEntry(trackID: trackID))
        save()
    }

    func replaceQueue(with trackIDs: [UUID]) {
        queue = trackIDs.map { QueueEntry(trackID: $0) }
        save()
    }

    func removeQueueEntry(_ entryID: UUID) {
        queue.removeAll { $0.id == entryID }
        save()
    }

    func shuffleQueue() {
        guard queue.count > 1 else { return }

        let previousOrder = queue
        queue.shuffle()
        if queue == previousOrder {
            queue.swapAt(0, 1)
        }
        save()
    }

    func popNextQueueTrackID() -> UUID? {
        guard !queue.isEmpty else { return nil }
        let entry = queue.removeFirst()
        save()
        return entry.trackID
    }

    func queueTrackIDs(after trackID: UUID, shuffle: Bool = false) -> [UUID] {
        var ids = selectedTracks.map(\.id)
        if shuffle {
            ids.shuffle()
        }

        guard let currentIndex = ids.firstIndex(of: trackID) else {
            return Array(ids.dropFirst())
        }

        return Array(ids.dropFirst(currentIndex + 1))
    }

    func save() {
        let snapshot = LibrarySnapshot(
            tracks: tracks,
            playlists: playlists,
            selectedPlaylistID: selectedPlaylistID,
            queue: queue,
            trackTombstones: trackTombstones,
            albumTombstones: albumTombstones
        )
        let libraryURL = libraryURL

        // Encoding and atomic disk I/O can get noticeably expensive for a large
        // library. Keep them off the main actor so playback controls and scrolling
        // never wait for persistence to finish. This serial queue also preserves
        // the order of snapshots when the user taps controls quickly.
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: libraryURL, options: .atomic)
        }

        guard !isApplyingCloudSnapshot else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    nonisolated private static func importAudioFile(
        from url: URL,
        audioURL: URL,
        coversURL: URL
    ) -> Track? {
        let fileManager = FileManager.default
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let destinationFileName = "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "audio" : url.pathExtension)"
        let destinationURL = audioURL.appendingPathComponent(destinationFileName)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: url, to: destinationURL)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            return nil
        }

        let metadata = readMetadata(
            from: destinationURL,
            fallbackName: url.deletingPathExtension().lastPathComponent,
            coversURL: coversURL
        )
        return Track(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            duration: metadata.duration,
            audioFileName: destinationFileName,
            coverFileName: metadata.coverFileName,
            dateAdded: Date()
        )
    }

    nonisolated private static func readMetadata(
        from url: URL,
        fallbackName: String,
        coversURL: URL
    ) -> (title: String, artist: String, album: String, duration: TimeInterval, coverFileName: String?) {
        let asset = AVURLAsset(url: url)
        let metadata = asset.commonMetadata
        let title = metadata.stringValue(for: .commonIdentifierTitle) ?? fallbackName
        let artist = metadata.stringValue(for: .commonIdentifierArtist) ?? "Unknown Artist"
        let album = metadata.stringValue(for: .commonIdentifierAlbumName) ?? "Unknown Album"
        let seconds = CMTimeGetSeconds(asset.duration)
        let duration = seconds.isFinite ? seconds : 0
        let coverFileName = metadata.artworkData().flatMap {
            writeCoverImage(data: $0, coversURL: coversURL)
        }

        return (title, artist, album, duration, coverFileName)
    }

    private func writeCoverImage(data: Data) -> String? {
        Self.writeCoverImage(data: data, coversURL: coversURL)
    }

    nonisolated private static func writeCoverImage(data: Data, coversURL: URL) -> String? {
        let imageData: Data
        if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) {
            imageData = jpeg
        } else {
            imageData = data
        }

        let fileName = "\(UUID().uuidString).jpg"
        let url = coversURL.appendingPathComponent(fileName)
        do {
            try imageData.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    private func createFolders() {
        try? fileManager.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: coversURL, withIntermediateDirectories: true)
        // Imported files get the same protection individually. Setting it on the
        // directory is enough here and avoids scanning the whole library at launch.
        setBackgroundPlaybackFileProtection(for: audioURL)
    }

    private func setBackgroundPlaybackFileProtection(for url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: libraryURL),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
        else { return }

        tracks = snapshot.tracks
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        playlists = snapshot.playlists
        selectedPlaylistID = snapshot.selectedPlaylistID
        queue = snapshot.queue
        trackTombstones = snapshot.trackTombstones ?? []
        albumTombstones = snapshot.albumTombstones ?? []
    }

    private func ensureDefaultPlaylist() {
        if playlists.isEmpty {
            playlists = [Playlist(name: "Offline Music")]
            selectedPlaylistID = playlists[0].id
            save()
        } else if selectedPlaylistID == nil {
            selectedPlaylistID = playlists[0].id
            save()
        }
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            syncStatus = "Syncing…"
            let local = CloudLibrarySnapshot(
                tracks: tracks.map(CloudTrack.init),
                albums: playlists.map(CloudAlbum.init),
                trackTombstones: trackTombstones.map(CloudTombstone.init),
                albumTombstones: albumTombstones.map(CloudTombstone.init),
                revision: nil
            )
            let remote = try await cloud.sync(local)
            try await apply(remote)
            syncStatus = "Connected"
        } catch {
            syncStatus = "Offline"
        }
    }

    func generateMCPLinkCode() async {
        do {
            mcpLinkCode = try await cloud.createLinkCode()
            mcpConnections = try await cloud.connections()
        } catch {
            syncStatus = "Connection failed"
        }
    }

    func refreshMCPConnections() async {
        mcpConnections = (try? await cloud.connections()) ?? []
    }

    func revokeMCPConnection(_ id: UUID) async {
        do {
            try await cloud.revokeConnection(id)
            await refreshMCPConnections()
        } catch {
            syncStatus = "Connection failed"
        }
    }

    private func apply(_ remote: CloudLibrarySnapshot) async throws {
        isApplyingCloudSnapshot = true
        defer { isApplyingCloudSnapshot = false }

        let removedTrackIDs = Set(remote.trackTombstones.map(\.id))
        for oldTrack in tracks where removedTrackIDs.contains(oldTrack.id) {
            if !oldTrack.audioFileName.isEmpty {
                try? fileManager.removeItem(at: audioFileURL(for: oldTrack))
            }
        }

        var appliedTracks: [Track] = []
        for cloudTrack in remote.tracks {
            appliedTracks.append(try await materialize(cloudTrack, preserving: tracksByID[cloudTrack.id]))
        }
        let appliedByID = Dictionary(uniqueKeysWithValues: appliedTracks.map { ($0.id, $0) })
        var appliedAlbums: [Playlist] = []
        for cloudAlbum in remote.albums {
            let local = playlists.first { $0.id == cloudAlbum.id }
            let cover = try await materializeCover(
                remoteURL: cloudAlbum.coverURL,
                existingURL: local?.remoteCoverURL,
                existingFileName: local?.coverFileName
            )
            appliedAlbums.append(Playlist(
                id: cloudAlbum.id,
                name: cloudAlbum.name,
                trackIDs: cloudAlbum.trackIDs.filter { appliedByID[$0] != nil },
                coverFileName: cover,
                remoteCoverURL: cloudAlbum.coverURL,
                updatedAt: cloudAlbum.updatedAt
            ))
        }

        tracks = appliedTracks
        tracksByID = appliedByID
        playlists = appliedAlbums
        trackTombstones = remote.trackTombstones.map(\.local)
        albumTombstones = remote.albumTombstones.map(\.local)
        queue.removeAll { appliedByID[$0.trackID] == nil }
        if !playlists.contains(where: { $0.id == selectedPlaylistID }) {
            selectedPlaylistID = playlists.first?.id
        }
        ensureDefaultPlaylist()
        save()
    }

    private func materialize(_ remote: CloudTrack, preserving local: Track?) async throws -> Track {
        var audioFileName = local?.audioFileName ?? ""
        let localAudioExists = !audioFileName.isEmpty
            && fileManager.fileExists(atPath: audioURL.appendingPathComponent(audioFileName).path)
        if let remoteAudioURL = remote.audioURL,
           local?.remoteAudioURL != remoteAudioURL || !localAudioExists {
            audioFileName = try await downloadAudio(from: remoteAudioURL)
        }
        let coverFileName = try await materializeCover(
            remoteURL: remote.coverURL,
            existingURL: local?.remoteCoverURL,
            existingFileName: local?.coverFileName
        )
        return Track(
            id: remote.id,
            title: remote.title,
            artist: remote.artist,
            album: remote.album,
            duration: remote.duration,
            audioFileName: audioFileName,
            coverFileName: coverFileName,
            lyrics: remote.lyrics,
            dateAdded: remote.dateAdded,
            remoteAudioURL: remote.audioURL,
            remoteCoverURL: remote.coverURL,
            updatedAt: remote.updatedAt
        )
    }

    private func downloadAudio(from url: URL) async throws -> String {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let fileName = "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "audio" : url.pathExtension)"
        let destination = audioURL.appendingPathComponent(fileName)
        try fileManager.moveItem(at: temporaryURL, to: destination)
        setBackgroundPlaybackFileProtection(for: destination)
        return fileName
    }

    private func materializeCover(
        remoteURL: URL?,
        existingURL: URL?,
        existingFileName: String?
    ) async throws -> String? {
        guard let remoteURL else { return existingFileName }
        if remoteURL == existingURL, let existingFileName,
           fileManager.fileExists(atPath: coversURL.appendingPathComponent(existingFileName).path) {
            return existingFileName
        }
        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              data.count <= 15_000_000,
              let fileName = writeCoverImage(data: data) else {
            throw URLError(.badServerResponse)
        }
        return fileName
    }
}

private extension Array where Element == AVMetadataItem {
    func stringValue(for identifier: AVMetadataIdentifier) -> String? {
        AVMetadataItem.metadataItems(from: self, filteredByIdentifier: identifier).first?.stringValue
    }

    func artworkData() -> Data? {
        let artworkItems = AVMetadataItem.metadataItems(from: self, filteredByIdentifier: .commonIdentifierArtwork)
        for item in artworkItems {
            if let data = item.dataValue {
                return data
            }
            if let image = item.value as? UIImage {
                return image.pngData()
            }
        }
        return nil
    }
}
