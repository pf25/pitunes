import Foundation

/// Talks to the pitunes server (see server/README for the endpoints).
/// The server address is set in Settings and stored in UserDefaults.
enum API {
    /// Shown as an example only. Every install connects to its owner's own
    /// server, so there is no built-in address.
    static let exampleServer = "music"
    static let serverKey = "serverURL"

    /// Has the user connected this phone to a server yet?
    static var isConfigured: Bool { normalized(UserDefaults.standard.string(forKey: serverKey) ?? "") != nil }

    static var baseURL: URL {
        normalized(UserDefaults.standard.string(forKey: serverKey) ?? "") ?? URL(string: "http://server.invalid")!
    }

    /// Turn what someone typed ("music", "music:8000", " http://100.64.0.1:8000/ ") into a URL.
    static func normalized(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        let typedScheme = s.contains("://")
        if !typedScheme { s = "http://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme ?? "") else { return nil }
        // Just a name or IP ("music") means the server's usual port, 8000.
        if !typedScheme, url.port == nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.port = 8000
            return parts.url ?? url
        }
        return url
    }

    /// Check that a pitunes server answers at `url`.
    static func check(_ url: URL) async -> String? {
        var req = URLRequest(url: url.appendingPathComponent("health"))
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["ok"] as? Bool == true
            else { return "Something answered at that address, but it isn't a PiTunes server." }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Which profile this phone uses (likes, playlists, history, podcasts).
    static let profileKey = "profileID"
    static var profileID: Int {
        let id = UserDefaults.standard.integer(forKey: profileKey)
        return id > 0 ? id : 1
    }

    struct ServerError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "Server error \(status): \(body.prefix(200))" }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase  // item_id -> itemId
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    /// Artwork goes through the Pi's /img proxy, so Google's image servers
    /// never see this phone.
    static func imageURL(_ original: String?) -> URL? {
        guard let original, !original.isEmpty, let direct = URL(string: original) else { return nil }
        // The proxy only serves YouTube's image hosts; podcast artwork loads directly.
        let host = direct.host ?? ""
        guard [".ytimg.com", ".googleusercontent.com", ".ggpht.com"].contains(where: host.hasSuffix) else { return direct }
        var comps = URLComponents(url: baseURL.appendingPathComponent("img"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "u", value: original)]
        return comps?.url
    }

    static func streamURL(_ songID: String) -> URL {
        baseURL.appendingPathComponent("stream").appendingPathComponent(songID)
    }

    // MARK: - Low-level

