"""Thin wrapper around yt-dlp: search YouTube and resolve a video to an audio URL.

yt-dlp is imported once and kept in memory, which is much cheaper than
starting the `yt-dlp` command for every request (important on the Pi Zero).
Its calls block, so we run them in a worker thread.
"""

import asyncio
import logging
import time
from dataclasses import dataclass
from urllib.parse import parse_qs, urlparse

import yt_dlp

from . import config

log = logging.getLogger("pitunes.youtube")

# itag 140 = AAC-LC ~128 kbps in an MP4 (m4a) container. iOS plays it natively,
# so we never need to transcode on the Zero. Fall back to any AAC/m4a audio.
AUDIO_FORMAT = "140/bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"

# Options shared by every yt-dlp call. No cookies or login: everything is logged out.
_BASE_OPTS = {
    "quiet": True,
    "no_warnings": False,
    "noprogress": True,
    "noplaylist": True,
    "skip_download": True,
    "logger": logging.getLogger("pitunes.yt_dlp"),
}


class ResolveError(Exception):
    """Raised when yt-dlp can't give us a playable audio stream."""


@dataclass
class AudioStream:
    """A resolved, ready-to-proxy audio stream for one video."""

    video_id: str
    url: str  # googlevideo.com URL; only works from the IP that resolved it
    headers: dict  # HTTP headers yt-dlp says to send upstream
    filesize: int | None  # bytes, if YouTube told us
    mime_type: str  # e.g. "audio/mp4"
    title: str
    artist: str
    duration: int | None  # seconds
    abr: float | None  # audio bitrate, kbps
    expires_at: float  # unix time after which `url` stops working
    # YouTube now hands out URLs that only start working a few seconds later
    # (googlevideo answers 403 until then). yt-dlp reports this as `available_at`.
    available_at: float

    def is_fresh(self) -> bool:
        # Treat URLs as stale 10 minutes early so a song never expires mid-play.
        return time.time() < self.expires_at - 600

    async def wait_until_available(self) -> None:
        delay = self.available_at - time.time()
        if delay > 0:
            log.info("%s: waiting %.1fs for YouTube to activate the URL", self.video_id, delay)
            await asyncio.sleep(delay)


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------


# Metadata of songs seen recently in search/radio results, so clients can like
# or add a song by id alone. Bounded so it can't grow forever.
_known: dict[str, dict] = {}
_KNOWN_MAX = 2000


def remember(songs: list[dict]) -> None:
    for song in songs:
        _known.pop(song["id"], None)
        _known[song["id"]] = song
    while len(_known) > _KNOWN_MAX:
        _known.pop(next(iter(_known)))


def known(video_id: str) -> dict | None:
    return _known.get(video_id)


def _flat_entries(url: str, limit: int) -> list[dict]:
    """List a search or playlist. 'Flat' extraction returns only basic metadata,
    so it's fast and doesn't trigger the expensive per-video stream resolution
    (no Deno)."""
    # noplaylist=False: for radio, the URL is a watch URL with &list=RD..., and we want the list.
    opts = {**_BASE_OPTS, "extract_flat": "in_playlist", "playlistend": limit, "noplaylist": False}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)

    results = []
    for e in info.get("entries") or []:
        if not e or not e.get("id"):
            continue
        thumbs = e.get("thumbnails") or []
        results.append(
            {
                "id": e["id"],
                "title": e.get("title"),
                "artist": e.get("channel") or e.get("uploader"),
                "duration": int(e["duration"]) if e.get("duration") else None,
                "thumbnail": thumbs[-1]["url"] if thumbs else None,
            }
        )
    remember(results)
    return results


async def search(query: str, limit: int) -> list[dict]:
    try:
        return await asyncio.to_thread(_flat_entries, f"ytsearch{limit}:{query}", limit)
    except yt_dlp.utils.DownloadError as e:
        raise ResolveError(str(e)) from e


async def radio(video_id: str, limit: int) -> list[dict]:
    """YouTube's auto-generated "Mix" for a song (playlist RD<id>): ~25 similar
    songs, the same picks YouTube's autoplay uses. Works logged out. The seed
    song itself comes first in the mix; we drop it."""
    url = f"https://www.youtube.com/watch?v={video_id}&list=RD{video_id}"
    try:
        songs = await asyncio.to_thread(_flat_entries, url, limit + 1)
    except yt_dlp.utils.DownloadError as e:
        raise ResolveError(str(e)) from e
    return [s for s in songs if s["id"] != video_id][:limit]


# ---------------------------------------------------------------------------
# Resolve (video id -> audio stream URL)
# ---------------------------------------------------------------------------


def _expiry_from_url(url: str) -> float:
    """googlevideo URLs carry an `expire=<unix time>` query param (usually ~6 h)."""
    try:
        return float(parse_qs(urlparse(url).query)["expire"][0])
    except (KeyError, ValueError, IndexError):
        return time.time() + 3600  # unknown: assume 1 hour


