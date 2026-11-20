# PiTunes (iPhone app)

SwiftUI + AVQueuePlayer client for the PiTunes server. It is optional: the
web app the server provides covers almost everything. Build this one if you want
a CarPlay screen, sound search or podcast downloads. It isn't on the App Store.

Before building, open `project.yml` and change two things to your own:
`DEVELOPMENT_TEAM` (your Apple developer team ID) and
`PRODUCT_BUNDLE_IDENTIFIER` (any ID you own, for example `com.yourname.pitunes`).
A free Apple ID works; the app then needs reinstalling every 7 days.

## Build & install

```sh
brew install xcodegen
cd ios
xcodegen                     # generates PiTunes.xcodeproj from project.yml
open PiTunes.xcodeproj       # then pick your iPhone and press Run
```

Or from the terminal, with the iPhone plugged in / on the same Wi-Fi:

```sh
xcodebuild -project PiTunes.xcodeproj -scheme PiTunes -configuration Release \
  -destination 'id=<iPhone UDID>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <iPhone UDID> build/Build/Products/Release-iphoneos/PiTunes.app
```

`xcrun devicectl list devices` shows the UDID. With a paid developer account
the app keeps working for a year; just reinstall after that.

## How it works

- **Server address**: asked on first launch (for example `music`); change it later in Settings. The Tailscale app must be connected.
- **Profiles**: the server recognises each person by their Tailscale account; you pick a profile once.
- **Search → tap a song**: plays it, then similar songs (YouTube's Mix) when *Autoplay* is on.
- **••• / long-press a song**: Play Next, Add to Queue, Start Radio, Like, Add to Playlist.
- **Background playback**: AVQueuePlayer always holds the current *and* next song,
  so tracks advance with the screen locked. The app asks the server to prefetch
  the next two songs, so they start instantly.
- **Lock screen / Control Center / AirPods / car**: play, pause, next, previous, scrubbing.
- A play is logged to History after 30 s of listening.

Code map: `Player.swift` (playback, queue, remote controls), `API.swift` (server
calls), `Library.swift` (likes + playlists state), `Views/` (screens).

## Offline downloads

- **One song:** ••• → **Download**. **A whole list:** the round **⬇︎** button at the top right of a playlist or Liked Songs downloads it to the
  phone. Progress shows as `3/20`; tap again to remove the downloads.
- Downloaded songs always play from the phone, online or not. **Library →
  Downloads** lists everything that's on the phone.
- Downloaded lists stay in sync: songs you add on the server are downloaded the
  next time you open the list (or the app) with a connection.
- Downloads run while the app is open or playing music; they continue where
  they left off next time.
