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
