"""Answer GET/HEAD /stream/{id}.

  1. Song cached      -> read it from disk (instant).
  2. Not cached yet   -> download + repackage it into the cache (see cache.py
                         for why), then serve it from disk. This is the
                         first-play wait: mostly the yt-dlp resolve.
  3. Disk nearly full -> don't cache; pass YouTube's bytes straight through.
                         (Emergency mode: those raw files report a doubled
                         length to Apple players.)
"""

import logging
import re

from fastapi import Request
from fastapi.responses import Response, StreamingResponse

from .cache import Downloader, SongCache
from .upstream import Upstream, UpstreamError, parse_range

log = logging.getLogger("pitunes.streaming")

MIME = "audio/mp4"  # everything we serve is AAC in m4a
READ_SIZE = 64 * 1024


async def _read_file(path, start: int, end: int):
    """Yield bytes start..end of a file."""
    with open(path, "rb") as f:
        f.seek(start)
        remaining = end - start + 1
        while remaining > 0:
            data = f.read(min(READ_SIZE, remaining))
            if not data:
                return
            remaining -= len(data)
            yield data


async def respond(request: Request, video_id: str, cache: SongCache,
                  downloader: Downloader, upstream: Upstream) -> Response:
    range_header = request.headers.get("range")
    is_head = request.method == "HEAD"

    for _ in range(2):
        if hit := cache.get(video_id):
            path, total = hit
            start, end, partial = parse_range(range_header, total)
            return _make(None if is_head else _read_file(path, start, end), start, end, total, partial)
        if cache.disk_low():
            return await _passthrough(upstream, video_id, range_header, is_head)
        # Not cached: download it (or join the download already running, moving
        # it ahead of prefetches), wait, then loop to serve it from the cache.
        dl = downloader.ensure(video_id, urgent=True)
        if dl is not None:
            await dl.finished.wait()
            if dl.error:
                if isinstance(dl.error, Exception):
                    raise dl.error
                raise UpstreamError(0)
    raise UpstreamError(0)  # downloaded but evicted straight away: cache far too small


async def _passthrough(upstream: Upstream, video_id: str, range_header: str | None, is_head: bool) -> Response:
    """Serve straight from YouTube without caching (disk nearly full)."""
    m = re.fullmatch(r"\s*bytes=(\d+)-(\d*)\s*", range_header or "")
    want_start = int(m[1]) if m else 0
    want_end = int(m[2]) if m and m[2] else None
    s, first, total, stop = await upstream.open(video_id, want_start, want_end, urgent=True)
    if is_head:
        await first.aclose()
        return _make(None, want_start, stop, total, bool(m))

    async def body():
        try:
            async for data in upstream.iter_bytes(s, first, want_start, stop):
                yield data
        except UpstreamError as e:  # headers already sent: we can only stop early
            log.warning("%s: %s mid-stream", video_id, e)

    return _make(body(), want_start, stop, total, bool(m))


def _make(body, start: int, end: int, total: int, partial: bool) -> Response:
    status = 206 if partial else 200
    headers = {"Accept-Ranges": "bytes", "Content-Length": str(end - start + 1)}
    if partial:
        headers["Content-Range"] = f"bytes {start}-{end}/{total}"
    if body is None:
        return Response(status_code=status, headers=headers, media_type=MIME)
    return StreamingResponse(body, status_code=status, headers=headers, media_type=MIME)
