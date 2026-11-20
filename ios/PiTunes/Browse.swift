import Foundation

// YouTube Music browsing data, as returned by the server's /music/... endpoints.

/// A song, album, playlist, or artist in a shelf / search result.
struct MusicItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case song, album, playlist, artist }
    let type: Kind
    let id: String
    let title: String
    var subtitle: String?
    var thumbnail: String?
    var artist: String?
    var duration: Int?
    /// True for a music video's soundtrack rather than the album recording.
    var video: Bool?

    var thumbnailURL: URL? { API.imageURL(thumbnail) }
    var asSong: Song {
        Song(id: id, title: title, artist: artist ?? subtitle, duration: duration, thumbnail: thumbnail, video: video)
    }
}

/// A titled row of items ("Quick picks", "New releases"...).
struct Shelf: Decodable, Identifiable {
    let title: String
    let items: [MusicItem]
    var id: String { title }
    var isSongs: Bool { items.allSatisfy { $0.type == .song } }
}

struct Mood: Decodable, Identifiable, Hashable {
    let title: String
    let params: String
    var id: String { params }
}

struct ShelvesPage: Decodable {
    let shelves: [Shelf]
    var moods: [Mood]?
    var country: String?
    var countries: [String]?
}

struct MoodGroups: Decodable {
    struct Group: Decodable, Identifiable { let title: String; let moods: [Mood]; var id: String { title } }
    let groups: [Group]
}

struct ItemsPage: Decodable { let items: [MusicItem] }

struct ArtistPage: Decodable {
    let name: String?
    let thumbnail: String?
    let subscribers: String?
    let songsPlaylist: String?
    let shelves: [Shelf]
}

/// An album or playlist with its tracks.
struct TrackList: Decodable {
    let title: String?
    let subtitle: String?
    let thumbnail: String?
    let tracks: [MusicItem]
    var songs: [Song] { tracks.map(\.asSong) }
}

struct Lyrics: Decodable { let lyrics: String?; let source: String? }

/// A screen to navigate to (album, playlist, artist, mood, charts).
enum BrowseRoute: Hashable {
    case item(MusicItem)
    case mood(Mood)
    case charts
}

extension API {
    static func home(fresh: Bool = false) async throws -> ShelvesPage {
        try await getJSON("music/home", fresh ? ["fresh": "1"] : [:])
    }
    static func explore() async throws -> ShelvesPage { try await getJSON("music/explore") }
    static func charts(_ country: String) async throws -> ShelvesPage {
        try await getJSON("music/charts", ["country": country])
    }
    static func moods() async throws -> MoodGroups { try await getJSON("music/moods") }
    static func mood(_ params: String) async throws -> ItemsPage { try await getJSON("music/mood/\(params)") }
    static func musicSearch(_ q: String, filter: String?) async throws -> [MusicItem] {
        var query = ["q": q]
        if let filter { query["filter"] = filter }
        let page: ItemsPage = try await getJSON("music/search", query)
        return page.items
    }
    static func artist(_ id: String) async throws -> ArtistPage { try await getJSON("music/artist/\(id)") }
    static func album(_ id: String) async throws -> TrackList { try await getJSON("music/album/\(id)") }
    static func ytPlaylist(_ id: String) async throws -> TrackList { try await getJSON("music/playlist/\(id)") }
    static func lyrics(_ songID: String) async throws -> Lyrics { try await getJSON("music/lyrics/\(songID)") }
}