def _resolve_sync(video_id: str) -> AudioStream:
    opts = {**_BASE_OPTS, "format": AUDIO_FORMAT}
    started = time.monotonic()
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=False)
    log.info("resolved %s in %.1fs", video_id, time.monotonic() - started)

    # With a single-format selector, yt-dlp puts the chosen format's fields
    # directly on `info` (url, filesize, http_headers, ...).
    url = info.get("url")
    if not url:
        raise ResolveError(f"no audio URL found for {video_id}")
    ext = info.get("ext") or "m4a"
    return AudioStream(
        video_id=video_id,
        url=url,
        headers=info.get("http_headers") or {},
        filesize=info.get("filesize"),
        mime_type="audio/mp4" if ext in ("m4a", "mp4") else f"audio/{ext}",
        title=info.get("track") or info.get("title") or video_id,
        artist=info.get("artist") or info.get("channel") or info.get("uploader") or "",
        duration=int(info["duration"]) if info.get("duration") else None,
        abr=info.get("abr"),
        expires_at=_expiry_from_url(url),
        # +0.5s margin: the URL sometimes isn't live exactly at available_at.
        available_at=(info.get("available_at") or 0) + 0.5,
    )


class PriorityGate:
    """Like a semaphore, but urgent waiters (someone pressed play) go before
    normal ones (prefetches). A waiting key can be upgraded with `bump`."""

    def __init__(self, slots: int):
        self._free = slots
        self._seq = 0
        self._waiters: list[list] = []  # [urgent, seq, future, key]

    async def acquire(self, key: str, urgent: bool) -> None:
        if self._free > 0 and not self._waiters:
            self._free -= 1
            return
        self._seq += 1
        waiter = [urgent, self._seq, asyncio.get_running_loop().create_future(), key]
        self._waiters.append(waiter)
        try:
            await waiter[2]
        except asyncio.CancelledError:
            if waiter in self._waiters:
                self._waiters.remove(waiter)
            else:  # we were handed the slot just as we got cancelled: pass it on
                self.release()
            raise

    def release(self) -> None:
        if self._waiters:
            # Urgent first; within the same urgency, first come first served.
            waiter = min(self._waiters, key=lambda w: (not w[0], w[1]))
            self._waiters.remove(waiter)
            waiter[2].set_result(None)
        else:
            self._free += 1

    def bump(self, key: str) -> None:
        for waiter in self._waiters:
            if waiter[3] == key:
                waiter[0] = True


# How long to remember that a video failed to resolve (removed, age-restricted,
# ...), so repeated requests don't each cost a 20 s Deno run on the Pi.
FAILURE_TTL_S = 180


class Resolver:
    """Resolves video ids to audio streams and remembers results until they expire.

    - In-memory cache: replays and seeks don't hit YouTube again.
    - Per-video locks: two simultaneous requests for one song resolve it once.
    - A priority gate caps concurrent resolves (each may spawn a Deno process)
      and lets plays jump ahead of prefetches.
    - Recent failures are remembered briefly.
    """

    def __init__(self, max_concurrent: int = config.MAX_CONCURRENT_RESOLVES):
        self._cache: dict[str, AudioStream] = {}
        self._failed: dict[str, tuple[float, str]] = {}
        self._locks: dict[str, asyncio.Lock] = {}
        self._gate = PriorityGate(max_concurrent)

    async def get(self, video_id: str, urgent: bool = False) -> AudioStream:
        cached = self._cache.get(video_id)
        if cached and cached.is_fresh():
            return cached
        failed = self._failed.get(video_id)
        if failed and time.time() - failed[0] < FAILURE_TTL_S:
            raise ResolveError(failed[1])
        if urgent:
            self._gate.bump(video_id)  # already queued as a prefetch? move it up

        lock = self._locks.setdefault(video_id, asyncio.Lock())
        try:
            async with lock:
                # Someone else may have resolved it while we waited for the lock.
                cached = self._cache.get(video_id)
                if cached and cached.is_fresh():
                    return cached
                await self._gate.acquire(video_id, urgent)
                try:
                    stream = await asyncio.to_thread(_resolve_sync, video_id)
                except (yt_dlp.utils.DownloadError, ResolveError) as e:
                    self._failed[video_id] = (time.time(), str(e))
                    raise ResolveError(str(e)) from e
                finally:
                    self._gate.release()
                self._cache[video_id] = stream
                self._failed.pop(video_id, None)
                return stream
        finally:
            if not lock.locked():
                self._locks.pop(video_id, None)  # don't let the table grow forever
            self._prune()

    def bump(self, video_id: str) -> None:
        """A listener is now waiting for this song: resolve it before prefetches."""
        self._gate.bump(video_id)

    def _prune(self) -> None:
        """Drop expired entries once the tables get big."""
        if len(self._cache) > 500:
            self._cache = {k: v for k, v in self._cache.items() if v.is_fresh()}
        if len(self._failed) > 500:
            now = time.time()
            self._failed = {k: v for k, v in self._failed.items() if now - v[0] < FAILURE_TTL_S}

    def invalidate(self, video_id: str) -> None:
        """Forget a cached URL (e.g. YouTube answered 403 because it expired)."""
        self._cache.pop(video_id, None)
