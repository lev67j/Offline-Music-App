import Foundation
import Security

enum OfflineMusicConfiguration {
    static let serverBaseURL = URL(string: "https://lev11111-gtd-system-backend.hf.space/offline-music")!
    static let mcpURL = serverBaseURL.appendingPathComponent("mcp")
}

struct MCPLinkCode: Decodable {
    let code: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
    }
}

struct MCPConnection: Identifiable, Decodable {
    let id: UUID
    let clientID: String
    let createdAt: Date
    let lastUsedAt: Date?
    let revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case clientID = "client_id"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case revokedAt = "revoked_at"
    }
}

struct CloudLibrarySnapshot: Codable {
    var tracks: [CloudTrack]
    var albums: [CloudAlbum]
    var trackTombstones: [CloudTombstone]
    var albumTombstones: [CloudTombstone]
    var revision: Int?

    enum CodingKeys: String, CodingKey {
        case tracks, albums, revision
        case trackTombstones = "track_tombstones"
        case albumTombstones = "album_tombstones"
    }
}

struct CloudTrack: Codable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var audioURL: URL?
    var coverURL: URL?
    var lyrics: String?
    var dateAdded: Date?
    var updatedAt: Date

    init(_ track: Track) {
        id = track.id
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
        audioURL = track.remoteAudioURL
        coverURL = track.remoteCoverURL
        lyrics = track.lyrics
        dateAdded = track.dateAdded
        updatedAt = track.updatedAt ?? track.dateAdded ?? .distantPast
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, lyrics
        case audioURL = "audio_url"
        case coverURL = "cover_url"
        case dateAdded = "date_added"
        case updatedAt = "updated_at"
    }
}

struct CloudAlbum: Codable {
    let id: UUID
    var name: String
    var trackIDs: [UUID]
    var coverURL: URL?
    var updatedAt: Date

    init(_ playlist: Playlist) {
        id = playlist.id
        name = playlist.name
        trackIDs = playlist.trackIDs
        coverURL = playlist.remoteCoverURL
        updatedAt = playlist.updatedAt ?? .distantPast
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case trackIDs = "track_ids"
        case coverURL = "cover_url"
        case updatedAt = "updated_at"
    }
}

struct CloudTombstone: Codable {
    let id: UUID
    let updatedAt: Date

    init(_ tombstone: DeletionTombstone) {
        id = tombstone.id
        updatedAt = tombstone.updatedAt
    }

    var local: DeletionTombstone {
        DeletionTombstone(id: id, updatedAt: updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case updatedAt = "updated_at"
    }
}

actor OfflineMusicCloudClient {
    private let session: URLSession
    private let credentials = DeviceCredentialStore()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func sync(_ snapshot: CloudLibrarySnapshot) async throws -> CloudLibrarySnapshot {
        var request = try await authorizedRequest(path: "/api/v1/library/sync")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(snapshot)
        return try await send(request)
    }

    func createLinkCode() async throws -> MCPLinkCode {
        var request = try await authorizedRequest(path: "/api/v1/mcp/link_codes")
        request.httpMethod = "POST"
        return try await send(request)
    }

    func connections() async throws -> [MCPConnection] {
        try await send(authorizedRequest(path: "/api/v1/mcp/connections"))
    }

    func revokeConnection(_ id: UUID) async throws {
        var request = try await authorizedRequest(path: "/api/v1/mcp/connections/\(id.uuidString)")
        request.httpMethod = "DELETE"
        let _: RevocationResponse = try await send(request)
    }

    private func authorizedRequest(path: String) async throws -> URLRequest {
        let token = try await deviceToken()
        var request = URLRequest(url: OfflineMusicConfiguration.serverBaseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 45
        return request
    }

    private func deviceToken() async throws -> String {
        if let saved = credentials.load() {
            return saved
        }
        var request = URLRequest(url: OfflineMusicConfiguration.serverBaseURL.appendingPathComponent("/api/v1/device/register"))
        request.httpMethod = "POST"
        let response: DeviceRegistration = try await send(request)
        credentials.save(response.deviceToken)
        return response.deviceToken
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }()

    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: string)
                ?? ISO8601DateFormatter.standard.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        return value
    }()
}

private struct DeviceRegistration: Decodable {
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
    }
}

private struct RevocationResponse: Decodable {
    let revoked: Bool
}

private struct DeviceCredentialStore {
    private let service = "com.levvlasov.OfflineMusic"
    private let account = "cloud-device-token"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insertion = query
            insertion.merge(attributes) { _, new in new }
            SecItemAdd(insertion as CFDictionary, nil)
        }
    }
}

private extension ISO8601DateFormatter {
    static let standard = ISO8601DateFormatter()
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
