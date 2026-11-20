import SwiftUI

@main
struct PiTunesApp: App {
    @State private var player = Player.shared
    @State private var library = Library.shared

    init() {
        // For UI tests: behave like a fresh install (no server chosen yet).
        if CommandLine.arguments.contains("-resetServer") {
            UserDefaults.standard.removeObject(forKey: API.serverKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .environment(library)
                .preferredColorScheme(.dark)   // the design system is dark-only
                .tint(Theme.accent)
                .task { await library.refresh() }
        }
    }
}

struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(API.serverKey) private var server = ""

    var body: some View {
        @Bindable var player = player
        if API.normalized(server) == nil {
            ConnectView()   // first launch: this phone isn't connected to a server yet
        } else {
            tabs
        }
    }

    private var tabs: some View {
        @Bindable var player = player
        return TabView {
            NavigationStack { HomeView() }
                .withMiniPlayer()
                .tabItem { Label("Home", systemImage: "house") }
            NavigationStack { ExploreView() }
                .withMiniPlayer()
                .tabItem { Label("Explore", systemImage: "safari") }
            NavigationStack { PodcastsView() }
                .withMiniPlayer()
                .tabItem { Label("Podcasts", systemImage: "mic") }
            NavigationStack { SearchView() }
                .withMiniPlayer()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { LibraryView() }
                .withMiniPlayer()
                .tabItem { Label("Library", systemImage: "music.note.list") }
        }
        // First time on this server: ask once which profile is yours.
        .sheet(isPresented: .constant(library.needsProfile)) { ProfileChooser() }
        .sheet(isPresented: $player.showNowPlaying) {
            NowPlayingView().presentationDragIndicator(.hidden).preferredColorScheme(.dark).tint(Theme.accent)
        }
        // Continue unfinished downloads whenever the app comes to the foreground.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Downloads.shared.resume() }
        }
    }
}

extension View {
    /// The small "now playing" bar above the tab bar.
    func withMiniPlayer() -> some View { modifier(MiniPlayerHost()) }
}

private struct MiniPlayerHost: ViewModifier {
    @Environment(Player.self) private var player

    func body(content: Content) -> some View {
        content
            // While the bar is showing, give every list on this tab extra room
            // at the end so its last rows can scroll clear of the bar.
            .contentMargins(.bottom, player.current == nil ? 0 : Theme.Size.miniPlayerClearance,
                            for: .scrollContent)
            .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
    }
}
