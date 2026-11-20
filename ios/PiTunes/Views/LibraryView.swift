import SwiftUI

struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var showNewPlaylist = false
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SongListView(title: "Liked Songs", downloadKey: Downloads.likedKey, load: API.likes)
                } label: { LibraryRow(icon: "heart.fill", title: "Liked Songs", subtitle: "\(library.likedIDs.count) songs") }
                NavigationLink {
                    DownloadsView()
                } label: { LibraryRow(icon: "arrow.down", title: "Downloads", subtitle: "On this iPhone") }
                NavigationLink {
                    SongListView(title: "History", load: API.history)
                } label: { LibraryRow(icon: "clock.arrow.circlepath", title: "History", subtitle: "Recently played") }
            }
            .themedRow()
            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    NavigationLink(value: playlist) {
                        LibraryRow(icon: "music.note.list", title: playlist.name,
                                   subtitle: "\(playlist.songCount) songs", gradient: false)
                    }
                }
                .onDelete { offsets in
                    for i in offsets {
                        let p = library.playlists[i]
                        Task { await library.deletePlaylist(p) }
                    }
                }
                Button { showNewPlaylist = true } label: {
                    LibraryRow(icon: "plus", title: "New Playlist", subtitle: nil, gradient: false)
                }
            }
            .themedRow()
            if !library.saved.isEmpty {
                Section("Artists") {
                    ForEach(library.saved) { ItemRow(item: $0) }
                        .onDelete { offsets in
                            for item in offsets.map({ library.saved[$0] }) {
                                Task { await library.toggleSaved(item) }
                            }
                        }
                }
            }
            if let error = library.error { Notice(text: error) }
        }
        .themedList()
        .navigationTitle("Library")
        .navigationDestination(for: PlaylistSummary.self) { PlaylistView(summary: $0) }
        .browseDestinations()
        .toolbar {
            NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gear") }
        }
        .refreshable { await library.refresh() }
        .task { await library.refresh() }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName
                newName = ""
                Task { await library.createPlaylist(named: name) }
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

struct PlaylistView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    let summary: PlaylistSummary
    @State private var songs: [Song] = []
    @State private var error: String?

    var body: some View {
        List {
            if !songs.isEmpty { PlayShuffleButtons(songs: songs) }
            ForEach(Array(songs.enumerated()), id: \.element.itemId) { i, song in
                SongRow(song: song) { player.play(songs, startAt: i) }
            }
            .onDelete { offsets in
                let removed = offsets.compactMap { songs[$0].itemId }
                songs.remove(atOffsets: offsets)
                Task {
                    for itemID in removed { _ = try? await API.removeFromPlaylist(summary.id, itemID: itemID) }
                    await library.refresh()
                }
            }
            .onMove { from, to in
                songs.move(fromOffsets: from, toOffset: to)
                let order = songs.compactMap(\.itemId)
                Task { await save { try await API.reorderPlaylist(summary.id, itemIDs: order) } }
            }
            if let error { Notice(text: error, isError: !error.hasPrefix("Offline")) }
        }
        .themedList()
        .navigationTitle(summary.name)
        .toolbar {
            DownloadButton(key: Downloads.key(playlist: summary.id), name: summary.name, songs: songs)
            EditButton()
        }
        .overlay {
            if songs.isEmpty && error == nil {
                ContentUnavailableView("Empty playlist", systemImage: "music.note.list",
                                       description: Text("Add songs with the ••• menu on any song."))
            }
        }
        .task { await save { try await API.playlist(summary.id) } }
        .refreshable { await save { try await API.playlist(summary.id) } }
    }

    /// Run a server call that returns the updated playlist, and show it.
    private func save(_ call: () async throws -> Playlist) async {
        let key = Downloads.key(playlist: summary.id)
        do {
            songs = try await call().songs
            error = nil
            Downloads.shared.refresh(key, songs: songs)
        } catch {
            // Offline: show the downloaded copy if there is one.
            if let saved = Downloads.shared.songs(in: key) {
                songs = saved
                self.error = "Offline: showing downloaded songs"
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Library list row: icon tile + title + subtitle.
struct LibraryRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    var gradient = true

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemImage: icon, gradient: gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).rowTitle().foregroundStyle(.white)
                if let subtitle { Text(subtitle).rowSubtitle() }
            }
        }
    }
}

/// Everything stored on this iPhone, with the space it uses and "Remove All".
struct DownloadsView: View {
    @Environment(Player.self) private var player
    @State private var confirmRemoveAll = false

    var body: some View {
        let downloads = Downloads.shared
        let songs = downloads.allSongs
        List {
            if !songs.isEmpty {
                PlayShuffleButtons(songs: songs)
                Text("\(songs.count) songs · \(ByteCountFormatter.string(fromByteCount: downloads.bytesOnDisk, countStyle: .file)) on this iPhone")
                    .rowSubtitle().listRowSeparator(.hidden).themedRow()
            }
            if let error = downloads.error { Notice(text: error) }
            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                SongRow(song: song) { player.play(songs, startAt: i) }
            }
            .onDelete { offsets in offsets.map { songs[$0].id }.forEach(downloads.removeSong) }
        }
        .themedList()
        .navigationTitle("Downloads")
        .toolbar {
            Button("Remove All", role: .destructive) { confirmRemoveAll = true }
                .disabled(songs.isEmpty && downloads.collections.isEmpty)
        }
        .confirmationDialog("Remove all downloads from this iPhone?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("Your playlists and likes stay; only the files stored on this phone are deleted.")
        }
        .overlay {
            if songs.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Use ••• → Download on a song, or the ⬇︎ button on a playlist."))
            }
        }
    }
}
