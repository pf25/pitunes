import AVKit
import SwiftUI

// MARK: - Navigation

extension View {
    /// Album / playlist / artist / mood / charts screens, reachable from any tab.
    func browseDestinations() -> some View {
        navigationDestination(for: BrowseRoute.self) { route in
            switch route {
            case .item(let item):
                switch item.type {
                case .artist: ArtistView(item: item)
                case .album, .playlist: TrackListView(item: item)
                case .song: EmptyView()
                }
            case .mood(let mood): MoodView(mood: mood)
            case .charts: ChartsView()
            }
        }
    }
}

/// Loads a page once, with pull-to-refresh and an error message.
struct Loader<Value, Content: View>: View {
    let load: () async throws -> Value
    /// Used for pull-to-refresh if set (e.g. to skip the server's cache).
    var refresh: (() async throws -> Value)? = nil
    @ViewBuilder let content: (Value) -> Content
    @State private var value: Value?
    @State private var error: String?

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn't load", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await reload(load) } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if value == nil { await reload(load) } }
        .refreshable {
            // Run in its own Task: SwiftUI cancels the refresh action when the
            // view redraws mid-pull, which left the list stuck pulled down.
            // The short pause lets the spinner settle before content changes.
            await Task {
                try? await Task.sleep(for: .milliseconds(400))
                await reload(refresh ?? load)
            }.value
        }
    }

    private func reload(_ fetch: () async throws -> Value) async {
        do { value = try await fetch(); error = nil } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Home / Explore / Charts / Moods

struct HomeView: View {
    @State private var dial: [Song] = []

    var body: some View {
        // Read the state here (not only inside the closure below), or SwiftUI
        // won't redraw Home when the speed dial arrives.
        let songs = dial
        Loader(load: { try await API.home() }, refresh: {
            // Pull to refresh: fresh picks from YouTube Music + an updated speed dial.
            if let fresh = try? await API.speedDial() { dial = fresh }
            return try await API.home(fresh: true)
        }) { page in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let moods = page.moods, !moods.isEmpty { MoodRow(moods: moods) }
                    if !songs.isEmpty { SpeedDial(songs: songs) }
                    if songs.count >= 3 { MixShelf(songs: Array(songs.prefix(8))) }
                }
                .padding(.top, Theme.Space.s)
                ShelvesStack(shelves: page.shelves)
            }
        }
        // Refresh the grid each time Home appears, so it follows what you play.
        .task { if let songs = try? await API.speedDial() { dial = songs } }
        .screenBackground()
        .navigationTitle("Home")
        .browseDestinations()
    }
}

struct ExploreView: View {
    var body: some View {
        Loader(load: API.explore) { page in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    HStack(spacing: Theme.Space.m) {
                        NavigationLink(value: BrowseRoute.charts) {
                            Label("Charts", systemImage: "chart.line.uptrend.xyaxis")
                        }
                        NavigationLink(value: BrowseRoute.mood(Mood(title: "Moods & genres", params: ""))) {
                            Label("Moods & genres", systemImage: "face.smiling")
                        }
                    }
                    .buttonStyle(.secondary)
                    .padding(.horizontal, Theme.Space.l)
                    ShelvesStack(shelves: page.shelves)
                    if let moods = page.moods, !moods.isEmpty {
                        MoodChips(title: "Moods & genres", moods: moods)
                    }
                }
            }
        }
        .screenBackground()
        .navigationTitle("Explore")
        .browseDestinations()
    }
}

struct ChartsView: View {
    @AppStorage("chartsCountry") private var country = Locale.current.region?.identifier ?? "US"
    @State private var countries: [String] = []

    var body: some View {
        Loader(load: { try await API.charts(country) }) { page in
            ScrollView { ShelvesStack(shelves: page.shelves) }
                .onAppear { countries = page.countries ?? [] }
        }
        .id(country)  // reload when the country changes
        .screenBackground()
        .navigationTitle("Charts")
        .toolbar {
            Menu {
                Picker("Country", selection: $country) {
                    ForEach(countries, id: \.self) { code in
                        Text(Locale.current.localizedString(forRegionCode: code) ?? code).tag(code)
                    }
                }
            } label: {
                Label(Locale.current.localizedString(forRegionCode: country) ?? country, systemImage: "globe")
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

/// With empty params: the full list of moods & genres. Otherwise: one mood's playlists.
struct MoodView: View {
    let mood: Mood

    var body: some View {
        Group {
            if mood.params.isEmpty {
                Loader(load: API.moods) { page in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(page.groups) { MoodChips(title: $0.title, moods: $0.moods) }
                        }
                    }
                }
            } else {
                Loader(load: { try await API.mood(mood.params) }) { page in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.Size.card), spacing: Theme.Space.l)], spacing: Theme.Space.xl) {
                            ForEach(page.items) { CardView(item: $0) }
                        }
                        .padding()
                    }
                }
            }
        }
        .screenBackground()
        .navigationTitle(mood.title)
    }
}

