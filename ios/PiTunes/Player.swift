import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// One entry in the play queue. Has its own id because the same song can be
/// queued twice.
struct QueueItem: Identifiable, Equatable {
    let id = UUID()
    let song: Song
}

/// Playback engine: the queue, AVQueuePlayer, lock screen / AirPods / car
/// controls, prefetching, and radio autoplay.
///
/// How background playback works: AVQueuePlayer always holds the current song
/// *and the next one*. When a song ends, AVFoundation moves to the next item on
/// its own, even with the screen locked, and we get a callback to queue up the
/// one after it.
@MainActor @Observable
final class Player {
    /// One player for the whole app: the phone screens and CarPlay share it.
    static let shared = Player()

    // MARK: State the UI reads

    private(set) var queue: [QueueItem] = []
    private(set) var index: Int?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var lastError: String?
    var showNowPlaying = false
    /// When the queue runs out, keep going with similar songs (YouTube's Mix).
    var autoplayRadio: Bool = UserDefaults.standard.object(forKey: "autoplayRadio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplayRadio, forKey: "autoplayRadio") }
    }

    /// What happens at the end of a song or of the queue.
    enum RepeatMode: String { case off, all, one }
    var repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode")
            resyncUpcoming()   // the song loaded "next" may now be a different one
        }
    }
    /// Sleep timer: playback pauses at this time (nil = no timer).
    private(set) var sleepAt: Date?

    /// Playback speed for podcast episodes (music always plays at 1x).
    var episodeRate: Float = UserDefaults.standard.object(forKey: "episodeRate") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(episodeRate, forKey: "episodeRate")
            applyRate()
        }
    }

    // Both check that `index` is really inside the queue: reading past the
    // end of an array crashes the app.
    var current: Song? { index.flatMap { queue.indices.contains($0) ? queue[$0].song : nil } }
    var upNext: [QueueItem] { index.flatMap { $0 < queue.count ? Array(queue[($0 + 1)...]) : nil } ?? [] }

    // MARK: Internals

    @ObservationIgnored private let player = AVQueuePlayer()
    /// Which queue entry each AVPlayerItem plays.
    @ObservationIgnored private var itemOwner: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var kvo: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var playRecorded: UUID?   // queue entry we've logged a play for
    @ObservationIgnored private var failedHandled: UUID?
    /// Watches each loaded item so a song that can't load is skipped (the
    /// periodic time observer doesn't fire for an item that never starts).
    @ObservationIgnored private var itemStatus: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var radioLoading = false
    /// The AVPlayerItem that was playing last, to notice a song repeating.
    @ObservationIgnored private var lastItem: ObjectIdentifier?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    @ObservationIgnored private var artwork: [String: MPMediaItemArtwork] = [:]

    init() {
        // Default routing policy on purpose: `.longFormAudio` makes iOS suggest
        // nearby AirPlay devices ("AirPlay to MacBook") every time the app opens.
        // AirPlay is still available from the button in Now Playing.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        // AirPlay: always send the sound from the phone. The default (handing
        // the TV or speaker our stream address to fetch by itself) can't work,
        // because that device isn't on Tailscale and can't reach the server.
        // It "connects" and then plays nothing.
        player.allowsExternalPlayback = false
        observePlayer()
        setUpRemoteCommands()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
    }

    // MARK: - Public controls

    /// Replace the queue with `songs` and start playing at `startAt`.
    func play(_ songs: [Song], startAt: Int = 0) {
        guard !songs.isEmpty else { return }
        // Finish with the old queue first. The old position can be past the
        // end of a shorter new queue, which used to crash the app here.
        saveEpisodeProgress(force: true)
        index = nil
        queue = songs.map { QueueItem(song: $0) }
        start(at: startAt)
    }

    /// Play one song, then (with autoplay on) similar songs.
    func playWithRadio(_ song: Song) {
        play([song])
    }

    /// Start a radio station: this song now, then its Mix.
    func startRadio(_ song: Song) {
        play([song])
        Task { await loadRadio(force: true) }
    }

    func playNext(_ song: Song) {
        guard let i = index else { return play([song]) }
        queue.insert(QueueItem(song: song), at: i + 1)
        resyncUpcoming()
    }

    func addToQueue(_ song: Song) {
        guard index != nil else { return play([song]) }
        queue.append(QueueItem(song: song))
        resyncUpcoming()
    }

    func jump(to item: QueueItem) {
        if let i = queue.firstIndex(of: item) { start(at: i) }
    }

    func removeFromQueue(_ item: QueueItem) {
        guard let i = queue.firstIndex(of: item), i != index else { return }
        queue.remove(at: i)
        if let cur = index, i < cur { index = cur - 1 }
        resyncUpcoming()
    }

    /// Mix up the songs waiting after the current one.
    func shuffleUpNext() {
        guard let i = index, i + 2 < queue.count else { return }
        queue[(i + 1)...].shuffle()
        resyncUpcoming()
    }

    /// Drop everything waiting after the current song.
    func clearUpNext() {
        guard let i = index, i + 1 < queue.count else { return }
        queue.removeSubrange((i + 1)...)
        resyncUpcoming()
    }

    /// Fill Up Next with songs similar to the current one.
    func addSimilar() {
        Task { await loadRadio(force: true) }
    }

    /// Pause after this many minutes (nil turns the timer off).
    func setSleepTimer(minutes: Int?) {
        sleepAt = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        guard let i = index else { return }
        if player.currentItem == nil { return start(at: i) }  // queue had ended
        activateSession()
        player.play()
    }

    func pause() {
        player.pause()
        saveEpisodeProgress(force: true)
    }

    /// Stop and forget the queue, so the mini player goes away.
    func close() {
        saveEpisodeProgress(force: true)
        player.pause()
        player.removeAllItems()
        itemOwner = [:]
        itemStatus = [:]
        queue = []
        index = nil
        elapsed = 0
        duration = 0
        lastError = nil
        sleepAt = nil
        showNowPlaying = false
        updateNowPlaying()
    }

    /// Jump forward/back within the current item (podcasts: +-30 s).
    func skip(by seconds: Double) {
        let target = max(0, min(elapsed + seconds, max(duration - 1, 0)))
        seek(to: target)
    }

    /// Episodes play at `episodeRate`; songs at normal speed.
    private func applyRate() {
        let rate: Float = current?.isEpisode == true ? episodeRate : 1
        player.defaultRate = rate
        if isPlaying { player.rate = rate }
    }

    /// Remember where we are in a podcast episode (every 15 s, on pause, at the end).
    private func saveEpisodeProgress(force: Bool = false) {
        guard let ep = current, ep.isEpisode, elapsed > 5 else { return }
        guard force || Date().timeIntervalSince(lastProgressSave) >= 15 else { return }
        lastProgressSave = Date()
        let finished = duration > 60 && elapsed >= duration - 30
        let position = elapsed
        Task { await API.saveProgress(ep, position: position, finished: finished) }
    }

    func next() {
        guard let i = index else { return }
        if i + 1 < queue.count {
            // With "repeat one" the song loaded next is this same song, so start the real next one.
            if repeatMode != .one, player.items().count >= 2 { player.advanceToNextItem() } else { start(at: i + 1) }
        } else if repeatMode == .all {
            start(at: 0)
        } else if autoplayRadio {
            Task {
                await loadRadio()
                if let j = index, j + 1 < queue.count { start(at: j + 1) }
            }
        }
    }

    func previous() {
        guard let i = index else { return }
        if elapsed > 3 || i == 0 { seek(to: 0) } else { start(at: i - 1) }
    }

    func seek(to seconds: Double) {
        elapsed = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    // MARK: - Queue <-> AVQueuePlayer

    private func start(at i: Int) {
        guard queue.indices.contains(i) else { return }
        saveEpisodeProgress(force: true)   // leaving an episode: keep its position
        index = i
        starting = true
        player.removeAllItems()
        itemOwner = [:]
        itemStatus = [:]
        enqueue(queue[i])
        lastItem = player.currentItem.map { ObjectIdentifier($0) }
        starting = false
        enqueueNextIfNeeded()
        activateSession()
        player.play()
        trackChanged()
    }

    private func makeItem(for entry: QueueItem) -> AVPlayerItem {
        // Downloaded items play from the phone (works offline, no data used).
        // Podcast episodes otherwise play straight from the publisher.
        let url = Downloads.shared.localURL(for: entry.song.id)
            ?? entry.song.audioUrl.flatMap(URL.init(string:))
            ?? API.streamURL(entry.song.id)
        let item = AVPlayerItem(url: url)
        itemOwner[ObjectIdentifier(item)] = entry.id
        // Safety net: YouTube's raw files report double their real length to
        // AVPlayer, which then plays silence instead of advancing. The server
        // repackages files to fix that; this also caps any that slip through.
        if let d = entry.song.duration, d > 0, !entry.song.isEpisode {   // feed durations are often rough
            item.forwardPlaybackEndTime = CMTime(seconds: Double(d) + 2, preferredTimescale: 600)
        }
        itemStatus[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "unknown error"
            Task { @MainActor in self?.itemFailed(entryID: entry.id, message: message) }
        }
        return item
    }

    private func enqueue(_ entry: QueueItem) {
        player.insert(makeItem(for: entry), after: nil)
    }

    /// Keep exactly one upcoming song loaded in AVQueuePlayer.
    private func enqueueNextIfNeeded() {
        guard let next = nextIndex, player.items().count < 2 else { return }
        enqueue(queue[next])
    }

    /// Which queue entry plays after the current one, given the repeat mode.
    private var nextIndex: Int? {
        guard let i = index else { return nil }
        if repeatMode == .one { return i }
        if i + 1 < queue.count { return i + 1 }
        return repeatMode == .all ? 0 : nil
    }

    /// The queue changed after the current song: replace AVQueuePlayer's
    /// upcoming item so it matches.
    private func resyncUpcoming() {
        for item in player.items().dropFirst() {
            player.remove(item)
            itemOwner[ObjectIdentifier(item)] = nil
            itemStatus[ObjectIdentifier(item)] = nil
        }
        enqueueNextIfNeeded()
        prefetchUpcoming()
    }

    /// AVQueuePlayer moved to another item (song ended, or we skipped).
    private func currentItemChanged() {
        guard let item = player.currentItem else {
            guard !starting else { return }   // just swapping songs
            isPlaying = false   // reached the end of the queue
            updateNowPlaying()
            // Nothing was queued (for example after "Clear Up Next"): with
            // autoplay on, fetch similar songs and keep going.
            if let i = index, i == queue.count - 1, autoplayRadio, repeatMode == .off, current?.isEpisode != true {
                Task {
                    await loadRadio()
                    if let j = index, j + 1 < queue.count, player.currentItem == nil { start(at: j + 1) }
                }
            }
            return
        }
        let itemID = ObjectIdentifier(item)
        let isNewItem = itemID != lastItem && !starting
        lastItem = itemID
        if let owner = itemOwner[itemID], let i = queue.firstIndex(where: { $0.id == owner }) {
            if i != index {
                index = i
                trackChanged()
            } else if isNewItem {
                // The same song started over (repeat): count it as a new listen.
                playRecorded = nil
                trackChanged()
            }
        }
        enqueueNextIfNeeded()
    }

    private func trackChanged() {
        elapsed = 0
        duration = Double(current?.duration ?? 0)
        lastError = nil
        applyRate()
        configureRemoteCommands()
        // Resume a half-heard episode where you left off (unless it was nearly done).
        if let ep = current, ep.isEpisode, ep.finished != true, let pos = ep.position, pos > 10,
           duration == 0 || pos < duration - 30 {
            seek(to: pos)
        }
        updateNowPlaying()
        prefetchUpcoming()
        if let i = index, i == queue.count - 1, autoplayRadio, repeatMode == .off, current?.isEpisode != true {
            Task { await loadRadio() }   // queue about to run out: fetch similar songs now
        }
    }

    /// Ask the server to cache the next two songs, so they start instantly.
    private func prefetchUpcoming() {
        // Songs already on the phone don't need the server at all.
        for entry in upNext.prefix(2) where Downloads.shared.localURL(for: entry.song.id) == nil && !entry.song.isEpisode {
            Task { await API.prefetch(entry.song.id) }
        }
    }

    /// Append the current song's Mix to the queue (skipping songs already queued).
    private func loadRadio(force: Bool = false) async {
        guard let seed = current, !seed.isEpisode, !radioLoading else { return }
        guard force || index == queue.count - 1 else { return }
        radioLoading = true
        defer { radioLoading = false }
        do {
            let songs = try await API.radio(seed.id)
            let queued = Set(queue.map(\.song.id))
            queue.append(contentsOf: songs.filter { !queued.contains($0.id) }.map { QueueItem(song: $0) })
            resyncUpcoming()
        } catch {
            lastError = "Radio: \(error.localizedDescription)"
        }
    }

    // MARK: - Observing AVPlayer

    private func observePlayer() {
        kvo.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })
        kvo.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = status != .paused
                self.isLoading = status == .waitingToPlayAtSpecifiedRate
                self.updateNowPlaying()
            }
        })
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    private func tick(_ seconds: Double) {
        guard let i = index, queue.indices.contains(i) else { return }
        let entry = queue[i]
        if seconds.isFinite { elapsed = seconds }
        if let sleepAt, Date() >= sleepAt {   // sleep timer ran out
            self.sleepAt = nil
            pause()
        }
        // Use the player's duration only when the song's metadata has none.
        if current?.duration == nil, let d = player.currentItem?.duration.seconds,
           d.isFinite, d > 0, abs(d - duration) > 1 {
            duration = d
            updateNowPlaying()
        }
        if elapsed >= 5 { consecutiveFailures = 0 }   // it's really playing
        saveEpisodeProgress()
        // Count a "play" after 30 s of listening (once per queue entry).
        if elapsed >= 30, playRecorded != entry.id, !entry.song.isEpisode {
            playRecorded = entry.id
            Task { await API.recordPlay(entry.song) }
        }
    }

    /// A song couldn't be loaded (server error, removed video, offline...).
    /// Say so and move on; stop after 3 failures in a row so a dead
    /// connection doesn't burn through the whole queue.
    private func itemFailed(entryID: UUID, message: String) {
        guard failedHandled != entryID, let i = queue.firstIndex(where: { $0.id == entryID }) else { return }
        failedHandled = entryID
        lastError = "Couldn't play \(queue[i].song.displayTitle): \(message)"
        guard i == index else {   // the preloaded *next* song failed: drop it from the queue
            queue.remove(at: i)
            if let cur = index, i < cur { index = cur - 1 }
            resyncUpcoming()
            return
        }
        consecutiveFailures += 1
        if consecutiveFailures >= 3 || i + 1 >= queue.count {
            consecutiveFailures = 0
            player.pause()
            return
        }
        start(at: i + 1)
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Phone calls, Siri, alarms... pause us; resume afterwards if iOS says so.
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended,
              let opts = info[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume)
        else { return }
        resume()
    }

    // MARK: - Lock screen, Control Center, AirPods, car

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }; return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }; return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }; return .success
        }
        // Podcasts: the lock screen / AirPods / car skip 30 s instead of changing track.
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: 30) }; return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -30) }; return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    /// Show skip-30 controls for episodes and next/previous for songs.
    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        let episode = current?.isEpisode == true
        c.skipForwardCommand.isEnabled = episode
        c.skipBackwardCommand.isEnabled = episode
        c.nextTrackCommand.isEnabled = !episode
        c.previousTrackCommand.isEnabled = !episode
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let song = current else { center.nowPlayingInfo = nil; return }
        let now = player.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.displayTitle,
            MPMediaItemPropertyArtist: song.displayArtist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: now.isFinite ? now : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isLoading ? Double(player.rate) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let art = artwork[song.id] {
            info[MPMediaItemPropertyArtwork] = art
        } else if let url = song.thumbnailURL {
            Task { await loadArtwork(for: song.id, from: url) }
        }
        center.nowPlayingInfo = info
    }

    private func loadArtwork(for id: String, from url: URL) async {
        guard artwork[id] == nil,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        let square = image.centerSquare()
        artwork[id] = MPMediaItemArtwork(boundsSize: square.size) { _ in square }
        if current?.id == id { updateNowPlaying() }
    }
}

extension UIImage {
    /// YouTube thumbnails are 16:9; lock screen artwork looks best square.
    func centerSquare() -> UIImage {
        let side = min(size.width, size.height)
        let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
    }
}
