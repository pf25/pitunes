# Plan

## Phases

| # | Phase | Milestone |
|---|---|---|
| 1 | **Minimal server**: `/search`, `/stream/{id}` proxy with Range support | VLC/browser on the Mac plays and seeks a song ✅ |
| 1b | **Early Pi check**: run Phase 1 on the Zero by hand | Have RAM and timing numbers for the Zero ✅ |
| 2 | **Cache + prefetch**: disk cache with LRU + size cap, written while streaming; `/prefetch` | Replays and the next queued song start instantly ✅ |
| 3 | **Library**: SQLite with profiles, songs, playlists, playlist_items, likes, plays (`profile_id` everywhere) | Playlists and likes work through the API ✅ (+ radio, liked songs pinned in cache) |
| 4 | **Deploy**: `deploy/deploy.sh` (rsync over SSH, Tailscale hostname), systemd units, weekly yt-dlp update timer, SD-friendly logging | One command deploys; the server survives a reboot ✅ |
| 5 | **iOS app**: SwiftUI + AVQueuePlayer, background audio, Now Playing, remote commands | Plays on the iPhone ✅ (lock screen / AirPods / car still to confirm) |
| 6 | **Offline + polish**: download playlists to the phone | Plays in airplane mode (built; testing) |
| 6b | **YouTube Music-style browsing**: Home, Explore, Charts, Moods & genres, music search, artist/album pages, lyrics (ytmusicapi, logged out) + AirPlay | Browse like YT Music ✅ (deployed 2026-11-18) |
| 7 | **Pico player** (later): `/stream/{id}.mp3` via ffmpeg | — |

## Decisions

- Song cache: 4 GB cap, LRU by last play (persisted as file mtime, at most hourly).
- Repo `pitunes`; Python deps via **uv**; access is **Tailscale-only** (the server
  binds to the Tailscale IP on the Pi, with no app-level auth).
- yt-dlp is used **as a library**, imported once and kept in memory, instead of
  spawning the CLI for every song.
- Audio format: itag 140 (AAC-LC ~128 kbps, m4a). No transcoding for iOS.

## Risks

1. **yt-dlp breakage / anti-bot.** YouTube changes things often, and logged-out
   access is the first to break. A home IP is much better than a datacenter IP.
   Age-restricted videos won't work logged out. *Mitigation:* update yt-dlp weekly
   (plus on demand), cache aggressively, surface errors clearly.
2. **Zero 2 W RAM, mostly Deno.** See the measurements below. *Mitigation:*
   only one resolve at a time, cache resolved URLs, prefetch, zram/swap. If it's
   still too heavy, try a lighter JS runtime (QuickJS is supported by yt-dlp)
   or cap V8's heap.
3. **First-play latency.** Resolve time plus YouTube's activation wait.
   *Mitigation:* prefetch the next song; start resolving as soon as a song is
   queued.
4. **DASH-flavoured m4a.** ⚠️ Confirmed real (2026-11-18): AVFoundation reads
   YouTube's raw `ftyp dash` files as **twice their length** and plays silence
   after the song instead of advancing the queue. *Fixed:* the server repackages
   every song with `ffmpeg -c copy` (lossless, ~1.4 s on the Zero) before caching
   or serving it; old cached files are converted at startup; the app also caps
   playback at the metadata duration as a safety net.
5. **iOS background playback.** Use AVQueuePlayer so the next track is already
   loaded, rather than relying on app code while suspended. Tailscale must be
   connected on the phone. ATS needs HTTPS or an exception: decide in Phase 5
   (exception vs `tailscale serve`).
6. **SD card wear.** The cache is the main writer: modest cap, logs in RAM.

## Measurements

### Phase 1 on the Mac (M-series, 2026-11-18, yt-dlp 2026.10.26)

| | |
|---|---|
| Search (`ytsearch`, flat) | ~1.0 s |
| Resolve (incl. Deno JS challenge) | 2.6–3.0 s |
| YouTube "available_at" wait after resolve | ~4–5 s |
| First play, time to first byte | ~8.2 s |
| Replay (URL cached), time to first byte | 0.07 s |
| Server peak RSS | ~125–150 MB |
| **Deno child peak RSS** | **~340 MB** ⚠️ |

The Deno number is the big question for the Zero's 512 MB. Phase 1b will tell.

### Phase 1b on the Pi Zero 2 W (2026-11-18, Debian 13 trixie, Python 3.13, Deno 2.9.8)

After converting the desktop image to headless (see README): 462 MB usable,
~300 MB available at idle, zram swap 461 MB.

| | |
|---|---|
| Server startup (`uv run`) | ~18 s |
| Search | ~4.1 s |
| **Resolve** | **~21–23 s**, of which **~16 s is Deno solving the JS challenge** |
| Replay (URL cached), time to first byte | 0.11 s; full 4 MB song in ~1 s |
| Server peak RSS | ~128 MB |
| Deno child peak RSS | ~245 MB |
| Swap used at peak | ~100 MB (no OOM) |

Findings:
- **Memory is OK** with one resolve at a time. **First-play latency is the problem.**
- Resolve breakdown: ~3.5 s network (webpage, player API, player JS), then ~16 s
  Deno and ~1.5 s for the HLS manifest. The available_at wait is already over by then.
- Clients that skip the JS challenge (`android_vr`, `ios`, `android`) don't offer
  itag 140 logged out (they need PO tokens). The challenge is unavoidable.
- yt-dlp's preprocessed-player cache (off by default; 4.4 MB per player version)
  only saves ~1.5 s. The cost is Deno starting and compiling the player JS on each solve.
- Same solve on an M-series Mac: ~0.8 s.

Options to fix it (to decide):
1. **Hide it** (Phase 2 already plans this): prefetch the queue, keep a disk
   cache, start resolving as soon as a song is queued. Only "search, then play
   right now" waits ~22 s.
2. **Persistent JS worker**: a small yt-dlp plugin that keeps one Deno process
   alive with the player already loaded, so each solve takes well under a second.
   Costs ~150–250 MB RAM while alive (stop it after N idle minutes).
3. **Try Node instead of Deno** (same V8 engine, sometimes starts faster). A quick experiment.

### Phase 2 on the Pi Zero 2 W (cache + prefetch)

| | time to first byte |
|---|---|
| Cold play (resolve + download) | ~23 s (download itself ~1.2 s) |
| Replay from SD card | 0.03 s |
| Seek within cached song | 0.006 s |
| Play after `/prefetch` finished | 0.013 s |

Known limitation: resolves run one at a time, so a play that needs a resolve
waits behind any prefetch already resolving (up to ~20 s extra on the Pi).
A priority queue (plays before prefetches) is an easy follow-up if it bites.

### Warm JS worker on the Pi Zero 2 W (2026-11-18)

`jsworker.py` keeps one Deno process alive with YouTube's player already loaded.

| | Before | With warm worker |
|---|---|---|
| JS challenge solve | ~16 s | 0.01–0.07 s |
| Resolve | 21–23 s | 3.3–5.3 s |
| First play, time to first byte | ~23–26 s | **~11 s** (resolve + YouTube's ~4–5 s URL activation + download/repackage) |
| Worker memory | none | ~65–80 MB steady, ~225 MB peak while loading a player |

Caveats: a player variant the worker hasn't seen yet costs the old ~16 s once
(YouTube serves a few variants; the worker keeps 3). The floor on any hardware
is ~8 s because of the activation wait (some videos: ~15 s).
