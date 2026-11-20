import SwiftUI

/// YouTube Music search with filters (All / Songs / Albums / Artists / Playlists).
struct SearchView: View {
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var filter: String? = nil
    @State private var results: [MusicItem] = []
    @State private var searching = false
    @State private var error: String?
    /// Your last searches, kept on this phone only.
    @AppStorage("recentSearches") private var recentData = Data()
    @State private var sound = SoundSearch()

    private var recents: [String] { (try? JSONDecoder().decode([String].self, from: recentData)) ?? [] }
    private func setRecents(_ list: [String]) { recentData = (try? JSONEncoder().encode(list)) ?? Data() }

    private let filters: [(String, String?)] = [
        ("All", nil), ("Songs", "songs"), ("Albums", "albums"), ("Artists", "artists"), ("Playlists", "playlists"),
    ]

    var body: some View {
        List {
            if !query.isEmpty || !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(filters, id: \.0) { label, value in
                            Button(label) {
                                filter = value
                                Task { await search() }
                            }
                            .buttonStyle(ChipStyle(selected: filter == value))
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if let error { Notice(text: error) }
            if query.isEmpty && results.isEmpty {
                // Sound search: name the song that's playing around you.
                Button { Task { await identify() } } label: {
                    Label("Identify a song playing nearby", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondary)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if let message = sound.message { Notice(text: message, isError: false) }
            if query.isEmpty && results.isEmpty && !recents.isEmpty {
                Section {
                    ForEach(recents, id: \.self) { term in
                        Button { query = term; Task { await search() } } label: {
                            Label(term, systemImage: "clock.arrow.circlepath").foregroundStyle(.white)
                        }
                    }
                    .onDelete { offsets in var list = recents; list.remove(atOffsets: offsets); setRecents(list) }
                } header: {
                    HStack {
                        Text("Recent searches")
                        Spacer()
                        Button("Clear") { setRecents([]) }.font(.caption)
                    }
                }
                .themedRow()
            }
            ForEach(results) { item in
                if item.type == .song {
                    // Like YouTube Music: play the song, then similar songs (radio).
                    SongRow(song: item.asSong) { player.playWithRadio(item.asSong) }
                } else {
                    ItemRow(item: item)
                }
            }
        }
        .themedList()
        .navigationTitle("Search")
        // Always visible: by default iOS hides the field until you pull down
        // once the list has rows (recent searches).
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Songs, albums, artists")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, new in if new.isEmpty { results = [] } }
        .browseDestinations()
        .overlay {
            if sound.listening {
                VStack(spacing: Theme.Space.l) {
                    Image(systemName: "waveform").font(.system(size: 56)).foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative)
                    Text("Listening…").font(.title3.bold())
                    Text("Hold your phone near the music.").foregroundStyle(Theme.textSecondary)
                    Button("Cancel") { sound.cancel() }.buttonStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg.opacity(0.95))
            } else if searching {
                ProgressView("Searching…")
            } else if results.isEmpty && error == nil && recents.isEmpty && sound.message == nil {
                ContentUnavailableView("Search for music", systemImage: "magnifyingglass",
                                       description: Text("Tap a song to play it, then similar songs."))
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await API.musicSearch(q, filter: filter)
            error = nil
            setRecents(Array(([q] + recents.filter { $0.caseInsensitiveCompare(q) != .orderedSame }).prefix(12)))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Listen for the song playing nearby, then search for it.
    private func identify() async {
        player.pause()   // our own music would drown out what we're listening for
        guard let found = await sound.identify() else { return }
        query = found
        filter = "songs"
        await search()
    }
}
