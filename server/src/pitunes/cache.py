"""On-disk song cache with a size cap (LRU eviction), plus background downloads.

Layout:  <data dir>/cache/<video_id>.m4a        finished songs (repackaged)
         <data dir>/cache/<video_id>.m4a.part   downloads in progress

Why repackage? YouTube serves "DASH" m4a files. Apple's players read their
length as double the real one, then sit in silence at the end of each song
instead of moving to the next. `ffmpeg -c copy` rewrites the container
(lossless, ~1.5 s on a Pi Zero 2 W, no re-encoding) and fixes that, so the
cache only ever holds repackaged files.

"Least recently used" order lives in memory. It's saved to disk as each
file's mtime, at most once an hour per song, so playing a song doesn't cause
an SD card write every time. On startup we rebuild the order from the mtimes.
"""

import asyncio
import logging
import os
import shutil
import time
from pathlib import Path

from . import config
from .upstream import Upstream

log = logging.getLogger("pitunes.cache")

TOUCH_INTERVAL_S = 3600  # persist "last played" to the file's mtime at most hourly


def is_raw_dash(path: Path) -> bool:
    """Is this an un-repackaged YouTube file? (MP4 major brand "dash")"""
    try:
        with open(path, "rb") as f:
            return f.read(12)[8:12] == b"dash"
    except OSError:
        return False


async def remux(src: Path, dest: Path) -> None:
    """Repackage `src` into a normal m4a at `dest` (audio copied bit for bit)."""
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-v", "error", "-y", "-i", str(src), "-c", "copy",
        "-movflags", "+faststart", "-f", "mp4", str(dest),
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
    )
    _, err = await proc.communicate()
    if proc.returncode != 0 or not dest.exists() or dest.stat().st_size == 0:
        dest.unlink(missing_ok=True)
        raise IOError(f"ffmpeg remux failed: {err.decode(errors='replace')[:200]}")


class SongCache:
    """Tracks finished songs on disk and evicts the least recently used ones."""

    def __init__(self, directory: Path, max_bytes: int):
        self.dir = directory
        self.max_bytes = max_bytes
        self.dir.mkdir(parents=True, exist_ok=True)
        # video_id -> [size_bytes, last_used (unix time), last_touched_on_disk]
        self._entries: dict[str, list[float]] = {}
        # Songs that are never evicted (liked songs). Set by the app at startup
        # and updated on like/unlike.
        self.pinned: set[str] = set()
        self._scan()

    def _scan(self) -> None:
        for p in self.dir.iterdir():
            if p.name.endswith((".part", ".tmp")):
                p.unlink(missing_ok=True)  # leftover from a crash or restart
            elif p.suffix == ".m4a":
                st = p.stat()
                self._entries[p.stem] = [st.st_size, st.st_mtime, st.st_mtime]
        log.info("cache: %d songs, %.0f MB (cap %.0f MB)", len(self._entries),
                 self.total_bytes / 1e6, self.max_bytes / 1e6)
        # No eviction here: pinned songs aren't known yet. main.py calls
        # set_pinned() right after startup, which evicts.

    def set_pinned(self, ids: set[str]) -> None:
        self.pinned = set(ids)
        self._evict()

    @property
    def total_bytes(self) -> int:
        return int(sum(e[0] for e in self._entries.values()))

    def path(self, video_id: str) -> Path:
        return self.dir / f"{video_id}.m4a"

    def part_path(self, video_id: str) -> Path:
        return self.dir / f"{video_id}.m4a.part"

    def get(self, video_id: str) -> tuple[Path, int] | None:
        """(path, size) if the song is fully cached. Marks it as recently used."""
        entry = self._entries.get(video_id)
        if not entry:
            return None
        now = time.time()
        entry[1] = now
        if now - entry[2] > TOUCH_INTERVAL_S:
            entry[2] = now
            try:
                os.utime(self.path(video_id))
            except FileNotFoundError:  # deleted behind our back
                del self._entries[video_id]
                return None
        return self.path(video_id), int(entry[0])

    def add(self, video_id: str, size: int) -> None:
        """Register a finished download, then evict old songs if over the cap."""
        now = time.time()
        self._entries[video_id] = [size, now, now]
        self._evict()

    def _evict(self) -> None:
        total = self.total_bytes
        # Oldest "last used" first. A file that's still being read stays
        # readable after deletion (the OS frees it when the reader closes it).
        for video_id, entry in sorted(self._entries.items(), key=lambda kv: kv[1][1]):
            if total <= self.max_bytes:
                break
            if video_id in self.pinned:
                continue
            self.path(video_id).unlink(missing_ok=True)
            del self._entries[video_id]
            total -= entry[0]
            log.info("cache: evicted %s (%.1f MB)", video_id, entry[0] / 1e6)
        if total > self.max_bytes:
            log.warning("cache: over the cap (%.0f MB) because of pinned (liked) songs",
                        total / 1e6)

    async def convert_raw_files(self) -> None:
        """One-time upgrade: repackage songs cached before we did that."""
        raw = [vid for vid in list(self._entries) if is_raw_dash(self.path(vid))]
        if raw:
            log.info("cache: repackaging %d old raw files", len(raw))
        for vid in raw:
            tmp = self.dir / f"{vid}.m4a.tmp"
            try:
                await remux(self.path(vid), tmp)
                os.replace(tmp, self.path(vid))
                if vid in self._entries:
                    self._entries[vid][0] = self.path(vid).stat().st_size
            except OSError as e:
                log.warning("cache: couldn't repackage %s (%s); dropping it", vid, e)
                self.path(vid).unlink(missing_ok=True)
                self._entries.pop(vid, None)

    def disk_low(self) -> bool:
        """True when the disk is nearly full. Liked songs are exempt from the
        cache cap, so this is the backstop that keeps the SD card from filling:
        while it's true we stop caching and stream straight from YouTube."""
        return shutil.disk_usage(self.dir).free < config.MIN_FREE_BYTES

    def stats(self) -> dict:
        return {
            "disk_free_bytes": shutil.disk_usage(self.dir).free,
            "songs": len(self._entries),
            "bytes": self.total_bytes,
            "max_bytes": self.max_bytes,
            "pinned_cached": sum(1 for v in self._entries if v in self.pinned),
        }


