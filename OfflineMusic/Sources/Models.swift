import Foundation

struct Track: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var audioFileName: String
    var coverFileName: String?
    var lyrics: String?
    var dateAdded: Date?
    var remoteAudioURL: URL?
    var remoteCoverURL: URL?
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        audioFileName: String,
        coverFileName: String? = nil,
        lyrics: String? = nil,
        dateAdded: Date? = nil,
        remoteAudioURL: URL? = nil,
        remoteCoverURL: URL? = nil,
        updatedAt: Date? = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.audioFileName = audioFileName
        self.coverFileName = coverFileName
        self.lyrics = lyrics
        self.dateAdded = dateAdded
        self.remoteAudioURL = remoteAudioURL
        self.remoteCoverURL = remoteCoverURL
        self.updatedAt = updatedAt
    }
}

extension Track {
    var hasLyrics: Bool {
        !(lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

struct Playlist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var trackIDs: [UUID]
    var coverFileName: String?
    var remoteCoverURL: URL?
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        trackIDs: [UUID] = [],
        coverFileName: String? = nil,
        remoteCoverURL: URL? = nil,
        updatedAt: Date? = Date()
    ) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.coverFileName = coverFileName
        self.remoteCoverURL = remoteCoverURL
        self.updatedAt = updatedAt
    }
}

struct QueueEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let trackID: UUID

    init(id: UUID = UUID(), trackID: UUID) {
        self.id = id
        self.trackID = trackID
    }
}

enum RepeatMode: String, Codable, Equatable {
    case off
    case once
    case continuous

    var next: RepeatMode {
        switch self {
        case .off:
            return .once
        case .once:
            return .continuous
        case .continuous:
            return .off
        }
    }
}

struct LibrarySnapshot: Codable {
    var schemaVersion: Int
    var savedAt: Date
    var tracks: [Track]
    var playlists: [Playlist]
    var selectedPlaylistID: UUID?
    var queue: [QueueEntry]
    var trackTombstones: [DeletionTombstone]?
    var albumTombstones: [DeletionTombstone]?

    init(
        schemaVersion: Int = 2,
        savedAt: Date = Date(),
        tracks: [Track],
        playlists: [Playlist],
        selectedPlaylistID: UUID?,
        queue: [QueueEntry],
        trackTombstones: [DeletionTombstone]? = [],
        albumTombstones: [DeletionTombstone]? = []
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.tracks = tracks
        self.playlists = playlists
        self.selectedPlaylistID = selectedPlaylistID
        self.queue = queue
        self.trackTombstones = trackTombstones
        self.albumTombstones = albumTombstones
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, savedAt, tracks, playlists, selectedPlaylistID, queue
        case trackTombstones, albumTombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? .distantPast
        tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        playlists = try container.decodeIfPresent([Playlist].self, forKey: .playlists) ?? []
        selectedPlaylistID = try container.decodeIfPresent(UUID.self, forKey: .selectedPlaylistID)
        queue = try container.decodeIfPresent([QueueEntry].self, forKey: .queue) ?? []
        trackTombstones = try container.decodeIfPresent([DeletionTombstone].self, forKey: .trackTombstones) ?? []
        albumTombstones = try container.decodeIfPresent([DeletionTombstone].self, forKey: .albumTombstones) ?? []
    }
}

struct DeletionTombstone: Codable, Equatable {
    let id: UUID
    let updatedAt: Date
}

enum LibraryExportFolderResolver {
    enum Failure: LocalizedError {
        case manifestNotFound
        case multipleExports

        var errorDescription: String? {
            switch self {
            case .manifestNotFound:
                return "No Offline Music export was found. Select the exported folder that contains manifest.json and Tracks."
            case .multipleExports:
                return "This folder contains several Offline Music exports. Select one export folder."
            }
        }
    }

    /// File providers do not all return the same directory level. Resolve the
    /// export itself, a directory containing one export, or a visible child such
    /// as Tracks without recursively scanning unrelated user files.
    static func resolve(from selectedURL: URL, manager: FileManager = .default) throws -> URL {
        let selectedURL = selectedURL.standardizedFileURL

        if manager.fileExists(atPath: selectedURL.appendingPathComponent("manifest.json").path) {
            return selectedURL
        }

        let children = (try? manager.contentsOfDirectory(
            at: selectedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let childExports = children.filter {
            manager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
        if childExports.count == 1, let export = childExports.first {
            return export.standardizedFileURL
        }
        if childExports.count > 1 {
            throw Failure.multipleExports
        }

        var ancestor = selectedURL
        for _ in 0..<2 {
            let parent = ancestor.deletingLastPathComponent().standardizedFileURL
            guard parent != ancestor else { break }
            if manager.fileExists(atPath: parent.appendingPathComponent("manifest.json").path) {
                return parent
            }
            ancestor = parent
        }

        throw Failure.manifestNotFound
    }
}
