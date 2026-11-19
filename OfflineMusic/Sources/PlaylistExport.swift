import Foundation

enum PlaylistExport {
    static func makeFolder(
        playlists: [Playlist],
        tracksByID: [UUID: Track],
        audioURL: URL,
        coversURL: URL
    ) throws -> URL {
        let manager = FileManager.default
        let date = Date().formatted(.iso8601.year().month().day())
        let root = manager.temporaryDirectory.appendingPathComponent(
            "Offline Music Playlists \(date) \(UUID().uuidString.prefix(8))", isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: false)

        do {
            for (index, playlist) in playlists.enumerated() {
                let name = "\(position(index, count: playlists.count)) \(safeName(playlist.name, fallback: "Playlist"))"
                let folder = root.appendingPathComponent(name, isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: false)

                if let cover = playlist.coverFileName {
                    try copyCover(cover, named: "Playlist Cover", from: coversURL, to: folder)
                }

                var entries = ["#EXTM3U"]
                for (trackIndex, id) in playlist.trackIDs.enumerated() {
                    guard let track = tracksByID[id] else {
                        throw Failure.missingTrack(playlist.name, trackIndex + 1)
                    }
                    let source = audioURL.appendingPathComponent(track.audioFileName)
                    guard !track.audioFileName.isEmpty, manager.fileExists(atPath: source.path) else {
                        throw Failure.missingAudio(track.title, playlist.name)
                    }

                    let prefix = position(trackIndex, count: playlist.trackIDs.count)
                    let label = track.artist.isEmpty ? track.title : "\(track.artist) - \(track.title)"
                    let stem = "\(prefix) \(safeName(label, fallback: "Track"))"
                    let extensionName = source.pathExtension
                    let audioName = extensionName.isEmpty ? stem : "\(stem).\(extensionName)"
                    try manager.copyItem(at: source, to: folder.appendingPathComponent(audioName))
                    entries.append("./\(audioName)")

                    if let cover = track.coverFileName {
                        try copyCover(cover, named: "\(stem) - Cover", from: coversURL, to: folder)
                    }
                    if let lyrics = track.lyrics, track.hasLyrics {
                        try lyrics.write(to: folder.appendingPathComponent("\(stem) - Lyrics.txt"), atomically: true, encoding: .utf8)
                    }
                }

                try (entries.joined(separator: "\n") + "\n").write(
                    to: folder.appendingPathComponent("Playlist.m3u8"), atomically: true, encoding: .utf8
                )
            }
            return root
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }

    private static func copyCover(_ fileName: String, named name: String, from sourceFolder: URL, to folder: URL) throws {
        let source = sourceFolder.appendingPathComponent(fileName)
        let extensionName = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("\(name).\(extensionName)"))
    }

    private static func position(_ index: Int, count: Int) -> String {
        let number = String(index + 1)
        return String(repeating: "0", count: max(2, String(count).count) - number.count) + number
    }

    private static func safeName(_ name: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
            .union(.newlines)
        let cleaned = name.components(separatedBy: forbidden).joined(separator: " ")
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= 160 else { break }
            result.append(character)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return result.isEmpty ? fallback : result
    }

    private enum Failure: LocalizedError {
        case missingTrack(String, Int)
        case missingAudio(String, String)

        var errorDescription: String? {
            switch self {
            case let .missingTrack(playlist, position):
                return "Track \(position) in “\(playlist)” is missing from the library."
            case let .missingAudio(track, playlist):
                return "The audio file for “\(track)” in “\(playlist)” is unavailable on this device."
            }
        }
    }
}
