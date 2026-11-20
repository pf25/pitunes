import SwiftUI

/// Podcasts tab: category chips, continue listening, your shows, the top
/// chart as large cards, then a shelf per category. Plus search.
struct PodcastsView: View {
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var results: [PodcastShow]?
    @State private var subs: [PodcastShow] = []
    @State private var inProgress: [Song] = []
    @State private var shelves: [PodcastShelf] = []
    /// The category chip that's selected (nil = the overview).
    @State private var category: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.xxl) {
                if let error { Notice(text: error).padding(.horizontal, Theme.Space.l) }
                if let results {
                    showGrid("Results", results)
                } else {
                    if shelves.count > 1 { chips }
                    if let shelf = shelves.first(where: { $0.title == category }) {
                        showGrid(shelf.title, shelf.shows)
                    } else {
                        overview
                    }
                }
            }
            .padding(.vertical)
        }
        .screenBackground()
        .navigationTitle("Podcasts")
        .navigationDestination(for: PodcastShow.self) { ShowView(show: $0) }
        .searchable(text: $query, prompt: "Find a podcast")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, new in if new.isEmpty { results = nil } }
        .task { await load() }
        .refreshable { await Task { await load() }.value }
    }

    /// One chip per category; tap again to go back to the overview.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(shelves.dropFirst()) { shelf in
                    Button(shelf.title) { category = category == shelf.title ? nil : shelf.title }
                        .buttonStyle(ChipStyle(selected: category == shelf.title))
                }
            }
            .padding(.horizontal, Theme.Space.l)
        }
    }

    @ViewBuilder
    private var overview: some View {
        if !inProgress.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Continue listening").sectionTitle()
                ForEach(inProgress) { ep in
                    EpisodeRow(episode: ep) { player.play([ep]) }
                }
            }
            .padding(.horizontal, Theme.Space.l)
        }
        if !subs.isEmpty { showShelf("Your shows", subs) }
        ForEach(Array(shelves.enumerated()), id: \.element.id) { i, shelf in
            // The overall chart leads with large cards; categories use regular ones.
            showShelf(shelf.title, shelf.shows, size: i == 0 ? Theme.Size.cardLarge : Theme.Size.card,
                      more: i == 0 ? nil : { category = shelf.title })
        }
        if subs.isEmpty && shelves.isEmpty && error == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        }
    }

    private func showShelf(_ title: String, _ shows: [PodcastShow], size: CGFloat = Theme.Size.card,
                           more: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(title).sectionTitle()
                Spacer()
                if let more { Button("More", action: more).buttonStyle(ChipStyle()) }
            }
            .padding(.horizontal, Theme.Space.l)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.m) {
                    ForEach(shows) { ShowCard(show: $0, size: size).frame(width: size) }
                }
                .padding(.horizontal, Theme.Space.l)
            }
        }
    }

    private func showGrid(_ title: String, _ shows: [PodcastShow]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).sectionTitle()
            if shows.isEmpty { Text("No podcasts found.").foregroundStyle(Theme.textSecondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.Size.card), spacing: Theme.Space.l)], spacing: Theme.Space.xl) {
                ForEach(shows) { ShowCard(show: $0).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .padding(.horizontal, Theme.Space.l)
    }

    private func load() async {
        do {
            async let s = API.subscriptions()
            async let c = API.continueListening()
            (subs, inProgress) = try await (s, c)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if shelves.isEmpty, let found = try? await API.podcastBrowse() { shelves = found }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        do { results = try await API.podcastSearch(q); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct ShowCard: View {
    let show: PodcastShow
    var size: CGFloat = Theme.Size.card

    var body: some View {
        NavigationLink(value: show) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(url: show.artworkURL, size: size)
                Text(show.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.white)
                if let author = show.author, !author.isEmpty { Text(author).rowSubtitle() }
            }
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("show-card")
    }
}

/// One show: artwork, Subscribe, and its episodes (newest first).
struct ShowView: View {
    @Environment(Player.self) private var player
    let show: PodcastShow
    @State private var loaded: LoadedShow?
    @State private var error: String?

    var body: some View {
        List {
            VStack(spacing: Theme.Space.m) {
                Artwork(url: show.artworkURL, size: Theme.Size.hero, radius: Theme.Radius.l)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                Text(show.title).font(.title2.bold()).multilineTextAlignment(.center)
                if let author = show.author { Text(author).font(.subheadline).foregroundStyle(Theme.textSecondary) }
                if let loaded {
                    HStack(spacing: Theme.Space.m) {
                        if let latest = loaded.episodes.first {
                            Button { player.play([latest]) } label: { Label("Latest", systemImage: "play.fill") }
                                .buttonStyle(.primary)
                        }
                        Button { Task { await toggleSubscription() } } label: {
                            Label(loaded.subscribed ? "Subscribed" : "Subscribe",
                                  systemImage: loaded.subscribed ? "checkmark" : "plus")
                        }
                        .buttonStyle(.secondary)
                    }
                    if let about = loaded.description, !about.isEmpty {
                        Text(about).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(4)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden).listRowBackground(Color.clear)

            if let error { Notice(text: error) }
            if let loaded {
                ForEach(loaded.episodes) { ep in
                    EpisodeRow(episode: ep) { player.play([ep]) }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .themedList()
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await Task { await load() }.value }
    }

    private func load() async {
        do { loaded = try await API.podcastShow(show.feed); error = nil } catch { self.error = error.localizedDescription }
    }

    private func toggleSubscription() async {
        guard var l = loaded else { return }
        do {
            if l.subscribed { try await API.unsubscribe(show.feed) } else { try await API.subscribe(l.show) }
            l.subscribed.toggle()
            loaded = l
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// An episode in a list: title, date, length or time left, download state.
struct EpisodeRow: View {
    @Environment(Player.self) private var player
    let episode: Song
    let onTap: () -> Void

    var body: some View {
        let isCurrent = player.current?.id == episode.id
        let downloaded = Downloads.shared.localURL(for: episode.id) != nil
        HStack(spacing: Theme.Space.m) {
            Artwork(url: episode.thumbnailURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.displayTitle).font(.body).lineLimit(2)
                    .foregroundStyle(isCurrent ? Theme.accent : (episode.finished == true ? Theme.textSecondary : .white))
                HStack(spacing: 6) {
                    if episode.finished == true { Image(systemName: "checkmark.circle.fill") }
                    if downloaded { Image(systemName: "arrow.down.circle.fill") }
                    Text(detail)
                }
                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let pos = episode.position, let d = episode.duration, d > 0, episode.finished != true, pos > 30 {
                    ProgressView(value: min(pos / Double(d), 1)).tint(Theme.accent)
                }
            }
            Spacer(minLength: Theme.Space.s)
            Menu {
                Button { player.playNext(episode) } label: { Label("Play Next", systemImage: "text.insert") }
                Button { player.addToQueue(episode) } label: { Label("Add to Queue", systemImage: "text.append") }
                if downloaded {
                    Button(role: .destructive) { Downloads.shared.removeSong(episode.id) } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } else {
                    Button { Downloads.shared.downloadSong(episode) } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: Theme.Size.tap, height: Theme.Size.tap)
            }
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel("More")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .themedRow()
    }

    private var detail: String {
        var parts: [String] = []
        if let show = episode.artist, episode.published == nil { parts.append(show) }
        if let t = episode.published {
            parts.append(Date(timeIntervalSince1970: t).formatted(.dateTime.day().month(.abbreviated).year()))
        }
        if let d = episode.duration {
            if let pos = episode.position, pos > 30, episode.finished != true {
                parts.append("\(max(1, (d - Int(pos)) / 60)) min left")
            } else {
                parts.append(d >= 3600 ? "\(d / 3600) hr \(d % 3600 / 60) min" : "\(max(1, d / 60)) min")
            }
        }
        return parts.joined(separator: " · ")
    }
}