class Download:
    """One song being downloaded into the cache. Requests for it wait on
    `finished`, then read the finished file from the cache."""

    def __init__(self, video_id: str, urgent: bool = False):
        self.video_id = video_id
        self.urgent = urgent  # a listener is waiting (vs. a background prefetch)
        self.total: int | None = None  # known once YouTube answers
        self.written = 0  # bytes safely on disk (readable by other file handles)
        self.error: BaseException | None = None
        self.finished = asyncio.Event()  # set when cached, or on failure (see `error`)
        self.task: asyncio.Task | None = None


class Downloader:
    """Downloads songs into the cache in the background. One download per song,
    no matter how many requests (plays, prefetches) ask for it."""

    def __init__(self, cache: SongCache, upstream: Upstream):
        self.cache = cache
        self.upstream = upstream
        self.active: dict[str, Download] = {}

    def ensure(self, video_id: str, urgent: bool = False) -> Download | None:
        """Start downloading `video_id` unless it's cached or already downloading.
        Returns the in-progress Download, or None if the song is already cached.
        `urgent` (someone pressed play) moves it ahead of queued prefetches."""
        if video_id in self.active:
            if urgent:
                self.active[video_id].urgent = True
                self.upstream.resolver.bump(video_id)
            return self.active[video_id]
        if self.cache.get(video_id):
            return None
        dl = Download(video_id, urgent)
        self.active[video_id] = dl
        dl.task = asyncio.create_task(self._run(dl))
        return dl

    async def _run(self, dl: Download) -> None:
        part = self.cache.part_path(dl.video_id)
        tmp = self.cache.dir / f"{dl.video_id}.m4a.tmp"
        started = time.monotonic()
        try:
            s, first, total, end = await self.upstream.open(dl.video_id, urgent=dl.urgent)
            dl.total = total
            with open(part, "wb") as f:
                async for data in self.upstream.iter_bytes(s, first, 0, end):
                    f.write(data)
                    dl.written += len(data)
            if dl.written != total:
                raise IOError(f"incomplete download: {dl.written}/{total} bytes")
            await remux(part, tmp)                             # see module docstring
            os.replace(tmp, self.cache.path(dl.video_id))      # atomic: never a half file
            self.cache.add(dl.video_id, self.cache.path(dl.video_id).stat().st_size)
            log.info("cached %s (%.1f MB) in %.1fs", dl.video_id, total / 1e6,
                     time.monotonic() - started)
        except BaseException as e:  # incl. cancellation: always report to waiters
            dl.error = e
            log.warning("download %s failed: %r", dl.video_id, e)
            if isinstance(e, asyncio.CancelledError):
                raise
        finally:
            part.unlink(missing_ok=True)
            tmp.unlink(missing_ok=True)
            self.active.pop(dl.video_id, None)
            dl.finished.set()

    async def aclose(self) -> None:
        for dl in list(self.active.values()):
            if dl.task:
                dl.task.cancel()
