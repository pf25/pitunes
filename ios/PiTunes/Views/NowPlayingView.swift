import SwiftUI

/// Floating card above the tab bar: current song + play/pause, with a thin
/// progress line. Tap to open Now Playing.
struct MiniPlayer: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let song = player.current {
            HStack(spacing: Theme.Space.m) {
                Artwork(url: song.thumbnailURL, size: Theme.Size.miniArt)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(player.isLoading ? "Loading…" : song.displayArtist).rowSubtitle()
                }
                Spacer()
                PlayPauseButton(size: 20)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 18))
                        .frame(width: Theme.Size.tap, height: Theme.Size.tap)
                }
                .accessibilityLabel("Next")
            }
            .foregroundStyle(.white)
            .padding(.leading, Theme.Space.s).padding(.vertical, Theme.Space.s)
            .background(alignment: .bottom) {
                // Progress line along the bottom edge.
                GeometryReader { geo in
                    Theme.accent.frame(width: geo.size.width * progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.xs)
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }
            // Swipe the bar down, or press and hold it, to close the player.
            .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
                if drag.translation.height > 30 { player.close() }
            })
            .contextMenu {
                Button(role: .destructive) { player.close() } label: {
                    Label("Close Player", systemImage: "xmark")
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Close Player") { player.close() }
        }
    }

    private var progress: Double {
        player.duration > 0 ? min(player.elapsed / player.duration, 1) : 0
    }
}

struct PlayPauseButton: View {
    @Environment(Player.self) private var player
    var size: CGFloat
    /// Filled brand-color circle (Now Playing) or a bare icon (mini player).
    var filled = false

