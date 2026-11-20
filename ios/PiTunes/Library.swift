import Foundation
import Observation

/// Likes and playlists, mirrored from the server so every screen can show
/// heart icons and "Add to playlist" menus without re-fetching.
@MainActor @Observable
final class Library {
    static let shared = Library()

    private(set) var likedIDs: Set<String> = []
    private(set) var playlists: [PlaylistSummary] = [] { didSet { saveOffline() } }
    /// Artists this profile follows.
    private(set) var saved: [MusicItem] = []
    /// Songs pinned to the front of the speed dial.
    private(set) var pinnedIDs: Set<String> = []
    var error: String?
    /// Who the server says this phone belongs to (nil until first asked).
    private(set) var me: API.Me?
    /// True when the server knows who you are but you haven't picked a profile.
    var needsProfile: Bool { me?.user != nil && me?.profile == nil }

    init() {
        // Last known library, so the Library tab works offline.
        let d = UserDefaults.standard
        if let data = d.data(forKey: "offline.playlists"),
           let saved = try? JSONDecoder().decode([PlaylistSummary].self, from: data) { playlists = saved }
        likedIDs = Set(d.stringArray(forKey: "offline.likedIDs") ?? [])
    }

    /// Ask the server whose phone this is, and switch to that person's profile.
    func loadMe() async {
        guard let me = try? await API.me() else { return }
        self.me = me
        if let mine = me.profile, mine.id != API.profileID {
            UserDefaults.standard.set(mine.id, forKey: API.profileKey)
        }
    }

    /// Pick your profile: an existing one (`id`) or a new one (`name`).
    func claimProfile(id: Int? = nil, name: String = "") async -> Bool {
        do {
            let mine: API.Profile
            if let id { mine = try await API.claimProfile(id) } else { mine = try await API.claimNewProfile(name) }
            UserDefaults.standard.set(mine.id, forKey: API.profileKey)
            await refresh()
            return true
        } catch {
            self.error = "Couldn't set your profile. \(error.localizedDescription)"
            return false
        }
    }

    func refresh() async {
        await loadMe()
        do {
            async let likes = API.likes()
            async let lists = API.playlists()
            let liked = try await likes
            likedIDs = Set(liked.map(\.id))
            playlists = try await lists
            Downloads.shared.refresh(Downloads.likedKey, songs: liked)
            error = nil
        } catch {
            self.error = "Offline? \(error.localizedDescription)"
        }
        if let items = try? await API.saved() { saved = items }
        if let pins = try? await API.pins() { pinnedIDs = Set(pins.map(\.id)) }
        saveOffline()
    }

    func isSaved(_ item: MusicItem) -> Bool { saved.contains { $0.id == item.id && $0.type == item.type } }

    /// Follow / unfollow an artist.
    func toggleSaved(_ item: MusicItem) async {
        do {
            if isSaved(item) {
                try await API.unsave(item)
                saved.removeAll { $0.id == item.id && $0.type == item.type }
            } else {
                try await API.save(item)
                saved.insert(item, at: 0)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveOffline() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(playlists), forKey: "offline.playlists")
        d.set(Array(likedIDs), forKey: "offline.likedIDs")
    }

    func isPinned(_ song: Song) -> Bool { pinnedIDs.contains(song.id) }

    /// Pin a song to the front of the speed dial, or unpin it.
    func togglePin(_ song: Song) async {
        let wasPinned = isPinned(song)
        if wasPinned { pinnedIDs.remove(song.id) } else { pinnedIDs.insert(song.id) }
        do {
            if wasPinned { try await API.unpin(song.id) } else { try await API.pin(song) }
        } catch {
            if wasPinned { pinnedIDs.insert(song.id) } else { pinnedIDs.remove(song.id) }
            self.error = error.localizedDescription
        }
    }

    func isLiked(_ song: Song) -> Bool { likedIDs.contains(song.id) }

    func toggleLike(_ song: Song) async {
        let wasLiked = isLiked(song)
        // Update the heart immediately; undo if the server call fails.
        if wasLiked { likedIDs.remove(song.id) } else { likedIDs.insert(song.id) }
        do {
            if wasLiked { try await API.unlike(song.id) } else { try await API.like(song) }
        } catch {
            if wasLiked { likedIDs.insert(song.id) } else { likedIDs.remove(song.id) }
            self.error = error.localizedDescription
        }
    }

    func add(_ song: Song, to playlist: PlaylistSummary) async {
        do {
            _ = try await API.addToPlaylist(playlist.id, song)
            playlists = try await API.playlists()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createPlaylist(named name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try await API.createPlaylist(name)
            playlists = try await API.playlists()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Copy an album / YouTube playlist into a new playlist of your own.
    func importPlaylist(named name: String, songs: [Song]) async {
        do {
            _ = try await API.importPlaylist(name, songs)
            playlists = try await API.playlists()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deletePlaylist(_ playlist: PlaylistSummary) async {
        do {
            try await API.deletePlaylist(playlist.id)
            playlists.removeAll { $0.id == playlist.id }
            Downloads.shared.remove(Downloads.key(playlist: playlist.id))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
