import CarPlay
import UIKit

/// The CarPlay screen: pick music from the car's display.
///
/// CarPlay apps can't draw their own views. Apple gives audio apps a few
/// ready-made "templates" (a tab bar, lists, and the Now Playing screen) and
/// we fill them in. iOS creates this class when the phone connects to a car;
/// it is named in the scene manifest in project.yml.
///
/// It needs the "CarPlay audio" entitlement, which Apple grants per developer
/// account. See CarPlay.entitlements.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
                                  CPInterfaceControllerDelegate, @preconcurrency CPNowPlayingTemplateObserver {
    private var car: CPInterfaceController?
    private let player = Player.shared

    private let home = CarPlaySceneDelegate.tab("Home", "house")
    private let library = CarPlaySceneDelegate.tab("Library", "music.note.list")
    private let podcasts = CarPlaySceneDelegate.tab("Podcasts", "mic")
    private let moods = CarPlaySceneDelegate.tab("Moods", "sparkles")
    /// When each tab was last filled, so a long drive doesn't show stale lists.
    private var loadedAt: [ObjectIdentifier: Date] = [:]

    private static func tab(_ title: String, _ symbol: String) -> CPListTemplate {
        let list = CPListTemplate(title: title, sections: [])
        list.tabImage = UIImage(systemName: symbol)
        list.emptyViewTitleVariants = ["Loading…"]
        return list
    }

    // MARK: - Connecting to the car

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        car = interfaceController
        interfaceController.delegate = self

        guard API.isConfigured else {
            let list = CPListTemplate(title: "PiTunes", sections: [])
            // Apple's CarPlay rules: say what's wrong, but never tell the
            // driver to pick up the phone.
            list.emptyViewTitleVariants = ["PiTunes isn't set up yet"]
            list.emptyViewSubtitleVariants = ["No server has been chosen."]
            interfaceController.setRootTemplate(list, animated: false, completion: nil)
            return
        }

        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.add(self)

        let tabs = CPTabBarTemplate(templates: [home, library, podcasts, moods])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        // The phone app may not be open, so load the library here too.
        Task { await Library.shared.refresh() }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CPNowPlayingTemplate.shared.remove(self)
        car = nil
    }

    /// Called whenever a screen is about to show. Fill a tab the first time,
    /// and again if it's more than 10 minutes old.
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        guard let list = aTemplate as? CPListTemplate else { return }
        let loaders: [(CPListTemplate, () async throws -> [CPListSection])] = [
            (home, loadHome), (library, loadLibrary), (podcasts, loadPodcasts), (moods, loadMoods),
        ]
        guard let loader = loaders.first(where: { $0.0 === list })?.1 else { return }
        let key = ObjectIdentifier(list)
        if let last = loadedAt[key], Date().timeIntervalSince(last) < 600 { return }
        loadedAt[key] = Date()
        fill(list, loader)
    }

    // MARK: - The four tabs

    private func loadHome() async throws -> [CPListSection] {
        async let dial = API.speedDial()
        async let page = API.home()
        var sections: [CPListSection] = []
        // Same as the phone's speed dial: your most played songs.
        let top = Array(((try? await dial) ?? []).prefix(9))
        if !top.isEmpty {
            sections.append(CPListSection(items: top.map { song in songItem(song) { self.player.playWithRadio(song) } },
                                          header: "Your top songs", sectionIndexTitle: nil))
        }
        let shelves = try await page.shelves
        sections.append(CPListSection(items: shelves.map { shelf in
            folder(shelf.title, detail: nil, symbol: "square.stack") { [self] in
                push(shelf.title) { [self.section(shelf.items)] }
            }
        }, header: "For you", sectionIndexTitle: nil))
        return sections
    }

    private func loadLibrary() async throws -> [CPListSection] {
        await Library.shared.refresh()
        var rows = [
            folder("Liked Songs", detail: nil, symbol: "heart.fill") { [self] in
                push("Liked Songs") { [self.songs(try await API.likes())] }
            },
            folder("History", detail: nil, symbol: "clock") { [self] in
                push("History") { [self.songs(try await API.history())] }
            },
        ]
        rows += Library.shared.playlists.map { list in
            folder(list.name, detail: "\(list.songCount) songs", symbol: "music.note.list") { [self] in
                push(list.name) { [self.songs(try await API.playlist(list.id).songs)] }
            }
        }
        var sections = [CPListSection(items: rows)]
        let artists = Library.shared.saved
        if !artists.isEmpty {
            sections.append(CPListSection(items: artists.map(musicItem), header: "Artists", sectionIndexTitle: nil))
        }
        return sections
    }

    private func loadPodcasts() async throws -> [CPListSection] {
        async let unfinished = API.continueListening()
        async let shows = API.subscriptions()
        var sections: [CPListSection] = []
        let episodes = (try? await unfinished) ?? []
        if !episodes.isEmpty {
            sections.append(CPListSection(items: episodes.map(episodeItem),
                                          header: "Continue listening", sectionIndexTitle: nil))
        }
        let mine = try await shows
        if !mine.isEmpty {
            sections.append(CPListSection(items: mine.map { show in
                let row = folder(show.title, detail: show.author, symbol: "mic") { [self] in
                    push(show.title) {
                        [CPListSection(items: try await API.podcastShow(show.feed).episodes.map(self.episodeItem))]
                    }
                }
                setImage(row, show.artworkURL)
                return row
            }, header: "Your shows", sectionIndexTitle: nil))
        }
        return sections
    }

    private func loadMoods() async throws -> [CPListSection] {
        let list = try await API.home().moods ?? []
        return [CPListSection(items: list.map { mood in
            folder(mood.title, detail: nil, symbol: "sparkles") { [self] in
                push(mood.title) { [self.section(try await API.mood(mood.params).items)] }
            }
        })]
    }

    // MARK: - Rows

    /// A row that plays something, then shows the Now Playing screen.
    private func songItem(_ song: Song, play: @escaping () -> Void) -> CPListItem {
        let row = CPListItem(text: song.displayTitle, detailText: song.displayArtist)
        setImage(row, song.thumbnailURL)
        row.handler = { [weak self] _, done in
            play()
            self?.showNowPlaying()
            done()
        }
        return row
    }

    private func episodeItem(_ episode: Song) -> CPListItem {
        songItem(episode) { self.player.play([episode]) }
    }

    /// A list of songs where tapping one plays the list from that song on.
    private func songs(_ songs: [Song]) -> CPListSection {
        CPListSection(items: songs.enumerated().map { i, song in
            songItem(song) { self.player.play(songs, startAt: i) }
        })
    }

    /// A row that opens another list.
    private func folder(_ title: String, detail: String?, symbol: String, open: @escaping () -> Void) -> CPListItem {
        let row = CPListItem(text: title, detailText: detail, image: UIImage(systemName: symbol))
        row.accessoryType = .disclosureIndicator
        row.handler = { _, done in
            open()
            done()
        }
        return row
    }

    /// A song, album, playlist or artist from YouTube Music.
    private func musicItem(_ item: MusicItem) -> CPListItem {
        if item.type == .song {
            return songItem(item.asSong) { self.player.playWithRadio(item.asSong) }
        }
        let row = folder(item.title, detail: item.subtitle, symbol: "music.note") { [self] in
            push(item.title) {
                switch item.type {
                case .album: return [self.songs(try await API.album(item.id).songs)]
                case .playlist: return [self.songs(try await API.ytPlaylist(item.id).songs)]
                default:
                    return try await API.artist(item.id).shelves.map {
                        CPListSection(items: $0.items.map(self.musicItem), header: $0.title, sectionIndexTitle: nil)
                    }
                }
            }
        }
        setImage(row, item.thumbnailURL)
        return row
    }

    private func section(_ items: [MusicItem]) -> CPListSection {
        CPListSection(items: items.map(musicItem))
    }

    /// Artwork arrives after the row is on screen.
    private func setImage(_ row: CPListItem, _ url: URL?) {
        guard let url else { return }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) {
                row.setImage(image)
            }
        }
    }

    // MARK: - Screens

    /// Open a new list and fill it once its content has loaded.
    private func push(_ title: String, _ load: @escaping () async throws -> [CPListSection]) {
        let list = CPListTemplate(title: title, sections: [])
        list.emptyViewTitleVariants = ["Loading…"]
        car?.pushTemplate(list, animated: true, completion: nil)
        fill(list, load)
    }

    private func fill(_ list: CPListTemplate, _ load: @escaping () async throws -> [CPListSection]) {
        Task {
            do {
                let sections = trimmed(try await load())
                list.emptyViewTitleVariants = ["Nothing here yet"]
                list.updateSections(sections)
            } catch {
                loadedAt[ObjectIdentifier(list)] = nil   // try again next time the tab shows
                list.emptyViewTitleVariants = ["Couldn't load"]
                list.emptyViewSubtitleVariants = ["Your server can't be reached right now."]
            }
        }
    }

    /// The car limits how long lists may be (less while driving); showing
    /// more than it allows is an error, so cut lists to fit.
    private func trimmed(_ sections: [CPListSection]) -> [CPListSection] {
        var room = min(CPListTemplate.maximumItemCount, 60)
        var out: [CPListSection] = []
        for section in sections.prefix(CPListTemplate.maximumSectionCount) where room > 0 {
            let items = Array(section.items.prefix(room))
            room -= items.count
            out.append(CPListSection(items: items, header: section.header, sectionIndexTitle: nil))
        }
        return out
    }

    private func showNowPlaying() {
        guard let car else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if car.templates.contains(nowPlaying) {
            car.pop(to: nowPlaying, animated: true, completion: nil)
        } else {
            car.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    /// The "Playing Next" button on the Now Playing screen.
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let queue = player.upNext
        push("Playing Next") { [self] in
            [CPListSection(items: queue.map { entry in self.songItem(entry.song) { self.player.jump(to: entry) } })]
        }
    }
}
