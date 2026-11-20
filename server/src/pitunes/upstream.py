"""Fetch audio bytes from YouTube (googlevideo.com), with Range support.

Why does everything go through the server? googlevideo URLs only work from
the IP address that resolved them (the server's), so the phone can't fetch
them directly.

This module only talks to YouTube. Deciding whether to serve from the disk
cache or straight from YouTube happens in `streaming.py`.
"""

import logging
import re

import httpx

from . import config
from .youtube import AudioStream, Resolver

log = logging.getLogger("pitunes.upstream")


class UpstreamError(Exception):
    def __init__(self, status: int):
        super().__init__(f"YouTube returned HTTP {status}")
        self.status = status


class RangeNotSatisfiable(Exception):
    def __init__(self, total: int):
        super().__init__(f"range outside 0..{total - 1}")
        self.total = total


def parse_range(header: str | None, total: int) -> tuple[int, int, bool]:
    """Turn a client's Range header into (start, end, is_partial). `end` is inclusive.

    Range requests are how seeking works: when you scrub to 2:30, the player
    asks for e.g. `Range: bytes=2400000-` and we answer 206 Partial Content.
    AVPlayer (iOS) won't play from servers that don't support this.

    Handles the three forms players send:
      bytes=100-     from byte 100 to the end
      bytes=100-199  bytes 100..199
      bytes=-500     the last 500 bytes
    Multiple ranges ("bytes=0-1,5-9") are rare; we only serve the first.
    """
    if not header:
        return 0, total - 1, False
    m = re.fullmatch(r"\s*bytes=(\d*)-(\d*)\s*(,.*)?", header)
    if not m or (m[1] == "" and m[2] == ""):
        return 0, total - 1, False  # malformed: ignore it and send everything
    if m[1] == "":  # suffix form
        start, end = max(0, total - int(m[2])), total - 1
    else:
        start = int(m[1])
        end = min(int(m[2]), total - 1) if m[2] else total - 1
    if start >= total or start > end:
        raise RangeNotSatisfiable(total)
    return start, end, True


class Upstream:
    def __init__(self, resolver: Resolver):
        self.resolver = resolver
        # One shared client = connection reuse to googlevideo (saves TLS handshakes).
        self.client = httpx.AsyncClient(
            timeout=httpx.Timeout(15.0, read=30.0), follow_redirects=True
        )

    async def aclose(self) -> None:
        await self.client.aclose()

    async def _fetch(self, s: AudioStream, start: int, end: int) -> httpx.Response:
        """Open a streaming GET for bytes start..end (inclusive) of the audio."""
        req = self.client.build_request(
            "GET", s.url, headers={**s.headers, "Range": f"bytes={start}-{end}"}
        )
        return await self.client.send(req, stream=True)

    async def _total_size(self, s: AudioStream) -> int:
        """File size in bytes. yt-dlp usually knows it; if not, ask YouTube for
        a single byte and read the total from the Content-Range header."""
        if s.filesize:
            return s.filesize
        r = await self._fetch(s, 0, 0)
        await r.aclose()
        if r.status_code != 206:
            raise UpstreamError(r.status_code)
        s.filesize = int(r.headers["content-range"].rsplit("/", 1)[1])
        return s.filesize

    async def open(self, video_id: str, start: int = 0, end: int | None = None, urgent: bool = False):
        """Start fetching bytes start..end (end=None means to the end of the file).

        Returns (stream, first_response, total_size, end). The first chunk's
        response is opened here, before we answer the client, so errors like
        an expired URL (403) can still be retried or turned into a clean HTTP
        error. Pass the result to `iter_bytes` to read the data.
        """
        for attempt in (1, 2):
            s = await self.resolver.get(video_id, urgent)
            await s.wait_until_available()  # no-op unless freshly resolved
            try:
                total = await self._total_size(s)
                if start >= total:
                    raise RangeNotSatisfiable(total)
                stop = total - 1 if end is None else min(end, total - 1)
                first = await self._fetch(s, start, min(start + config.UPSTREAM_CHUNK_BYTES - 1, stop))
                if first.status_code != 206:
                    await first.aclose()
                    raise UpstreamError(first.status_code)
                return s, first, total, stop
            except UpstreamError as e:
                # 403/410 usually means the cached URL expired: resolve again once.
                if attempt == 2 or e.status not in (403, 410):
                    raise
                log.info("%s: upstream %d, re-resolving", video_id, e.status)
                self.resolver.invalidate(video_id)
        raise AssertionError("unreachable")

    async def iter_bytes(self, s: AudioStream, first: httpx.Response, start: int, end: int):
        """Yield bytes start..end. The first chunk is already open (see `open`);
        later chunks are fetched one at a time, because YouTube throttles very
        large single requests."""
        pos, resp = start, first
        try:
            while True:
                received = 0
                async for data in resp.aiter_bytes(64 * 1024):
                    received += len(data)
                    yield data
                await resp.aclose()
                pos += received
                if pos > end:
                    return
                if received == 0:
                    raise UpstreamError(0)  # connection gave us nothing
                resp = await self._fetch(s, pos, min(pos + config.UPSTREAM_CHUNK_BYTES - 1, end))
                if resp.status_code != 206:
                    raise UpstreamError(resp.status_code)
        finally:
            # Runs when done, on error, or when the reader stops early (client
            # disconnected or seeked elsewhere).
            await resp.aclose()