struct MoodChips: View {
    let title: String
    let moods: [Mood]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).sectionTitle().padding(.horizontal, Theme.Space.l)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(36), spacing: Theme.Space.s), count: 3), spacing: Theme.Space.s) {
                    ForEach(moods) { mood in
                        NavigationLink(value: BrowseRoute.mood(mood)) {
                            Text(mood.title).frame(minWidth: 96)
                        }
                        .buttonStyle(ChipStyle())
                    }
                }
                .padding(.horizontal, Theme.Space.l)
            }
        }
    }
}

/// One row of mood chips for the top of Home ("Energize", "Workout"...).
struct MoodRow: View {
    let moods: [Mood]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(moods) { mood in
                    NavigationLink(mood.title, value: BrowseRoute.mood(mood)).buttonStyle(ChipStyle())
                }
            }
            .padding(.horizontal, Theme.Space.l)
        }
    }
}

/// "Your mixes": an endless mix of similar songs for each of your top songs.
struct MixShelf: View {
    @Environment(Player.self) private var player
    let songs: [Song]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Your mixes").sectionTitle().padding(.horizontal, Theme.Space.l)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.m) {
                    ForEach(songs) { song in
                        Button { player.startRadio(song) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Artwork(url: song.thumbnailURL, size: Theme.Size.card)
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                                            .padding(7).background(.black.opacity(0.6), in: Circle()).padding(6)
                                    }
                                Text("\(song.displayTitle) Mix").font(.subheadline.weight(.medium))
                                    .lineLimit(2).foregroundStyle(.white)
                                Text("Like \(song.displayArtist)").rowSubtitle()
                            }
                            .frame(width: Theme.Size.card, alignment: .leading)
                            .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(song.displayTitle) Mix")
                    }
                }
                .padding(.horizontal, Theme.Space.l)
            }
        }
    }
}

// MARK: - Speed dial

/// Your most played and liked songs, one tap to play: up to three 3x3 pages
/// that you swipe between.
struct SpeedDial: View {
    @Environment(Player.self) private var player
    let songs: [Song]
    @State private var page: Int? = 0

    private static let perPage = 9
    private var pages: [[Song]] {
        stride(from: 0, to: songs.count, by: Self.perPage).map {
            Array(songs[$0..<min($0 + Self.perPage, songs.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Speed dial").sectionTitle().padding(.horizontal, Theme.Space.l)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { number, group in
                        grid(group)
                            .padding(.horizontal, Theme.Space.l)
                            .containerRelativeFrame(.horizontal)   // each page = screen width
                            .id(number)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .contentMargins(.bottom, 0, for: .scrollContent)
            if pages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle().fill(i == (page ?? 0) ? Color.white : Theme.textSecondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityLabel("Page \((page ?? 0) + 1) of \(pages.count)")
            }
        }
    }

    private func grid(_ group: [Song]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 3),
                  spacing: Theme.Space.s) {
            ForEach(group) { song in
                Button { player.playWithRadio(song) } label: { tile(song) }
                    .buttonStyle(.plain)
                    .contextMenu { SongMenu(song: song) }
                    .accessibilityLabel("\(song.displayTitle), \(song.displayArtist)")
            }
        }
    }

    private func tile(_ song: Song) -> some View {
        let isCurrent = player.current?.id == song.id
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: song.thumbnailURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { Theme.surfaceRaised }
                }
            }
            .overlay {  // darken the bottom so the title stays readable on any artwork
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(song.displayTitle)
                    .font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(isCurrent ? Theme.accent : .white)
                    .padding(Theme.Space.s)
            }
            .overlay(alignment: .topTrailing) {
                if isCurrent {
                    Image(systemName: "waveform").font(.caption).foregroundStyle(Theme.accent)
                        .padding(6).background(.black.opacity(0.6), in: Circle()).padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m))
    }
}

// MARK: - Shelves & cards

struct ShelvesStack: View {
    let shelves: [Shelf]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.xxl) {
            ForEach(shelves) { ShelfView(shelf: $0) }
        }
        .padding(.vertical)
    }
}

/// One shelf: songs as a 4-row swipeable grid (like "Quick picks"), anything
/// else as a row of cards.
struct ShelfView: View {
    @Environment(Player.self) private var player
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(shelf.title).sectionTitle()
                Spacer()
                if shelf.isSongs {
                    Button { player.play(shelf.items.map(\.asSong)) } label: { Label("Play all", systemImage: "play.fill") }
                        .buttonStyle(ChipStyle())
                }
            }
            .padding(.horizontal, Theme.Space.l)
            ScrollView(.horizontal, showsIndicators: false) {
                if shelf.isSongs {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: Theme.Space.s), count: 4), spacing: Theme.Space.l) {
                        ForEach(shelf.items) { item in
                            SongRow(song: item.asSong) { player.playWithRadio(item.asSong) }
                                .frame(width: 310)
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                } else {
                    LazyHStack(alignment: .top, spacing: Theme.Space.m) {
                        ForEach(shelf.items) { CardView(item: $0).frame(width: Theme.Size.card) }
                    }
                    .padding(.horizontal, Theme.Space.l)
                }
            }
        }
    }
}

