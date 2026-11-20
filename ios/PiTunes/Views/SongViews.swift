import SwiftUI

/// Square, rounded thumbnail (YouTube's are 16:9, so crop the middle).
struct Artwork: View {
    let url: URL?
    var size: CGFloat = Theme.Size.rowArt
    var radius: CGFloat? = nil
    var circle = false

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Theme.surfaceRaised
                    .overlay(Image(systemName: "music.note").foregroundStyle(Theme.textTertiary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle())
                          : AnyShape(RoundedRectangle(cornerRadius: radius ?? (size <= 64 ? Theme.Radius.s : Theme.Radius.m))))
    }
}

/// A song in a list: artwork, title, artist, duration, plus a "..." menu.
struct SongRow: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    let song: Song
    /// If set, the menu gets a "Remove from Queue" action (Up Next list).
    var onRemove: (() -> Void)? = nil
    let onTap: () -> Void

    var body: some View {
        let isCurrent = player.current?.id == song.id
        HStack(spacing: Theme.Space.m) {
            Artwork(url: song.thumbnailURL)
                .overlay {
                    if isCurrent {  // "now playing" marker
                        RoundedRectangle(cornerRadius: Theme.Radius.s).fill(.black.opacity(0.55))
                        Image(systemName: "waveform").foregroundStyle(Theme.accent)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayTitle).rowTitle()
                    .foregroundStyle(isCurrent ? Theme.accent : .white)
                Text(song.artistLine).rowSubtitle()
            }
            Spacer(minLength: Theme.Space.s)
            if Downloads.shared.localURL(for: song.id) != nil {
                Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            if library.isLiked(song) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(Theme.accent)
            }
            if let d = song.duration {
                Text(formatTime(Double(d))).font(.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
            }
            Menu { menu } label: {
                Image(systemName: "ellipsis").frame(width: Theme.Size.tap, height: Theme.Size.tap)
            }
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel("More")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { menu }
        .themedRow()
    }

    @ViewBuilder private var menu: some View {
        if let onRemove {
            Button(role: .destructive, action: onRemove) { Label("Remove from Queue", systemImage: "minus.circle") }
        }
        if !song.isEpisode { SongMenu(song: song) }
    }
}

/// Actions for one song (used by the "..." button and long-press).
struct SongMenu: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    let song: Song
    /// True in Now Playing's menu: the song is already playing, so queueing
    /// it makes no sense, and the heart button is right there.
    var isCurrent = false

    var body: some View {
        if !isCurrent {
            Button { player.playNext(song) } label: { Label("Play Next", systemImage: "text.insert") }
            Button { player.addToQueue(song) } label: { Label("Add to Queue", systemImage: "text.append") }
        }
        Button { player.startRadio(song) } label: { Label("Start Radio", systemImage: "dot.radiowaves.left.and.right") }
        if Downloads.shared.localURL(for: song.id) != nil {
            Button(role: .destructive) { Downloads.shared.removeSong(song.id) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else {
            Button { Downloads.shared.downloadSong(song) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        if !isCurrent {
            Button {
                Task { await library.toggleLike(song) }
            } label: {
                library.isLiked(song)
                    ? Label("Unlike", systemImage: "heart.slash")
                    : Label("Like", systemImage: "heart")
            }
        }
        Button {
            Task { await library.togglePin(song) }
        } label: {
            library.isPinned(song)
                ? Label("Unpin from Speed Dial", systemImage: "pin.slash")
                : Label("Pin to Speed Dial", systemImage: "pin")
        }
        if let link = URL(string: "https://music.youtube.com/watch?v=\(song.id)") {
            ShareLink(item: link) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        Menu {
            ForEach(library.playlists) { playlist in
                Button(playlist.name) { Task { await library.add(song, to: playlist) } }
            }
            if library.playlists.isEmpty { Text("Create a playlist in Library first") }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
    }
}

/// A list of songs with Play / Shuffle buttons, e.g. Liked Songs or History.
struct SongListView: View {
    @Environment(Player.self) private var player
    let title: String
    /// If set, this list can be downloaded for offline use under this key.
    var downloadKey: String? = nil
    let load: () async throws -> [Song]
    @State private var songs: [Song] = []
    @State private var error: String?

    var body: some View {
        List {
            if !songs.isEmpty { PlayShuffleButtons(songs: songs) }
            ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                SongRow(song: song) { player.play(songs, startAt: i) }
            }
            if let error { Notice(text: error, isError: !error.hasPrefix("Offline")) }
        }
        .themedList()
        .navigationTitle(title)
        .toolbar { if let downloadKey { DownloadButton(key: downloadKey, name: title, songs: songs) } }
        .overlay { if songs.isEmpty && error == nil { ContentUnavailableView(title, systemImage: "music.note") } }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            songs = try await load()
            error = nil
            if let downloadKey { Downloads.shared.refresh(downloadKey, songs: songs) }
        } catch {
            // Offline: show the downloaded copy if there is one.
            if let downloadKey, let saved = Downloads.shared.songs(in: downloadKey) {
                songs = saved
                self.error = "Offline: showing downloaded songs"
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

struct PlayShuffleButtons: View {
    @Environment(Player.self) private var player
    let songs: [Song]

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button { player.play(songs) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.primary)
            Button { player.play(songs.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(.secondary)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

/// Toolbar button: download a list for offline use, show progress, or remove it.
struct DownloadButton: View {
    let key: String
    let name: String
    let songs: [Song]
    @State private var confirmRemove = false

    var body: some View {
        let downloads = Downloads.shared
        let (done, total) = downloads.progress(key)
        Group {
            if !downloads.isDownloaded(key) {
                Button { downloads.download(key, name: name, songs: songs) } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(songs.isEmpty)
                .accessibilityLabel("Download")
            } else if done < total {
                Button { confirmRemove = true } label: {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("\(done)/\(total)").font(.caption).monospacedDigit()
                    }
                }
                .accessibilityLabel("Downloading")
            } else {
                Button { confirmRemove = true } label: { Image(systemName: "arrow.down.circle.fill") }
                    .accessibilityLabel("Downloaded")
            }
        }
        .confirmationDialog("Remove downloads for \(name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Downloads", role: .destructive) { downloads.remove(key) }
        }
    }
}
