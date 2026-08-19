import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: MusicPlayer

    @State private var isImporting = false
    @State private var isShowingQueue = false
    @State private var isCreatingPlaylist = false
    @State private var playlistPendingRename: Playlist?
    @State private var playlistPendingDeletion: Playlist?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var artworkTrackID: UUID?
    @State private var isShowingMCPSettings = false
    @State private var didRecordFirstFrame = false
    @State private var albumAccentColor = ArtworkPalette.fallbackAccent

    var body: some View {
        Group {
            if library.isLibraryReady {
                libraryContent
            } else {
                launchContent
            }
        }
        .tint(albumAccentColor)
        .accentColor(albumAccentColor)
        .task { await library.start() }
        .task(id: selectedPlaylistArtworkURL?.path) {
            guard let path = selectedPlaylistArtworkURL?.path else {
                albumAccentColor = ArtworkPalette.fallbackAccent
                return
            }

            let palette = await Task.detached(priority: .utility) {
                ArtworkPalette.colors(fromImageAt: path)
            }.value
            withAnimation(.easeInOut(duration: 0.35)) {
                albumAccentColor = ArtworkPalette.accentColor(from: palette)
            }
        }
        .onAppear {
            guard !didRecordFirstFrame else { return }
            didRecordFirstFrame = true
            let elapsed = ProcessInfo.processInfo.systemUptime - LaunchPerformance.processStartedAt
            LaunchPerformance.logger
                .notice("First UI frame ready in \(elapsed, format: .fixed(precision: 3)) seconds")
        }
        .sheet(isPresented: $isImporting) {
            AudioDocumentPicker { urls in
                library.importAudioFiles(from: urls)
            }
        }
        .sheet(isPresented: $isShowingQueue) {
            QueueView()
                .environmentObject(library)
                .environmentObject(player)
        }
        .sheet(isPresented: $isCreatingPlaylist) {
            NewPlaylistView()
                .environmentObject(library)
        }
        .sheet(isPresented: $isShowingMCPSettings) {
            MCPSettingsView()
                .environmentObject(library)
        }
        .sheet(item: $playlistPendingRename) { playlist in
            RenamePlaylistView(playlist: playlist)
                .environmentObject(library)
        }
        .alert(
            "Delete Playlist?",
            isPresented: Binding(
                get: { playlistPendingDeletion != nil },
                set: { if !$0 { playlistPendingDeletion = nil } }
            ),
            presenting: playlistPendingDeletion
        ) { playlist in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                library.deletePlaylist(playlist.id)
                playlistPendingDeletion = nil
            }
        } message: { playlist in
            Text("\u{201c}\(playlist.name)\u{201d} will be deleted. Its tracks will remain available in other playlists.")
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { artworkTrackID != nil },
                set: { if !$0 { artworkTrackID = nil } }
            )
        ) {
            if let artworkTrackID {
                NowPlayingArtworkView(trackID: artworkTrackID)
                .environmentObject(library)
                .environmentObject(player)
            }
        }
        .onChange(of: coverPickerItem) { _, newItem in
            guard let newItem else { return }

            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        library.setSelectedPlaylistCover(data: data)
                    }
                }

                await MainActor.run {
                    coverPickerItem = nil
                }
            }
        }
    }

    private var libraryContent: some View {
        ZStack(alignment: .bottom) {
            AppBackground(
                artworkURL: library.playlistCoverURL(for: library.selectedPlaylist)
            )

            ScrollView {
                VStack(spacing: 28) {
                    topBar
                    playlistHeader
                    trackSection
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 128)
            }
            .scrollIndicators(.hidden)

            PlayerIsland(
                isShowingQueue: $isShowingQueue,
                artworkTrackID: $artworkTrackID
            )
                .environmentObject(library)
                .environmentObject(player)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
        }
    }

    private var selectedPlaylistArtworkURL: URL? {
        library.playlistCoverURL(for: library.selectedPlaylist)
    }

    private var launchContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text("Offline Music")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                ProgressView()
                    .tint(Color.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline Music is loading your protected library")
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(library.playlists) { playlist in
                    Button {
                        withAnimation(.smooth(duration: 0.22)) {
                            library.selectPlaylist(playlist.id)
                        }
                    } label: {
                        Label(
                            playlist.name,
                            systemImage: playlist.id == library.selectedPlaylist?.id
                                ? "checkmark"
                                : "music.note.list"
                        )
                    }
                }

                Divider()

                Button {
                    isCreatingPlaylist = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }

                if let selectedPlaylist = library.selectedPlaylist {
                    Button {
                        playlistPendingRename = selectedPlaylist
                    } label: {
                        Label("Rename Playlist", systemImage: "pencil")
                    }

                    if library.playlists.count > 1 {
                        Button(role: .destructive) {
                            playlistPendingDeletion = selectedPlaylist
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "music.note.list")

                    Text(library.selectedPlaylist?.name ?? "Playlist")
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .spotifyCapsule()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .accessibilityLabel("Switch playlist")
            .accessibilityValue(library.selectedPlaylist?.name ?? "Playlist")

            Spacer(minLength: 10)

            Button {
                isShowingMCPSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .spotifyCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("ChatGPT and MCP settings")

            Button {
                isImporting = true
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .spotifyCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Import tracks")
        }
    }

    private var playlistHeader: some View {
        VStack(spacing: 20) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    url: library.playlistCoverURL(
                        for: library.selectedPlaylist
                    ),
                    size: 260,
                    cornerRadius: 20
                )
                .shadow(
                    color: .black.opacity(0.32),
                    radius: 28,
                    y: 18
                )

                PhotosPicker(
                    selection: $coverPickerItem,
                    matching: .images
                ) {
                    Image(systemName: "pencil")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 46, height: 46)
                        .spotifyCircle()
                        .padding(14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set playlist cover")
            }

            VStack(spacing: 7) {
                Text(library.selectedPlaylist?.name ?? "Offline Music")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                Text(playlistSummary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.52))
            }

            HStack(spacing: 16) {
                Button {
                    player.playSelectedPlaylist()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .mainActionButton()
                }
                .buttonStyle(.plain)
                .disabled(library.selectedTracks.isEmpty)

                Button {
                    player.toggleShuffle()
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .mainActionButton(isActive: player.isShuffleEnabled)
                }
                .buttonStyle(.plain)
                .disabled(library.selectedTracks.isEmpty)
                .accessibilityValue(player.isShuffleEnabled ? "On" : "Off")
            }
        }
    }

    private var playlistSummary: String {
        let tracks = library.selectedTracks
        let duration = tracks.reduce(0) { $0 + $1.duration }
        let count = "\(tracks.count) \(tracks.count == 1 ? "track" : "tracks")"
        guard duration > 0 else { return count }
        return "\(count)  •  \(duration.formattedPlaylistDuration)"
    }

    private var trackSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Song")

                Spacer()

                Button {
                    withAnimation(.smooth(duration: 0.24)) {
                        library.shuffleSelectedPlaylistOrder()
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(library.selectedTracks.count < 2)
                .accessibilityLabel("Shuffle track order")
                .accessibilityHint("Randomizes and saves the order of tracks in this playlist")

                Button {
                    withAnimation(.smooth(duration: 0.24)) {
                        library.sortSelectedPlaylistNewestFirst()
                    }
                } label: {
                    Image(systemName: "calendar.badge.clock")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(library.selectedTracks.count < 2)
                .accessibilityLabel("Sort newest first")
                .accessibilityHint("Places recently added tracks first and saves the order")

                Text("Time")
                    .frame(width: 56, alignment: .trailing)

                Spacer()
                    .frame(width: 44)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .padding(.bottom, 12)

            if library.selectedTracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(
                            .system(
                                size: 40,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.secondary)

                    Text("No Tracks")
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .padding(.bottom, 28)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(library.selectedTracks) { track in
                        TrackRow(track: track)
                            .environmentObject(library)
                            .environmentObject(player)

                        Divider()
                            .padding(.leading, 74)
                    }
                }
            }
        }
    }
}

