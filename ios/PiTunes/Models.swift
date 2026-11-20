import Foundation

/// A song, as the server returns it from /search, /radio, /likes, playlists...
/// `id` is the YouTube video id.
struct Song: Codable, Identifiable, Hashable {
    let id: String
    var title: String?
    var artist: String?
    var duration: Int?
    var thumbnail: String?
    /// Only set for songs inside a playlist (the same song can appear twice).
    var itemId: Int?
    // Podcast episodes reuse this type so the player, queue and downloads
    // work for them unchanged. Their ids start with "ep-".
    /// Where the audio lives (episodes play straight from the publisher).
    var audioUrl: String?
    /// The show's RSS feed.
    var feed: String?
    /// Saved listening position, in seconds.
    var position: Double?
    var finished: Bool?
    var published: Double?
    var description: String?
    /// True for a music video's soundtrack rather than the album recording.
    var video: Bool?

    var isEpisode: Bool { id.hasPrefix("ep-") }

    var displayTitle: String { title ?? id }
    var displayArtist: String { artist ?? "" }
    /// The artist, marked when this is a video rather than the album recording.
    var artistLine: String { video == true ? "Video • \(displayArtist)" : displayArtist }
    var thumbnailURL: URL? { API.imageURL(thumbnail) }
}

struct SearchResponse: Decodable {
    let results: [Song]
}

struct PlaylistSummary: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let songCount: Int
}

struct Playlist: Decodable, Identifiable {
    let id: Int
    let name: String
    let songs: [Song]
}

/// "3:07"
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let s = Int(seconds)
    return "\(s / 60):" + String(format: "%02d", s % 60)
}
