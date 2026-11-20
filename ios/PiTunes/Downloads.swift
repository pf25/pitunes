import Foundation
import Observation

/// Offline downloads: songs saved on the phone, grouped into "collections"
/// (a playlist, or Liked Songs) that you chose to download.
///
/// Files live in Application Support/Downloads/<id>.m4a (not backed up to
/// iCloud). The list of downloaded collections is saved as JSON, so the
/// Library keeps working with no connection.
@MainActor @Observable
final class Downloads {
    static let shared = Downloads()

    struct Collection: Codable {
        var name: String
        var songs: [Song]
    }

    /// Collection key ("liked", "playlist:12") -> its songs.
    private(set) var collections: [String: Collection] = [:]
    /// Song ids with a finished file on disk.
    private(set) var onDisk: Set<String> = []
    /// File extension per id (songs are m4a; podcast episodes are usually mp3).
    @ObservationIgnored private var ext: [String: String] = [:]
    /// Songs you removed one by one even though a downloaded playlist contains
    /// them. They're skipped, so they don't just download again.
    private(set) var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "downloads.excluded") ?? []) {
        didSet { UserDefaults.standard.set(Array(excluded), forKey: "downloads.excluded") }
    }
    /// Song currently downloading, if any.
    private(set) var active: String?
    var error: String?

    @ObservationIgnored private let dir: URL
    @ObservationIgnored private let indexFile: URL
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Songs the server couldn't provide (removed, age-restricted...), and when
    /// we last tried. They're skipped for a while so they don't block the rest.
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    private static let retryFailedAfter: TimeInterval = 600

    static func key(playlist id: Int) -> String { "playlist:\(id)" }
    static let likedKey = "liked"
    /// Songs downloaded one by one from the ••• menu.
    static let singlesKey = "singles"

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent("Downloads", isDirectory: true)
        indexFile = support.appendingPathComponent("downloads.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(noBackup)

        if let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([String: Collection].self, from: data) {
            collections = saved
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in files {
            let url = URL(fileURLWithPath: name)
            guard !url.pathExtension.isEmpty else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            onDisk.insert(id)
            ext[id] = url.pathExtension
        }
        // Files saved by app versions before the server repackaged songs are
        // raw YouTube "dash" files, which iOS mis-times (see Player). Drop
        // them; they re-download in the fixed format.
        for id in onDisk where Self.isRawDash(file(id)) {
            try? FileManager.default.removeItem(at: file(id))
            onDisk.remove(id)
        }
    }

    // MARK: - Queries

    /// Local file to play instead of streaming, if this song is downloaded.
    func localURL(for songID: String) -> URL? {
        onDisk.contains(songID) ? file(songID) : nil
    }

    func isDownloaded(_ key: String) -> Bool { collections[key] != nil }

    func progress(_ key: String) -> (done: Int, total: Int) {
        let ids = Set(collections[key]?.songs.map(\.id) ?? []).subtracting(excluded)
        return (ids.filter(onDisk.contains).count, ids.count)
    }

    func songs(in key: String) -> [Song]? { collections[key]?.songs }

    /// Every downloaded song (for the "Downloads" screen).
    var allSongs: [Song] {
        var seen = Set<String>()
        return collections.values.flatMap(\.songs).filter { onDisk.contains($0.id) && seen.insert($0.id).inserted }
    }

    // MARK: - Changes

    /// Download a collection (or refresh its song list if already downloaded).
    func download(_ key: String, name: String, songs: [Song]) {
        collections[key] = Collection(name: name, songs: songs)
        saveIndex()
        removeUnneededFiles()
        resume()
    }

    /// Keep a downloaded collection in sync with the server's latest version.
    func refresh(_ key: String, songs: [Song]) {
        guard let c = collections[key], c.songs.map(\.id) != songs.map(\.id) else { return }
        download(key, name: c.name, songs: songs)
    }

    /// Download just this song (••• menu → Download).
    func downloadSong(_ song: Song) {
        if excluded.remove(song.id) != nil, collections.values.contains(where: { $0.songs.contains { $0.id == song.id } }) {
            return resume()   // it's in a downloaded playlist: just stop skipping it
        }
        var c = collections[Self.singlesKey] ?? Collection(name: "Songs", songs: [])
        guard !c.songs.contains(where: { $0.id == song.id }) else { return }
        c.songs.append(song)
        collections[Self.singlesKey] = c
        saveIndex()
        resume()
    }

    func isSingle(_ songID: String) -> Bool {
        collections[Self.singlesKey]?.songs.contains { $0.id == songID } ?? false
    }

    /// Remove one song from the phone. If a downloaded playlist contains it,
    /// the song is remembered as excluded so it isn't downloaded again.
    func removeSong(_ songID: String) {
        collections[Self.singlesKey]?.songs.removeAll { $0.id == songID }
        if collections.values.contains(where: { $0.songs.contains { $0.id == songID } }) {
            excluded.insert(songID)
        }
        saveIndex()
        removeUnneededFiles()
    }

    /// Delete every downloaded song and forget all downloaded lists.
    func removeAll() {
        collections = [:]
        excluded = []
        saveIndex()
        removeUnneededFiles()
    }

    /// Space used by downloaded songs, in bytes.
    var bytesOnDisk: Int64 {
        onDisk.reduce(0) { total, id in
            total + Int64((try? file(id).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func remove(_ key: String) {
        collections[key] = nil
        saveIndex()
        removeUnneededFiles()
    }

    /// Start (or continue) downloading whatever is missing. Safe to call often.
    func resume() {
        guard worker == nil else { return }
        worker = Task {
            await run()
            worker = nil
        }
    }

    // MARK: - Internals

    private func file(_ id: String) -> URL { dir.appendingPathComponent("\(id).\(ext[id] ?? "m4a")") }

    private static func isRawDash(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        return head.count == 12 && head.subdata(in: 8..<12) == Data("dash".utf8)
    }

    /// Songs still to download, skipping ones that failed recently.
    private var missing: [Song] {
        var seen = Set<String>()
        let now = Date()
        return collections.values.flatMap(\.songs).filter { song in
            if excluded.contains(song.id) { return false }
            if let t = failedAt[song.id], now.timeIntervalSince(t) < Self.retryFailedAfter { return false }
            return !onDisk.contains(song.id) && seen.insert(song.id).inserted
        }
    }

    private func run() async {
        while let song = missing.first {
            // Let the server start preparing the next few (resolving a song
            // that isn't in its cache takes ~20 s on the Pi).
            for upcoming in missing.prefix(3) where !upcoming.isEpisode { Task { await API.prefetch(upcoming.id) } }
            active = song.id
            do {
                try await fetch(song)
                error = nil
            } catch is API.ServerError {
                // The server answered but can't provide this song. Skip it and
                // carry on with the rest; it's retried after a while.
                failedAt[song.id] = Date()
                self.error = "Couldn't download \(song.displayTitle); skipped for now."
            } catch {
                // No connection. Stop; we'll retry next time resume() is called.
                self.error = "Download paused: \(error.localizedDescription)"
                break
            }
        }
        active = nil
    }

    private func fetch(_ song: Song) async throws {
        // Episodes come from the publisher; keep their real file type so iOS can play them.
        let source = song.audioUrl.flatMap(URL.init(string:))
        if let source {
            let e = source.pathExtension.lowercased()
            ext[song.id] = ["mp3", "m4a", "aac", "mp4", "ogg", "wav"].contains(e) ? e : "mp3"
        }
        var req = URLRequest(url: source ?? API.streamURL(song.id))
        req.timeoutInterval = 120  // first request for an uncached song waits for the server's resolve
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw API.ServerError(status: status, body: "download failed") }
        let dest = file(song.id)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        onDisk.insert(song.id)
    }

    /// Delete files no downloaded collection needs any more.
    private func removeUnneededFiles() {
        let needed = Set(collections.values.flatMap(\.songs).map(\.id)).subtracting(excluded)
        excluded.formIntersection(Set(collections.values.flatMap(\.songs).map(\.id)))  // forget stale entries
        for id in onDisk where !needed.contains(id) {
            try? FileManager.default.removeItem(at: file(id))
            onDisk.remove(id)
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(collections) {
            try? data.write(to: indexFile, options: .atomic)
        }
    }
}