private struct TrackRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: MusicPlayer

    let track: Track

    var body: some View {
        HStack(spacing: 0) {
            Button {
                player.playTrackFromSelectedPlaylist(track.id)
            } label: {
                HStack(spacing: 14) {
                    ArtworkView(
                        url: library.coverFileURL(named: track.coverFileName),
                        size: 56,
                        cornerRadius: 10
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(
                                .body.weight(
                                    player.currentTrackID == track.id
                                        ? .semibold
                                        : .regular
                                )
                            )
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("\(track.artist) - \(track.album)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.duration.formattedDuration)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)

            trackMenu
        }
        .padding(.vertical, 12)
    }

    private var trackMenu: some View {
        Menu {
            Button {
                library.addToQueue(track.id)
            } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }

            Menu("Add to Playlist") {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) {
                        library.add(
                            track.id,
                            to: playlist.id
                        )
                    }
                }
            }

            if let playlistID = library.selectedPlaylist?.id {
                Button(
                    "Remove from Playlist",
                    role: .destructive
                ) {
                    library.remove(
                        track.id,
                        from: playlistID
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Track actions")
    }
}

private struct PlayerIsland: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: MusicPlayer

    @Binding var isShowingQueue: Bool
    @Binding var artworkTrackID: UUID?

    var body: some View {
        HStack(spacing: 8) {
            if let track = player.currentTrack {
                Button {
                    artworkTrackID = track.id
                } label: {
                    ArtworkView(
                        url: library.coverFileURL(named: track.coverFileName),
                        size: 52,
                        cornerRadius: 12
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if track.hasLyrics {
                            Image(systemName: "text.quote")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.62), in: Circle())
                                .offset(x: 4, y: 4)
                        }
                    }
                }
                .accessibilityLabel("Open now playing artwork")
                .accessibilityHint("Shows a large cover for \(track.title)")
            }

            Button {
                player.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 38, height: 44)
            }
            .disabled(player.currentTrackID == nil)
            .accessibilityLabel("Previous track")

            Button {
                player.togglePlayPause()
            } label: {
                Image(
                    systemName: player.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .font(.title.weight(.semibold))
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 38, height: 44)
            }
            .disabled(player.currentTrackID == nil)
            .accessibilityLabel("Next track")

            Button {
                player.cycleRepeatMode()
            } label: {
                RepeatIcon(mode: player.repeatMode)
                    .frame(width: 42, height: 44)
            }
            .accessibilityLabel(repeatAccessibilityLabel)

            Spacer(minLength: 8)

            Button {
                isShowingQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title2.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Up next")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 74)
        .background(
            .ultraThinMaterial,
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(
            color: .black.opacity(0.14),
            radius: 24,
            y: 12
        )
        .buttonStyle(.plain)
    }

    private var repeatAccessibilityLabel: String {
        switch player.repeatMode {
        case .off: return "Repeat off"
        case .once: return "Repeat current track"
        case .continuous: return "Repeat playlist"
        }
    }
}

private struct NowPlayingArtworkView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: MusicPlayer

    let trackID: UUID
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var backgroundColors = ArtworkPalette.fallback
    @State private var isEditingLyrics = false
    @State private var lyricsDraft = ""

    var body: some View {
        ZStack {
            artworkBackground

            if let track = library.track(id: trackID) {
                let coverURL = library.coverFileURL(named: track.coverFileName)

                ScrollView {
                    VStack(spacing: 0) {
                        HStack {
                            Button { dismiss() } label: {
                                Label("Back", systemImage: "arrow.left")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 15)
                                    .frame(height: 44)
                                    .spotifyCapsule()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back")

                            Spacer()
                        }

                        PhotosPicker(selection: $coverPickerItem, matching: .images) {
                            ArtworkView(
                                url: coverURL,
                                size: min(UIScreen.main.bounds.width - 48, 390),
                                cornerRadius: 24
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(.white.opacity(0.15), lineWidth: 1)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.headline.weight(.semibold))
                                    .frame(width: 48, height: 48)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .padding(14)
                            }
                            .shadow(color: .black.opacity(0.48), radius: 34, y: 22)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Change track artwork")
                        .padding(.top, 12)

                        VStack(spacing: 7) {
                            Text(track.title)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)

                            Text(track.artist)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)

                            if !track.album.isEmpty && track.album != "Unknown Album" {
                                Text(track.album)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.42))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.top, 24)

                        if player.currentTrackID == track.id {
                            PlaybackScrubber()
                                .padding(.top, 24)
                        }

                        if isEditingLyrics {
                            VStack(spacing: 14) {
                                TextEditor(text: $lyricsDraft)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                    .scrollContentBackground(.hidden)
                                    .padding(10)
                                    .frame(minHeight: 320)
                                    .background(
                                        .black.opacity(0.2),
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(.white.opacity(0.16), lineWidth: 1)
                                    }

                                HStack(spacing: 12) {
                                    Button("Cancel") {
                                        withAnimation(.smooth(duration: 0.2)) {
                                            isEditingLyrics = false
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .spotifyCapsule()

                                    Button("Save") {
                                        library.setLyrics(lyricsDraft, for: track.id)
                                        withAnimation(.smooth(duration: 0.2)) {
                                            isEditingLyrics = false
                                        }
                                    }
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(Color.accentColor, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.top, 32)
                        } else if track.hasLyrics {
                            VStack(alignment: .leading, spacing: 12) {
                                lyricsEditButton(for: track)

                                ForEach(Array(lyricLines(for: track).enumerated()), id: \.offset) { _, line in
                                    LyricLineView(line: line)
                                }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 32)
                        } else {
                            VStack(spacing: 14) {
                                Text("No lyrics")
                                    .font(.title3.weight(.semibold))

                                lyricsEditButton(for: track)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 36)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 48)
                    .foregroundStyle(.white)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task(id: artworkURL?.path) {
            guard let path = artworkURL?.path else {
                backgroundColors = ArtworkPalette.fallback
                return
            }

            let colors = await Task.detached(priority: .userInitiated) {
                ArtworkPalette.colors(fromImageAt: path)
            }.value

            withAnimation(.easeInOut(duration: 0.45)) {
                backgroundColors = colors
            }
        }
        .tint(ArtworkPalette.accentColor(from: backgroundColors))
        .accentColor(ArtworkPalette.accentColor(from: backgroundColors))
        .onChange(of: coverPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        library.setCover(data: data, for: trackID)
                        player.refreshNowPlayingInfo()
                    }
                }
                await MainActor.run { coverPickerItem = nil }
            }
        }
    }

    private func lyricLines(for track: Track) -> [String] {
        (track.lyrics ?? "").components(separatedBy: .newlines)
    }

    private func lyricsEditButton(for track: Track) -> some View {
        Button {
            lyricsDraft = track.lyrics ?? ""
            withAnimation(.smooth(duration: 0.2)) {
                isEditingLyrics = true
            }
        } label: {
            Label(track.hasLyrics ? "Edit Lyrics" : "Add Lyrics", systemImage: "pencil")
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .spotifyCapsule()
        }
        .buttonStyle(.plain)
    }

    private var artworkURL: URL? {
        guard let track = library.track(id: trackID) else { return nil }
        return library.coverFileURL(named: track.coverFileName)
    }

    private var artworkBackground: some View {
        ZStack {
            LinearGradient(
                colors: backgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [backgroundColors[1].opacity(0.9), .clear],
                center: UnitPoint(x: 0.88, y: 0.15),
                startRadius: 0,
                endRadius: 430
            )

            LinearGradient(
                colors: [.black.opacity(0.08), .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct PlaybackScrubber: View {
    @EnvironmentObject private var player: MusicPlayer

    @State private var draggedPosition: TimeInterval = 0
    @State private var isDragging = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(player.playbackDuration, 0)
            let position = min(isDragging ? draggedPosition : player.playbackPosition, duration)

            HStack(alignment: .top, spacing: 10) {
                Button {
                    player.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous track")

                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { position },
                            set: { draggedPosition = $0 }
                        ),
                        in: 0...max(duration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                draggedPosition = player.playbackPosition
                            } else {
                                player.seek(to: draggedPosition)
                            }
                            isDragging = editing
                        }
                    )
                    .tint(.white)
                    .disabled(duration <= 0)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(formattedTime(position)) of \(formattedTime(duration))")

                    HStack {
                        Text(formattedTime(position))
                        Spacer()
                        Text(formattedTime(duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
                }

                Button {
                    player.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
            }
        }
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let totalSeconds = Int(time.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

private struct LyricLineView: View {
    let line: String

    var body: some View {
        styledLine
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(line)
    }

    private var styledLine: Text {
        guard !line.isEmpty else {
            return Text(" ").font(.system(size: 16))
        }

        let source = line as NSString
        let pattern = #"\([^)]*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return mainText(line)
        }

        let matches = expression.matches(
            in: line,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return mainText(line) }

        var result = Text("")
        var location = 0

        for match in matches {
            if match.range.location > location {
                let mainRange = NSRange(location: location, length: match.range.location - location)
                result = result + mainText(source.substring(with: mainRange))
            }

            result = result + Text(source.substring(with: match.range))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.68))
            location = NSMaxRange(match.range)
        }

        if location < source.length {
            result = result + mainText(source.substring(from: location))
        }

        return result
    }

    private func mainText(_ value: String) -> Text {
        Text(value)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .foregroundColor(.white)
    }
}

private struct RepeatIcon: View {
    let mode: RepeatMode

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "repeat")
                .font(.title3.weight(.semibold))
                .foregroundStyle(
                    mode == .off
                        ? .secondary
                        : Color.accentColor
                )

            if mode == .once {
                Text("1")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .offset(x: 4, y: -4)
            }
        }
    }
}

private struct QueueView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.queue) { entry in
                    if let track = library.track(
                        id: entry.trackID
                    ) {
                        HStack(spacing: 0) {
                            Button {
                                player.playQueueEntry(entry.id)
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(
                                        url: library.coverFileURL(
                                            named: track.coverFileName
                                        ),
                                        size: 46,
                                        cornerRadius: 7
                                    )

                                    VStack(
                                        alignment: .leading,
                                        spacing: 3
                                    ) {
                                        Text(track.title)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Text(track.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Play \(track.title)")

                            Button(role: .destructive) {
                                library.removeQueueEntry(entry.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Up Next")
            .toolbar {
                ToolbarItem(
                    placement: .topBarLeading
                ) {
                    Button {
                        withAnimation(.smooth(duration: 0.22)) {
                            library.shuffleQueue()
                        }
                    } label: {
                        Label("Shuffle Queue", systemImage: "shuffle")
                    }
                    .disabled(library.queue.count < 2)
                }

                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct NewPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    "Playlist name",
                    text: $name
                )
            }
            .navigationTitle("New Playlist")
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(
                    placement: .confirmationAction
                ) {
                    Button("Create") {
                        library.createPlaylist(named: name)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct RenamePlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    let playlist: Playlist
    @State private var name: String

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name", text: $name)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .navigationTitle("Rename Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        library.renamePlaylist(playlist.id, to: trimmedName)
        dismiss()
    }
}

private struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat
    @State private var artwork: UIImage?

    var body: some View {
        Group {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else if let defaultCover = UIImage(
                named: "DefaultCover"
            ) {
                Image(uiImage: defaultCover)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(
                        Color(
                            uiColor: .secondarySystemBackground
                        )
                    )
                    .overlay {
                        Image(systemName: "music.note")
                            .font(
                                .system(
                                    size: size * 0.28,
                                    weight: .bold
                                )
                            )
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(
            width: size,
            height: size
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
        )
        .clipped()
        .task(id: url) {
            artwork = nil
            guard let path = url?.path else { return }
            artwork = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: path)?.preparingForDisplay()
            }.value
        }
    }
}

private struct AppBackground: View {
    let artworkURL: URL?
    @State private var colors = ArtworkPalette.fallback

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [colors[1].opacity(0.72), .clear],
                center: UnitPoint(x: 0.78, y: 0.02),
                startRadius: 0,
                endRadius: 480
            )

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .task(id: artworkURL?.path) {
            guard let path = artworkURL?.path else {
                withAnimation(.easeInOut(duration: 0.35)) {
                    colors = ArtworkPalette.fallback
                }
                return
            }
            let palette = await Task.detached(priority: .utility) {
                ArtworkPalette.colors(fromImageAt: path)
            }.value
            withAnimation(.easeInOut(duration: 0.45)) {
                colors = palette
            }
        }
    }
}

private extension View {
    func spotifyCapsule() -> some View {
        background(
            .ultraThinMaterial,
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    func spotifyCircle() -> some View {
        background(
            .ultraThinMaterial,
            in: Circle()
        )
        .overlay {
            Circle()
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    func mainActionButton(isActive: Bool = true) -> some View {
        font(.headline.weight(.semibold))
            .foregroundStyle(isActive ? .black : .white.opacity(0.58))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                isActive ? Color.accentColor : Color.white.opacity(0.1),
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        guard isFinite, self > 0 else {
            return "--:--"
        }

        let totalSeconds = Int(self.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    var formattedPlaylistDuration: String {
        let totalMinutes = Int(self / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
    }
}
