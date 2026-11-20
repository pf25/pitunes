import AVFoundation
import Observation
import ShazamKit

/// "What's this song?" Listens through the microphone for a few seconds and
/// asks Apple's Shazam service to name the song that's playing around you.
/// The audio is turned into a fingerprint on the phone; it never goes to the
/// pitunes server.
@MainActor @Observable
final class SoundSearch {
    private(set) var listening = false
    var message: String?
    @ObservationIgnored private var session: SHManagedSession?

    /// Returns "title artist" to search for, or nil (see `message` for why).
    func identify() async -> String? {
        message = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "Allow microphone access for PiTunes in the Settings app to identify songs."
            return nil
        }
        let session = SHManagedSession()
        self.session = session
        listening = true
        defer {
            listening = false
            self.session = nil
            // Listening switched the audio session to recording; switch back.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        }
        switch await session.result() {
        case .match(let match):
            guard let item = match.mediaItems.first, let title = item.title else { break }
            return [title, item.artist].compactMap { $0 }.joined(separator: " ")
        case .noMatch:
            break
        case .error(let error, _):
            // Shazam's short message is just an error number; the reason, when
            // there is one, is tucked inside the error's extra details.
            let details = (error as NSError).userInfo
            let reason = details[NSDebugDescriptionErrorKey] as? String
                ?? (details[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
            message = "Couldn't listen: \(error.localizedDescription)" + (reason.map { "\n\($0)" } ?? "")
            return nil
        }
        if !Task.isCancelled { message = "Couldn't recognise that song. Try again closer to the music." }
        return nil
    }

    func cancel() {
        session?.cancel()
    }
}