    var body: some View {
        let box = max(Theme.Size.tap, size * (filled ? 2.2 : 1.4))
        Button { player.togglePlayPause() } label: {
            Group {
                if player.isLoading {
                    ProgressView().tint(filled ? Theme.onAccent : .white)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: size))
                }
            }
            .foregroundStyle(filled ? Theme.onAccent : .white)
            .frame(width: box, height: box)
            .background(filled ? Theme.accent : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var scrubbing: Double?
    @State private var showLyrics = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                Capsule().fill(.white.opacity(0.3)).frame(width: 36, height: 5).padding(.top, Theme.Space.s)
                // Close on the left, "..." on the right, clear of the sheet's top edge.
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.title3)
                            .frame(width: Theme.Size.tap, height: Theme.Size.tap, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel("Close")
                    Spacer()
                    moreMenu
                }
                .padding(.bottom, -Theme.Space.m)
                if let song = player.current {
                    nowPlaying(song)
                }
                upNext
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background { backdrop }
        .sheet(isPresented: $showLyrics) {
            if let song = player.current { LyricsView(song: song) }
        }
    }

    /// The artwork, blurred and darkened, so each song tints the screen.
    private var backdrop: some View {
        ZStack {
            Theme.bg
            AsyncImage(url: player.current?.thumbnailURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
            }
            .blur(radius: 60).opacity(0.45)
            LinearGradient(colors: [.clear, Theme.bg], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func nowPlaying(_ song: Song) -> some View {
        Artwork(url: song.thumbnailURL, size: 300, radius: Theme.Radius.l)
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .padding(.top, Theme.Space.s)

        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(song.displayTitle).font(.title2.bold()).lineLimit(2)
                Text(song.displayArtist).font(.body).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            if !song.isEpisode {
                Button { Task { await library.toggleLike(song) } } label: {
                    Image(systemName: library.isLiked(song) ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(library.isLiked(song) ? Theme.accent : .white)
                        .frame(width: Theme.Size.tap, height: Theme.Size.tap)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(library.isLiked(song) ? "Unlike" : "Like")
            }
        }

        progress

        HStack(spacing: Theme.Space.l) {
            if !song.isEpisode {
                // Mixes up the songs waiting in Up Next.
                Button { player.shuffleUpNext() } label: {
                    Image(systemName: "shuffle").font(.title3)
                        .frame(width: Theme.Size.tap, height: Theme.Size.tap)
                }
                .disabled(player.upNext.count < 2)
                .accessibilityLabel("Shuffle Up Next")
            }
            Spacer(minLength: 0)
            // Songs: previous/next track. Podcast episodes: back/forward 30 s.
            Button { song.isEpisode ? player.skip(by: -30) : player.previous() } label: {
                Image(systemName: song.isEpisode ? "gobackward.30" : "backward.fill").font(.title)
                    .frame(width: Theme.Size.tap, height: Theme.Size.tap)
            }
            .accessibilityLabel(song.isEpisode ? "Back 30 seconds" : "Previous")
            PlayPauseButton(size: 32, filled: true)
            Button { song.isEpisode ? player.skip(by: 30) : player.next() } label: {
                Image(systemName: song.isEpisode ? "goforward.30" : "forward.fill").font(.title)
                    .frame(width: Theme.Size.tap, height: Theme.Size.tap)
            }
            .accessibilityLabel(song.isEpisode ? "Forward 30 seconds" : "Next")
            Spacer(minLength: 0)
            if !song.isEpisode {
                // Off -> repeat the whole queue -> repeat this song -> off.
                Button {
                    player.repeatMode = switch player.repeatMode { case .off: .all; case .all: .one; case .one: .off }
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                        .foregroundStyle(player.repeatMode == .off ? .white : Theme.accent)
                        .frame(width: Theme.Size.tap, height: Theme.Size.tap)
                }
                .accessibilityLabel("Repeat")
                .accessibilityValue(player.repeatMode == .off ? "Off" : player.repeatMode == .all ? "All" : "One")
            }
        }
        .buttonStyle(.plain)

        HStack {
            if song.isEpisode {
                Menu {
                    ForEach([0.8, 1.0, 1.2, 1.5, 1.75, 2.0], id: \.self) { rate in
                        Button(rate == 1 ? "Normal" : "\(rate.formatted())x") { player.episodeRate = Float(rate) }
                    }
                } label: {
                    Label("\(Double(player.episodeRate).formatted())x", systemImage: "speedometer")
                }
                .buttonStyle(ChipStyle(selected: player.episodeRate != 1))
            } else {
                Button { showLyrics = true } label: { Label("Lyrics", systemImage: "text.quote") }
                    .buttonStyle(ChipStyle())
            }
            Spacer()
            AirPlayButton().frame(width: Theme.Size.tap, height: Theme.Size.tap)
        }

        if let err = player.lastError { Notice(text: err) }
    }

    /// The "..." button in the top corner.
    private var moreMenu: some View {
        Menu {
            if let song = player.current, !song.isEpisode { SongMenu(song: song, isCurrent: true) }
            if !player.upNext.isEmpty {
                Button(role: .destructive) { player.clearUpNext() } label: { Label("Clear Up Next", systemImage: "text.badge.xmark") }
            }
            Menu {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                }
                if player.sleepAt != nil { Button("Turn Off") { player.setSleepTimer(minutes: nil) } }
            } label: {
                if let at = player.sleepAt {
                    Label("Sleep Timer (stops \(at.formatted(date: .omitted, time: .shortened)))", systemImage: "moon.fill")
                } else {
                    Label("Sleep Timer", systemImage: "moon")
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.title3)
                .frame(width: Theme.Size.tap, height: Theme.Size.tap, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .accessibilityLabel("More")
    }

    private var progress: some View {
        let total = max(player.duration, 1)
        return VStack(spacing: 2) {
            Slider(
                value: Binding(get: { scrubbing ?? player.elapsed }, set: { scrubbing = $0 }),
                in: 0...total,
                onEditingChanged: { editing in
                    if !editing, let s = scrubbing { player.seek(to: s); scrubbing = nil }
                }
            )
            .tint(.white)
            HStack {
                Text(formatTime(scrubbing ?? player.elapsed))
                Spacer()
                Text(player.isLoading ? "Loading…" : formatTime(player.duration))
            }
            .font(.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
    }

    private var upNext: some View {
        @Bindable var player = player
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Up Next").sectionTitle()
                Spacer()
                // Keep playing similar songs when the queue runs out.
                if player.current?.isEpisode != true {
                    Button { player.autoplayRadio.toggle() } label: {
                        Label("Autoplay", systemImage: "infinity")
                    }
                    .buttonStyle(ChipStyle(selected: player.autoplayRadio))
                    .accessibilityValue(player.autoplayRadio ? "On" : "Off")
                }
            }
            if player.upNext.isEmpty && player.current?.isEpisode != true {
                Text(player.autoplayRadio ? "Similar songs will be added automatically."
                                          : "Nothing queued. Turn on Autoplay to keep the music going.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                // Brings songs back after "Clear Up Next", or any time the queue is empty.
                Button { player.addSimilar() } label: { Label("Add Similar Songs", systemImage: "sparkles") }
                    .buttonStyle(ChipStyle())
            }
            ForEach(player.upNext) { item in
                SongRow(song: item.song, onRemove: { player.removeFromQueue(item) }) { player.jump(to: item) }
            }
        }
        .padding(.top, Theme.Space.s)
    }
}
