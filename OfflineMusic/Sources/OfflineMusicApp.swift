import SwiftUI
import OSLog

@MainActor
enum LaunchPerformance {
    static var processStartedAt: TimeInterval = 0
    static let logger = Logger(subsystem: "com.levvlasov.OfflineMusic", category: "Launch")

    static func begin() {
        guard processStartedAt == 0 else { return }
        processStartedAt = ProcessInfo.processInfo.systemUptime
    }
}

@main
struct OfflineMusicApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: LibraryStore
    @StateObject private var player: MusicPlayer

    init() {
        LaunchPerformance.begin()
        let library = LibraryStore()
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: MusicPlayer(library: library))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, library.isLibraryReady {
                Task { await library.syncNow() }
            }
        }
    }
}
