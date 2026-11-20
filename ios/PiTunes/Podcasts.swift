import Foundation

// Podcast data from the server's /podcasts/... endpoints.

struct PodcastShow: Codable, Identifiable, Hashable {
    let feed: String
    let title: String
    var author: String?
    var artwork: String?
    var id: String { feed }
    var artworkURL: URL? { API.imageURL(artwork) }
}

struct ShowsPage: Decodable { let shows: [PodcastShow] }

/// A titled row of shows on the Podcasts tab ("Top shows", "Science"...).
struct PodcastShelf: Decodable, Identifiable {
    let title: String
    let shows: [PodcastShow]
    var id: String { title }
}
private struct PodcastBrowsePage: Decodable { let shelves: [PodcastShelf] }

/// An episode as the server sends it (artwork/show keys differ from Song).
private struct EpisodeDTO: Decodable {
    let id: String
    let title: String
    let show: String?
    let feed: String?
    let audioUrl: String
    let artwork: String?
    let duration: Int?
    let position: Double?
    let finished: Bool?
    let published: Double?
    let description: String?

    func song(show showTitle: String?, feed showFeed: String?, fallbackArt: String?) -> Song {
        Song(id: id, title: title, artist: show ?? showTitle, duration: duration, thumbnail: artwork ?? fallbackArt,
             itemId: nil, audioUrl: audioUrl, feed: feed ?? showFeed, position: position, finished: finished,
             published: published, description: description)
    }
}

private struct ShowDTO: Decodable {
    let feed: String
    let title: String
    let author: String?
    let description: String?
    let artwork: String?
    let subscribed: Bool
    let episodes: [EpisodeDTO]
}

struct LoadedShow {
    let show: PodcastShow
    let description: String?
    var subscribed: Bool
    let episodes: [Song]
}

extension API {
    static func podcastSearch(_ q: String) async throws -> [PodcastShow] {
        let page: ShowsPage = try await getJSON("podcasts/search", ["q": q]); return page.shows
    }
    /// The overall chart plus one shelf per category.
    static func podcastBrowse() async throws -> [PodcastShelf] {
        let country = (Locale.current.region?.identifier ?? "US").lowercased()
        let page: PodcastBrowsePage = try await getJSON("podcasts/browse", ["country": country]); return page.shelves
    }
    static func podcastShow(_ feed: String) async throws -> LoadedShow {
        let d: ShowDTO = try await getJSON("podcasts/show", ["feed": feed])
        return LoadedShow(show: PodcastShow(feed: d.feed, title: d.title, author: d.author, artwork: d.artwork),
                          description: d.description, subscribed: d.subscribed,
                          episodes: d.episodes.map { $0.song(show: d.title, feed: d.feed, fallbackArt: d.artwork) })
    }
    static func subscriptions() async throws -> [PodcastShow] { try await getJSON("podcasts/subscriptions") }
    static func subscribe(_ show: PodcastShow) async throws { try await sendOnly("PUT", "podcasts/subscriptions", body: show) }
    static func unsubscribe(_ feed: String) async throws {
        try await sendOnly("DELETE", "podcasts/subscriptions", query: ["feed": feed])
    }
    static func continueListening() async throws -> [Song] {
        let eps: [EpisodeDTO] = try await getJSON("podcasts/continue")
        return eps.map { $0.song(show: nil, feed: nil, fallbackArt: nil) }
    }
    /// Tell the server where we are in an episode.
    static func saveProgress(_ ep: Song, position: Double, finished: Bool) async {
        struct Body: Encodable {
            let id, feed, title: String; let show: String?; let audioUrl: String
            let artwork: String?; let duration: Int?; let position: Double; let finished: Bool
        }
        guard let audio = ep.audioUrl, let feed = ep.feed else { return }
        try? await sendOnly("PUT", "podcasts/progress", body: Body(
            id: ep.id, feed: feed, title: ep.displayTitle, show: ep.artist, audioUrl: audio,
            artwork: ep.thumbnail, duration: ep.duration, position: position, finished: finished))
    }
}