/// Square artwork + title + subtitle. Artists get round artwork.
struct CardView: View {
    @Environment(Player.self) private var player
    let item: MusicItem

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 6) {
            Artwork(url: item.thumbnailURL, size: Theme.Size.card, circle: item.type == .artist)
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.white)
            if let sub = item.subtitle, !sub.isEmpty { Text(sub).rowSubtitle() }
        }
        .multilineTextAlignment(.leading)

        if item.type == .song {
            Button { player.playWithRadio(item.asSong) } label: { card }.buttonStyle(.plain)
                .contextMenu { SongMenu(song: item.asSong) }
        } else {
            NavigationLink(value: BrowseRoute.item(item)) { card }.buttonStyle(.plain)
        }
    }
}

/// List row for an album / playlist / artist (search results).
struct ItemRow: View {
    let item: MusicItem

    var body: some View {
        NavigationLink(value: BrowseRoute.item(item)) {
            HStack(spacing: 12) {
                Artwork(url: item.thumbnailURL, circle: item.type == .artist)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).rowTitle().foregroundStyle(.white)
                    Text(item.subtitle ?? item.type.rawValue.capitalized).rowSubtitle()
                }
            }
        }
        .themedRow()
    }
}

// MARK: - Album / playlist / artist pages

struct TrackListView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    let item: MusicItem
    @State private var saving = false

    var body: some View {
        Loader(load: { item.type == .album ? try await API.album(item.id) : try await API.ytPlaylist(item.id) }) { list in
            let songs = list.songs
            List {
                VStack(spacing: Theme.Space.m) {
                    Artwork(url: API.imageURL(list.thumbnail ?? item.thumbnail),
                            size: Theme.Size.hero, radius: Theme.Radius.l)
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                    Text(list.title ?? item.title).font(.title2.bold()).multilineTextAlignment(.center)
                    if let sub = list.subtitle { Text(sub).font(.subheadline).foregroundStyle(Theme.textSecondary) }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                if !songs.isEmpty { PlayShuffleButtons(songs: songs) }
                ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                    SongRow(song: song) { player.play(songs, startAt: i) }
                }
            }
            .themedList()
            .toolbar {
                // Copy into your own playlists (then it can be downloaded for offline).
                Button {
                    saving = true
                    Task {
                        await library.importPlaylist(named: list.title ?? item.title, songs: songs)
                        saving = false
                    }
                } label: {
                    if saving { ProgressView() } else { Label("Save to Library", systemImage: "plus.circle") }
                }
                .disabled(saving || songs.isEmpty)
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ArtistView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    let item: MusicItem

    var body: some View {
        Loader(load: { try await API.artist(item.id) }) { page in
            ScrollView {
                VStack(spacing: Theme.Space.m) {
                    Artwork(url: API.imageURL(page.thumbnail ?? item.thumbnail),
                            size: Theme.Size.hero, circle: true)
                    Text(page.name ?? item.title).font(.largeTitle.bold())
                    if let subs = page.subscribers { Text("\(subs) subscribers").foregroundStyle(Theme.textSecondary) }
                    HStack(spacing: Theme.Space.s) {
                        if let pid = page.songsPlaylist {
                            Button {
                                Task { if let list = try? await API.ytPlaylist(pid) { player.play(list.songs) } }
                            } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.primary)
                            Button {
                                Task { if let list = try? await API.ytPlaylist(pid) { player.play(list.songs.shuffled()) } }
                            } label: { Label("Shuffle", systemImage: "shuffle") }
                            .buttonStyle(.secondary)
                        }
                        if let first = page.shelves.first(where: \.isSongs)?.items.first {
                            Button { player.startRadio(first.asSong) } label: {
                                Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                            }
                            .buttonStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                }
                ShelvesStack(shelves: page.shelves)
            }
        }
        .screenBackground()
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Followed artists are listed in the Library tab.
            Button { Task { await library.toggleSaved(item) } } label: {
                Label(library.isSaved(item) ? "Following" : "Follow",
                      systemImage: library.isSaved(item) ? "checkmark.circle.fill" : "plus.circle")
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

// MARK: - Lyrics & AirPlay

struct LyricsView: View {
    let song: Song

    var body: some View {
        NavigationStack {
            Loader(load: { try await API.lyrics(song.id) }) { lyrics in
                ScrollView {
                    if let text = lyrics.lyrics {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(text).font(.title3.weight(.medium)).lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let source = lyrics.source { Text(source).font(.caption).foregroundStyle(Theme.textSecondary) }
                        }
                        .padding(Theme.Space.xl)
                    } else {
                        ContentUnavailableView("No lyrics", systemImage: "text.quote",
                                               description: Text("No lyrics were found for this song."))
                    }
                }
            }
            .navigationTitle(song.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The system AirPlay button: pick a HomePod, Apple TV, AirPlay speaker or TV.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
