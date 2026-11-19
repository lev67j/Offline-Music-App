import SwiftUI
import UIKit

struct MCPSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var isImportingLibrary = false
    @State private var exportFolderURL: URL?
    @State private var isShowingExporter = false

    var body: some View {
        NavigationStack {
            List {
                Section("Playlists") {
                    NavigationLink {
                        PlaylistExportView()
                    } label: {
                        Label("Export playlists", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!library.isLibraryReady)
                }

                Section("Library safety") {
                    Label(library.dataSafetyStatus, systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)

                    Button {
                        Task {
                            if let folder = await library.makeExportFolder() {
                                exportFolderURL = folder
                                isShowingExporter = true
                            }
                        }
                    } label: {
                        Label("Export complete library", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        isImportingLibrary = true
                    } label: {
                        Label("Import exported folder", systemImage: "square.and.arrow.down")
                    }

                    if let status = library.transferStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("An export contains every audio file, cover, lyric, track field, playlist and queue in a readable folder with a versioned manifest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("ChatGPT, Claude / MCP") {
                    LabeledContent("Status") {
                        Text(library.syncStatus)
                            .foregroundStyle(library.syncStatus == "Connected" ? .green : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("MCP URL")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(OfflineMusicConfiguration.mcpURL.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Button {
                        UIPasteboard.general.string = OfflineMusicConfiguration.mcpURL.absoluteString
                    } label: {
                        Label("Copy MCP URL", systemImage: "doc.on.doc")
                    }

                    Link(destination: URL(string: "https://chatgpt.com/")!) {
                        Label("Open ChatGPT", systemImage: "arrow.up.right.square")
                    }
                }

                Section("One-time code") {
                    Button {
                        Task { await library.generateMCPLinkCode() }
                    } label: {
                        Label("Generate code", systemImage: "key.fill")
                    }
                    .disabled(library.syncStatus != "Connected")

                    if let code = library.mcpLinkCode {
                        Text(code.code)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .tracking(5)
                            .frame(maxWidth: .infinity)
                            .textSelection(.enabled)

                        Text("Enter this code on the authorization page that ChatGPT or Claude opens. It works once and expires in 10 minutes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Add the URL to ChatGPT or Claude first, then generate a code here when it asks you to connect.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Access") {
                    Label("Create and edit albums", systemImage: "checkmark.circle.fill")
                    Label("Add, edit and delete tracks", systemImage: "checkmark.circle.fill")
                    Label("Remove tracks from albums", systemImage: "checkmark.circle.fill")
                    Label("Tag tracks", systemImage: "checkmark.circle.fill")
                    Label("Set covers and lyrics", systemImage: "checkmark.circle.fill")
                    Label("Album deletion is blocked", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }

                Section("Connected apps") {
                    if library.mcpConnections.filter({ $0.revokedAt == nil }).isEmpty {
                        Text("No connected apps")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(library.mcpConnections.filter { $0.revokedAt == nil }) { connection in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(connection.appName)
                                    Text(connection.lastUsedAt?.formatted() ?? connection.createdAt.formatted())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) {
                                    Task { await library.revokeMCPConnection(connection.id) }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await library.syncNow()
                await library.refreshMCPConnections()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isImportingLibrary) {
            LibraryFolderImportPicker { folder in
                library.importLibraryFolder(from: folder)
            }
        }
        .sheet(isPresented: $isShowingExporter, onDismiss: {
            exportFolderURL = nil
        }) {
            if let exportFolderURL {
                LibraryFolderExportPicker(folderURL: exportFolderURL)
            }
        }
    }
}

private extension MCPConnection {
    var appName: String {
        let id = clientID.lowercased()
        if id.contains("chatgpt") || id.contains("openai") { return "ChatGPT" }
        if id.contains("claude") || id.hasPrefix("mcp-client-") { return "Claude" }
        return "MCP app"
    }
}

private struct PlaylistExportView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var selection: Set<UUID> = []
    @State private var isPreparing = false
    @State private var exportFolder: URL?
    @State private var isShowingFiles = false
    @State private var errorMessage = ""
    @State private var isShowingError = false

    private var availableSelection: Set<UUID> {
        selection.intersection(library.playlists.map(\.id))
    }

    var body: some View {
        List {
            if library.playlists.isEmpty {
                Text("No playlists to export")
                    .foregroundStyle(.secondary)
            }
            ForEach(library.playlists) { playlist in
                Toggle(isOn: Binding(
                    get: { selection.contains(playlist.id) },
                    set: { selected in
                        if selected {
                            selection.insert(playlist.id)
                        } else {
                            selection.remove(playlist.id)
                        }
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text(playlist.name)
                        Text("\(playlist.trackIDs.count) tracks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(isPreparing || isShowingFiles)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Export playlists")
        .navigationBarBackButtonHidden(isPreparing)
        .interactiveDismissDisabled(isPreparing)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isPreparing {
                    ProgressView()
                        .accessibilityLabel("Preparing export")
                } else {
                    Button("Export", action: prepareExport)
                        .disabled(availableSelection.isEmpty || isShowingFiles)
                }
            }
        }
        .sheet(isPresented: $isShowingFiles, onDismiss: {
            if let exportFolder {
                try? FileManager.default.removeItem(at: exportFolder)
            }
            exportFolder = nil
        }) {
            if let exportFolder {
                LibraryFolderExportPicker(folderURL: exportFolder) {
                    isShowingFiles = false
                }
            }
        }
        .alert("Export failed", isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func prepareExport() {
        let selected = availableSelection
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                exportFolder = try await library.makePlaylistExportFolder(for: selected)
                isShowingFiles = true
            } catch {
                errorMessage = error.localizedDescription
                isShowingError = true
            }
        }
    }
}
