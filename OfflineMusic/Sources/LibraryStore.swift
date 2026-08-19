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
    @Published private(set) var dataSafetyStatus = "Loading protected library…"
    @Published private(set) var transferStatus: String?
    @Published private(set) var isLibraryReady = false
    @Published private(set) var mcpLinkCode: MCPLinkCode?
    @Published private(set) var mcpConnections: [MCPConnection] = []

    let supportURL: URL
    private let audioURL: URL
    private let coversURL: URL
    private let libraryURL: URL
    private let backupsURL: URL
    private let recoveryURL: URL
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
    private var hasStarted = false

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportURL = baseURL.appendingPathComponent("OfflineMusic", isDirectory: true)
        audioURL = supportURL.appendingPathComponent("Audio", isDirectory: true)
        coversURL = supportURL.appendingPathComponent("Covers", isDirectory: true)
        libraryURL = supportURL.appendingPathComponent("library.json")
        backupsURL = supportURL.appendingPathComponent("Backups", isDirectory: true)
        recoveryURL = supportURL.appendingPathComponent("Recovery", isDirectory: true)

    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        let libraryURL = libraryURL
        let backupsURL = backupsURL
        let recoveryURL = recoveryURL
        let supportURL = supportURL
        let audioURL = audioURL
        let coversURL = coversURL
        let loadResult = await Task.detached(priority: .userInitiated) {
            Self.prepareStorage(
                supportURL: supportURL,
                audioURL: audioURL,
                coversURL: coversURL,
                backupsURL: backupsURL,
                recoveryURL: recoveryURL
            )
            return Self.loadBestSnapshot(
                primaryURL: libraryURL,
                backupsURL: backupsURL,
                recoveryURL: recoveryURL
            )
        }.value

        if let snapshot = loadResult.snapshot {
            applyLocal(snapshot)
        }
        ensureDefaultPlaylist(shouldSave: false)
        isLibraryReady = true

        switch loadResult.source {
        case .primary:
            dataSafetyStatus = "Protected by rotating local backups"
        case .backup:
            dataSafetyStatus = "Recovered the last valid local backup"
            save()
        case .newLibrary:
            dataSafetyStatus = "Protected by rotating local backups"
            save()
        case .corruptPrimary:
            dataSafetyStatus = "Damaged metadata was quarantined; your files were preserved"
            save()
        }

        await syncNow()
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
        guard isLibraryReady else { return }
        let snapshot = LibrarySnapshot(
            tracks: tracks,
            playlists: playlists,
            selectedPlaylistID: selectedPlaylistID,
            queue: queue,
            trackTombstones: trackTombstones,
            albumTombstones: albumTombstones
        )
        let libraryURL = libraryURL
        let backupsURL = backupsURL

        // Encoding and atomic disk I/O can get noticeably expensive for a large
        // library. Keep them off the main actor so playback controls and scrolling
        // never wait for persistence to finish. This serial queue also preserves
        // the order of snapshots when the user taps controls quickly.
        persistenceQueue.async {
            Self.persist(snapshot, to: libraryURL, backupsURL: backupsURL)
        }

        guard !isApplyingCloudSnapshot else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func makeExportFolder() async -> URL? {
        guard isLibraryReady else { return nil }
        transferStatus = "Preparing a complete export…"
        let snapshot = LibrarySnapshot(
            tracks: tracks,
            playlists: playlists,
            selectedPlaylistID: selectedPlaylistID,
            queue: queue,
            trackTombstones: trackTombstones,
            albumTombstones: albumTombstones
        )
        let audioURL = audioURL
        let coversURL = coversURL

        do {
            let folder = try await Task.detached(priority: .userInitiated) {
                try Self.exportFolder(snapshot: snapshot, audioURL: audioURL, coversURL: coversURL)
            }.value
            transferStatus = "Export ready: \(snapshot.tracks.count) tracks"
            return folder
        } catch {
            transferStatus = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func importLibraryFolder(from folderURL: URL) {
        guard isLibraryReady else { return }
        transferStatus = "Checking and importing the folder…"
        let audioURL = audioURL
        let coversURL = coversURL

        Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try Self.readExportFolder(
                        folderURL,
                        audioURL: audioURL,
                        coversURL: coversURL
                    )
                }.value
                applyImportedLibrary(imported)
                transferStatus = "Imported \(imported.tracks.count) tracks safely"
            } catch {
                transferStatus = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func applyImportedLibrary(_ imported: ImportedLibrary) {
        guard !imported.tracks.isEmpty || !imported.playlists.isEmpty else { return }
        createRecoverySnapshot(reason: "before-folder-import")

        for incomingTrack in imported.tracks {
            var track = incomingTrack
            if let index = tracks.firstIndex(where: { $0.id == track.id }) {
                let existing = tracks[index]
                if track.audioFileName.isEmpty {
                    track.audioFileName = existing.audioFileName
                }
                if track.coverFileName == nil {
                    track.coverFileName = existing.coverFileName
                }
                tracks[index] = track
            } else {
                tracks.append(track)
            }
            tracksByID[track.id] = track
        }

        for incomingPlaylist in imported.playlists {
            var playlist = incomingPlaylist
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                if playlist.coverFileName == nil {
                    playlist.coverFileName = playlists[index].coverFileName
                }
                playlists[index] = playlist
            } else {
                playlists.append(playlist)
            }
        }

        let importedTrackIDs = Set(imported.tracks.map(\.id))
        let importedPlaylistIDs = Set(imported.playlists.map(\.id))
        trackTombstones.removeAll { importedTrackIDs.contains($0.id) }
        albumTombstones.removeAll { importedPlaylistIDs.contains($0.id) }
        queue = imported.queue.filter { tracksByID[$0.trackID] != nil }
        if let selectedID = imported.selectedPlaylistID,
           playlists.contains(where: { $0.id == selectedID }) {
            selectedPlaylistID = selectedID
        }
        ensureDefaultPlaylist(shouldSave: false)
        save()
    }

    nonisolated private static func exportFolder(
        snapshot: LibrarySnapshot,
        audioURL: URL,
        coversURL: URL
    ) throws -> URL {
        let manager = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let root = manager.temporaryDirectory.appendingPathComponent(
            "Offline Music Export \(formatter.string(from: Date()))",
            isDirectory: true
        )
        try? manager.removeItem(at: root)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let tracksRoot = root.appendingPathComponent("Tracks", isDirectory: true)
        let playlistCoversRoot = root.appendingPathComponent("Playlist Covers", isDirectory: true)
        try manager.createDirectory(at: tracksRoot, withIntermediateDirectories: true)
        try manager.createDirectory(at: playlistCoversRoot, withIntermediateDirectories: true)

        var exportedTracks: [ExportedTrack] = []
        for track in snapshot.tracks {
            let trackFolder = tracksRoot.appendingPathComponent(track.id.uuidString, isDirectory: true)
            try manager.createDirectory(at: trackFolder, withIntermediateDirectories: true)

            var audioPath: String?
            if !track.audioFileName.isEmpty {
                let source = audioURL.appendingPathComponent(track.audioFileName)
                if manager.fileExists(atPath: source.path) {
                    let extensionName = source.pathExtension.isEmpty ? "audio" : source.pathExtension
                    let name = "audio.\(extensionName)"
                    try manager.copyItem(at: source, to: trackFolder.appendingPathComponent(name))
                    audioPath = "Tracks/\(track.id.uuidString)/\(name)"
                }
            }

            var coverPath: String?
            if let coverFileName = track.coverFileName {
                let source = coversURL.appendingPathComponent(coverFileName)
                if manager.fileExists(atPath: source.path) {
                    let extensionName = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
                    let name = "cover.\(extensionName)"
                    try manager.copyItem(at: source, to: trackFolder.appendingPathComponent(name))
                    coverPath = "Tracks/\(track.id.uuidString)/\(name)"
                }
            }

            var lyricsPath: String?
            if let lyrics = track.lyrics, !lyrics.isEmpty {
                let url = trackFolder.appendingPathComponent("lyrics.txt")
                try lyrics.data(using: .utf8)?.write(to: url, options: .atomic)
                lyricsPath = "Tracks/\(track.id.uuidString)/lyrics.txt"
            }

            let exported = ExportedTrack(track: track, audioPath: audioPath, coverPath: coverPath, lyricsPath: lyricsPath)
            exportedTracks.append(exported)
            let metadata = try JSONEncoder.pretty.encode(exported)
            try metadata.write(to: trackFolder.appendingPathComponent("metadata.json"), options: .atomic)
        }

        var exportedPlaylists: [ExportedPlaylist] = []
        for playlist in snapshot.playlists {
            var coverPath: String?
            if let coverFileName = playlist.coverFileName {
                let source = coversURL.appendingPathComponent(coverFileName)
                if manager.fileExists(atPath: source.path) {
                    let extensionName = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
                    let name = "\(playlist.id.uuidString).\(extensionName)"
                    try manager.copyItem(at: source, to: playlistCoversRoot.appendingPathComponent(name))
                    coverPath = "Playlist Covers/\(name)"
                }
            }
            exportedPlaylists.append(ExportedPlaylist(playlist: playlist, coverPath: coverPath))
        }

        let manifest = LibraryExportManifest(
            formatVersion: 1,
            exportedAt: Date(),
            tracks: exportedTracks,
            playlists: exportedPlaylists,
            selectedPlaylistID: snapshot.selectedPlaylistID,
            queue: snapshot.queue
        )
        try JSONEncoder.pretty.encode(manifest).write(
            to: root.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        return root
    }

    nonisolated private static func readExportFolder(
        _ folderURL: URL,
        audioURL: URL,
        coversURL: URL
    ) throws -> ImportedLibrary {
        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { folderURL.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var importResult: Result<ImportedLibrary, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: folderURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            importResult = Result {
                let exportRoot = try LibraryExportFolderResolver.resolve(from: coordinatedURL)
                return try readCoordinatedExportFolder(
                    exportRoot,
                    audioURL: audioURL,
                    coversURL: coversURL
                )
            }
        }

        if let importResult {
            return try importResult.get()
        }
        throw coordinationError ?? LibraryTransferError.folderUnavailable
    }

    nonisolated private static func readCoordinatedExportFolder(
        _ folderURL: URL,
        audioURL: URL,
        coversURL: URL
    ) throws -> ImportedLibrary {
        let manager = FileManager.default
        let manifestURL = folderURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            LibraryExportManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.formatVersion == 1 else { throw LibraryTransferError.unsupportedFormat }

        var createdFiles: [URL] = []
        do {
            var importedTracks: [Track] = []
            for item in manifest.tracks {
                var audioFileName = ""
                if let relativePath = item.audioPath {
                    let source = try safeChildURL(relativePath, root: folderURL)
                    guard manager.fileExists(atPath: source.path) else { throw LibraryTransferError.missingAudio }
                    let extensionName = source.pathExtension.isEmpty ? "audio" : source.pathExtension
                    audioFileName = "\(UUID().uuidString).\(extensionName)"
                    let destination = audioURL.appendingPathComponent(audioFileName)
                    try manager.copyItem(at: source, to: destination)
                    createdFiles.append(destination)
                    try? manager.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: destination.path
                    )
                }

                var coverFileName: String?
                if let relativePath = item.coverPath {
                    let source = try safeChildURL(relativePath, root: folderURL)
                    let extensionName = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
                    let name = "\(UUID().uuidString).\(extensionName)"
                    let destination = coversURL.appendingPathComponent(name)
                    try manager.copyItem(at: source, to: destination)
                    createdFiles.append(destination)
                    coverFileName = name
                }

                var lyrics = item.lyrics
                if let relativePath = item.lyricsPath {
                    let source = try safeChildURL(relativePath, root: folderURL)
                    lyrics = try String(contentsOf: source, encoding: .utf8)
                }
                importedTracks.append(item.localTrack(
                    audioFileName: audioFileName,
                    coverFileName: coverFileName,
                    lyrics: lyrics
                ))
            }

            var importedPlaylists: [Playlist] = []
            let importedIDs = Set(importedTracks.map(\.id))
            for item in manifest.playlists {
                var coverFileName: String?
                if let relativePath = item.coverPath {
                    let source = try safeChildURL(relativePath, root: folderURL)
                    let extensionName = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
                    let name = "\(UUID().uuidString).\(extensionName)"
                    let destination = coversURL.appendingPathComponent(name)
                    try manager.copyItem(at: source, to: destination)
                    createdFiles.append(destination)
                    coverFileName = name
                }
                importedPlaylists.append(item.localPlaylist(
                    coverFileName: coverFileName,
                    allowedTrackIDs: importedIDs
                ))
            }
            return ImportedLibrary(
                tracks: importedTracks,
                playlists: importedPlaylists,
                selectedPlaylistID: manifest.selectedPlaylistID,
                queue: manifest.queue
            )
        } catch {
            for url in createdFiles { try? manager.removeItem(at: url) }
            throw error
        }
    }

    nonisolated private static func safeChildURL(_ relativePath: String, root: URL) throws -> URL {
        guard !relativePath.hasPrefix("/") else { throw LibraryTransferError.invalidPath }
        let standardizedRoot = root.standardizedFileURL.path + "/"
        let child = root.appendingPathComponent(relativePath).standardizedFileURL
        guard child.path.hasPrefix(standardizedRoot) else { throw LibraryTransferError.invalidPath }
        return child
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

    private func setBackgroundPlaybackFileProtection(for url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    nonisolated private static func prepareStorage(
        supportURL: URL,
        audioURL: URL,
        coversURL: URL,
        backupsURL: URL,
        recoveryURL: URL
    ) {
        let manager = FileManager.default
        try? manager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try? manager.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try? manager.createDirectory(at: coversURL, withIntermediateDirectories: true)
        try? manager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        try? manager.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: audioURL.path
        )
    }

    private func applyLocal(_ snapshot: LibrarySnapshot) {
        tracks = snapshot.tracks
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        playlists = snapshot.playlists
        selectedPlaylistID = snapshot.selectedPlaylistID
        queue = snapshot.queue
        trackTombstones = snapshot.trackTombstones ?? []
        albumTombstones = snapshot.albumTombstones ?? []
    }

    private func ensureDefaultPlaylist(shouldSave: Bool = true) {
        if playlists.isEmpty {
            playlists = [Playlist(name: "Offline Music", trackIDs: tracks.map(\.id))]
            selectedPlaylistID = playlists[0].id
            if shouldSave { save() }
        } else if selectedPlaylistID == nil {
            selectedPlaylistID = playlists[0].id
            if shouldSave { save() }
        }
    }

    nonisolated private static func loadBestSnapshot(
        primaryURL: URL,
        backupsURL: URL,
        recoveryURL: URL
    ) -> LibraryLoadResult {
        let manager = FileManager.default
        let decoder = JSONDecoder()

        if let data = try? Data(contentsOf: primaryURL),
           let snapshot = try? decoder.decode(LibrarySnapshot.self, from: data) {
            return LibraryLoadResult(snapshot: snapshot, source: .primary)
        }

        let primaryExists = manager.fileExists(atPath: primaryURL.path)
        if primaryExists {
            try? manager.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
            let quarantineURL = recoveryURL.appendingPathComponent(
                "damaged-library-\(Int(Date().timeIntervalSince1970)).json"
            )
            try? manager.copyItem(at: primaryURL, to: quarantineURL)
        }

        let backupURLs = (try? manager.contentsOfDirectory(
            at: backupsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in backupURLs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decoder.decode(LibrarySnapshot.self, from: data)
            else { continue }
            return LibraryLoadResult(snapshot: snapshot, source: .backup)
        }

        return LibraryLoadResult(
            snapshot: nil,
            source: primaryExists ? .corruptPrimary : .newLibrary
        )
    }

    nonisolated private static func persist(
        _ snapshot: LibrarySnapshot,
        to libraryURL: URL,
        backupsURL: URL
    ) {
        let manager = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let newData = try? encoder.encode(snapshot),
              (try? JSONDecoder().decode(LibrarySnapshot.self, from: newData)) != nil
        else { return }

        try? manager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        if let currentData = try? Data(contentsOf: libraryURL),
           (try? JSONDecoder().decode(LibrarySnapshot.self, from: currentData)) != nil {
            let previousURL = backupsURL.appendingPathComponent("previous-library.json")
            try? currentData.write(
                to: previousURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )

            let checkpointURLs = ((try? manager.contentsOfDirectory(
                at: backupsURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.lastPathComponent.hasPrefix("library-") }
            let newestCheckpointDate = checkpointURLs.compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.compactMap { $0 }.max()
            if newestCheckpointDate.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
                let backupURL = backupsURL.appendingPathComponent(
                    "library-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString).json"
                )
                try? currentData.write(
                    to: backupURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }
        }

        do {
            try newData.write(to: libraryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return
        }

        let backups = ((try? manager.contentsOfDirectory(
            at: backupsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent.hasPrefix("library-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for expired in backups.dropFirst(12) {
            try? manager.removeItem(at: expired)
        }
    }

    func syncNow() async {
        guard isLibraryReady, !isSyncing else { return }
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
        } catch LibrarySafetyError.destructiveCloudSnapshot {
            syncStatus = "Sync paused: destructive change blocked"
            dataSafetyStatus = "A cloud update tried to remove too much data and was blocked"
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
        let localIDs = Set(tracks.map(\.id))
        let remoteIDs = Set(remote.tracks.map(\.id))
        let missingIDs = localIDs.subtracting(remoteIDs)
        let tombstoneIDs = Set(remote.trackTombstones.map(\.id))
        let massRemovalLimit = max(5, Int(ceil(Double(max(localIDs.count, 1)) * 0.25)))
        let localAlbumIDs = Set(playlists.map(\.id))
        let remoteAlbumIDs = Set(remote.albums.map(\.id))
        let missingAlbumIDs = localAlbumIDs.subtracting(remoteAlbumIDs)
        let albumTombstoneIDs = Set(remote.albumTombstones.map(\.id))
        let massAlbumRemovalLimit = max(3, Int(ceil(Double(max(localAlbumIDs.count, 1)) * 0.34)))
        guard missingIDs.isSubset(of: tombstoneIDs),
              missingAlbumIDs.isSubset(of: albumTombstoneIDs),
              !(remoteIDs.isEmpty && !localIDs.isEmpty),
              !(remoteAlbumIDs.isEmpty && !localAlbumIDs.isEmpty),
              missingIDs.count < massRemovalLimit,
              missingAlbumIDs.count < massAlbumRemovalLimit
        else {
            createRecoverySnapshot(reason: "blocked-cloud-delete")
            throw LibrarySafetyError.destructiveCloudSnapshot
        }

        isApplyingCloudSnapshot = true
        defer { isApplyingCloudSnapshot = false }

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

        if !missingIDs.isEmpty || !missingAlbumIDs.isEmpty {
            createRecoverySnapshot(reason: "before-cloud-delete")
            for oldTrack in tracks where missingIDs.contains(oldTrack.id) {
                quarantineAudio(for: oldTrack)
            }
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

    private func createRecoverySnapshot(reason: String) {
        let snapshot = LibrarySnapshot(
            tracks: tracks,
            playlists: playlists,
            selectedPlaylistID: selectedPlaylistID,
            queue: queue,
            trackTombstones: trackTombstones,
            albumTombstones: albumTombstones
        )
        let recoveryURL = recoveryURL
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let name = "\(reason)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json"
            try? data.write(
                to: recoveryURL.appendingPathComponent(name),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    private func quarantineAudio(for track: Track) {
        guard !track.audioFileName.isEmpty else { return }
        let source = audioFileURL(for: track)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let removedAudioURL = recoveryURL.appendingPathComponent("Removed Audio", isDirectory: true)
        try? fileManager.createDirectory(at: removedAudioURL, withIntermediateDirectories: true)
        let destination = removedAudioURL.appendingPathComponent(
            "\(track.id.uuidString)-\(source.lastPathComponent)"
        )
        if !fileManager.fileExists(atPath: destination.path) {
            try? fileManager.moveItem(at: source, to: destination)
        }
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

private enum LibraryLoadSource {
    case primary
    case backup
    case newLibrary
    case corruptPrimary
}

private struct LibraryLoadResult {
    let snapshot: LibrarySnapshot?
    let source: LibraryLoadSource
}

private enum LibrarySafetyError: Error {
    case destructiveCloudSnapshot
}

private enum LibraryTransferError: LocalizedError {
    case unsupportedFormat
    case missingAudio
    case invalidPath
    case folderUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "This export format is not supported."
        case .missingAudio: return "An audio file listed in the manifest is missing."
        case .invalidPath: return "The export contains an unsafe file path."
        case .folderUnavailable: return "The selected folder is unavailable. Download it in Files and try again."
        }
    }
}

private struct LibraryExportManifest: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let tracks: [ExportedTrack]
    let playlists: [ExportedPlaylist]
    let selectedPlaylistID: UUID?
    let queue: [QueueEntry]
}

private struct ExportedTrack: Codable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let audioPath: String?
    let coverPath: String?
    let lyricsPath: String?
    let lyrics: String?
    let dateAdded: Date?
    let remoteAudioURL: URL?
    let remoteCoverURL: URL?
    let updatedAt: Date?

    init(track: Track, audioPath: String?, coverPath: String?, lyricsPath: String?) {
        id = track.id
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
        self.audioPath = audioPath
        self.coverPath = coverPath
        self.lyricsPath = lyricsPath
        lyrics = track.lyrics
        dateAdded = track.dateAdded
        remoteAudioURL = track.remoteAudioURL
        remoteCoverURL = track.remoteCoverURL
        updatedAt = track.updatedAt
    }

    func localTrack(audioFileName: String, coverFileName: String?, lyrics: String?) -> Track {
        Track(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            audioFileName: audioFileName,
            coverFileName: coverFileName,
            lyrics: lyrics,
            dateAdded: dateAdded,
            remoteAudioURL: remoteAudioURL,
            remoteCoverURL: remoteCoverURL,
            updatedAt: updatedAt
        )
    }
}

private struct ExportedPlaylist: Codable {
    let id: UUID
    let name: String
    let trackIDs: [UUID]
    let coverPath: String?
    let remoteCoverURL: URL?
    let updatedAt: Date?

    init(playlist: Playlist, coverPath: String?) {
        id = playlist.id
        name = playlist.name
        trackIDs = playlist.trackIDs
        self.coverPath = coverPath
        remoteCoverURL = playlist.remoteCoverURL
        updatedAt = playlist.updatedAt
    }

    func localPlaylist(coverFileName: String?, allowedTrackIDs: Set<UUID>) -> Playlist {
        Playlist(
            id: id,
            name: name,
            trackIDs: trackIDs.filter { allowedTrackIDs.contains($0) },
            coverFileName: coverFileName,
            remoteCoverURL: remoteCoverURL,
            updatedAt: updatedAt
        )
    }
}

private struct ImportedLibrary {
    let tracks: [Track]
    let playlists: [Playlist]
    let selectedPlaylistID: UUID?
    let queue: [QueueEntry]
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
