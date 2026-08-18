import SwiftUI

@main
struct OfflineMusicApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: LibraryStore
    @StateObject private var player: MusicPlayer

    init() {
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
            if phase == .active {
                Task { await library.syncNow() }
            }
        }
    }
}