    @discardableResult
    private static func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                body: Encodable? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(String(profileID), forHTTPHeaderField: "X-Profile-Id")
        req.timeoutInterval = 30
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(AnyEncodable(body))
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ServerError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private static func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try decoder.decode(T.self, from: try await request("GET", path, query: query))
    }

    /// GET with simple string query parameters (used by the /music endpoints).
    static func getJSON<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        try await get(path, query: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
    }

    /// A request whose response body we don't need.
    static func sendOnly(_ method: String, _ path: String, query: [String: String] = [:], body: Encodable? = nil) async throws {
        try await request(method, path, query: query.map { URLQueryItem(name: $0.key, value: $0.value) }, body: body)
    }

    private static func send<T: Decodable>(_ method: String, _ path: String, body: Encodable? = nil) async throws -> T {
        try decoder.decode(T.self, from: try await request(method, path, body: body))
    }

    // MARK: - Endpoints

    static func health() async throws { try await request("GET", "health") }

    static func search(_ q: String) async throws -> [Song] {
        let r: SearchResponse = try await get("search", query: [.init(name: "q", value: q), .init(name: "limit", value: "20")])
        return r.results
    }

    static func radio(_ songID: String) async throws -> [Song] {
        let r: SearchResponse = try await get("radio/\(songID)")
        return r.results
    }

    /// Ask the server to download a song into its cache (returns immediately).
    static func prefetch(_ songID: String) async {
        _ = try? await request("POST", "prefetch/\(songID)")
    }

    static func likes() async throws -> [Song] { try await get("likes") }
    static func like(_ song: Song) async throws { try await request("PUT", "likes", body: song.forServer) }
    static func unlike(_ songID: String) async throws { try await request("DELETE", "likes/\(songID)") }

    static func playlists() async throws -> [PlaylistSummary] { try await get("playlists") }
    static func playlist(_ id: Int) async throws -> Playlist { try await get("playlists/\(id)") }
    static func createPlaylist(_ name: String) async throws -> Playlist {
        try await send("POST", "playlists", body: ["name": name])
    }
    /// Create a playlist with songs in one request.
    static func importPlaylist(_ name: String, _ songs: [Song]) async throws -> Playlist {
        struct Body: Encodable { let name: String; let songs: [Song] }
        return try await send("POST", "playlists/import", body: Body(name: name, songs: songs.map(\.forServer)))
    }
    static func deletePlaylist(_ id: Int) async throws { try await request("DELETE", "playlists/\(id)") }
    static func addToPlaylist(_ id: Int, _ song: Song) async throws -> Playlist {
        try await send("POST", "playlists/\(id)/songs", body: song.forServer)
    }
    static func removeFromPlaylist(_ id: Int, itemID: Int) async throws -> Playlist {
        try await send("DELETE", "playlists/\(id)/songs/\(itemID)")
    }
    static func reorderPlaylist(_ id: Int, itemIDs: [Int]) async throws -> Playlist {
        try await send("PUT", "playlists/\(id)/order", body: ["item_ids": itemIDs])
    }

    // Followed artists
    static func saved() async throws -> [MusicItem] { try await get("saved") }
    static func save(_ item: MusicItem) async throws { try await request("PUT", "saved", body: item) }
    static func unsave(_ item: MusicItem) async throws { try await request("DELETE", "saved/\(item.type.rawValue)/\(item.id)") }

    // Songs pinned to the front of the speed dial
    static func pins() async throws -> [Song] { try await get("pins") }
    static func pin(_ song: Song) async throws { try await request("PUT", "pins", body: song.forServer) }
    static func unpin(_ songID: String) async throws { try await request("DELETE", "pins/\(songID)") }

    static func recordPlay(_ song: Song) async { _ = try? await request("POST", "plays", body: song.forServer) }
    // Profiles
    struct Profile: Decodable, Identifiable, Hashable { let id: Int; let name: String }
    static func profiles() async throws -> [Profile] { try await get("profiles") }
    static func createProfile(_ name: String) async throws -> Profile { try await send("POST", "profiles", body: ["name": name]) }

    /// Who the server thinks this phone belongs to. The server asks Tailscale
    /// whose phone is calling, so each person gets their own profile without
    /// choosing one every time. `user` is nil when the server can't tell
    /// (for example when it isn't reached through Tailscale).
    struct Me: Decodable {
        struct User: Decodable { let id: String; let name: String }
        struct Choice: Decodable, Identifiable { let id: Int; let name: String; let claimed: Bool }
        let user: User?
        let profile: Profile?
        let profiles: [Choice]
    }
    static func me() async throws -> Me { try await get("me") }
    /// Make an existing profile yours.
    static func claimProfile(_ id: Int) async throws -> Profile { try await send("POST", "me", body: ["profile_id": id]) }
    /// Start a new profile and make it yours.
    static func claimNewProfile(_ name: String) async throws -> Profile { try await send("POST", "me", body: ["name": name]) }

    static func speedDial() async throws -> [Song] { try await get("speed-dial", query: [.init(name: "limit", value: "27")]) }
    static func history() async throws -> [Song] { try await get("history", query: [.init(name: "limit", value: "100")]) }
}

extension Song {
    /// The song as the server's SongIn body (no playlist item id).
    var forServer: Song {
        var s = self
        s.itemId = nil; s.audioUrl = nil; s.feed = nil; s.position = nil
        s.finished = nil; s.published = nil; s.description = nil; s.video = nil
        return s
    }
}

/// Lets us pass any Encodable value to JSONEncoder.
private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
