"""HTTP API for pitunes.

Endpoints:
  GET  /                      tiny test page: search and play in the browser
  GET  /health                status, memory, and cache usage (handy on the Pi)
  GET  /search?q=...          search YouTube, returns JSON
  GET  /resolve/{video_id}    debug: what yt-dlp resolved for this video
  GET  /stream/{video_id}     the audio itself (m4a), with Range/seek support
  POST /prefetch/{video_id}   download a song into the cache in the background
  GET  /cache                 cache stats + downloads in progress
  GET  /radio/{video_id}      YouTube's "Mix" for a song: similar songs
  ...plus the library (likes, playlists, history): see library_api.py
  ...and YouTube Music browsing under /music/... (home, charts, artists...): see music.py
"""

import argparse
import asyncio
import ipaddress
import logging
import re
import resource
import socket
import sqlite3
import sys
import tempfile
import time
from contextlib import asynccontextmanager

from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from . import config, jsworker, music, streaming
from .cache import Downloader, SongCache
from .images import router as images_router
from .db import Library
from .library_api import router as library_router
from .music import router as music_router
from .podcasts import router as podcasts_router
from .upstream import RangeNotSatisfiable, Upstream, UpstreamError
from .youtube import ResolveError, Resolver, radio, search

log = logging.getLogger("pitunes")

# YouTube video ids are exactly 11 chars of [A-Za-z0-9_-].
VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{11}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Shared objects live for the whole process (one HTTP client, one URL
    # cache, one song cache).
    app.state.resolver = Resolver()
    app.state.upstream = Upstream(app.state.resolver)
    app.state.cache = SongCache(config.DATA_DIR / "cache", config.CACHE_MAX_BYTES)
    app.state.downloader = Downloader(app.state.cache, app.state.upstream)
    app.state.library = Library(config.DATA_DIR / "pitunes.db")
    app.state.cache.set_pinned(app.state.library.liked_ids_all_profiles())
    # Upgrade songs cached by older versions, in the background.
    convert = asyncio.create_task(app.state.cache.convert_raw_files())
    warmup = None
    if config.JS_WORKER:
        jsworker.install()
        warmup = asyncio.create_task(_keep_worker_warm(app.state.resolver))
    yield
    convert.cancel()
    if warmup:
        warmup.cancel()
    jsworker.worker.stop()
    await app.state.downloader.aclose()
    await app.state.upstream.aclose()
    app.state.library.close()


async def _keep_worker_warm(resolver: Resolver) -> None:
    """Resolve one song at startup, then every few hours, as a background
    (non-urgent) job. This loads YouTube's current player into the JS worker
    ahead of time, so it's the warm-up that pays the ~15 s, not your first song."""
    while True:
        try:
            resolver.invalidate(config.WARMUP_VIDEO_ID)
            await resolver.get(config.WARMUP_VIDEO_ID)
        except Exception as e:  # noqa: BLE001 - warm-up is best effort
            log.warning("worker warm-up failed: %s", str(e)[:200])
        await asyncio.sleep(4 * 3600)


app = FastAPI(title="pitunes", lifespan=lifespan)
app.include_router(library_router)
app.include_router(music_router)
app.include_router(images_router)
app.include_router(podcasts_router)


def host_allowed(host_header: str) -> bool:
    """Is this Host header one of ours? IP addresses and localhost always are;
    names must be in config.ALLOWED_HOSTS (entries starting with "." match
    any subdomain)."""
    host = host_header.strip().lower()
    host = host.rsplit(":", 1)[0] if not host.endswith("]") else host  # drop :port
    host = host.strip("[]")
    if host in ("localhost", "testserver"):
        return True
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        pass
    return any(host == h or (h.startswith(".") and host.endswith(h)) for h in config.ALLOWED_HOSTS)


@app.middleware("http")
async def check_host(request: Request, call_next):
    """Refuse requests addressed to unknown hostnames. This stops DNS
    rebinding: a malicious web page can point its own domain at the Pi's
    address, but the browser will still send that domain in the Host header."""
    if not host_allowed(request.headers.get("host", "")):
        return JSONResponse({"error": "unknown host"}, status_code=421)
    return await call_next(request)


def check_id(video_id: str) -> str:
    if not VIDEO_ID.fullmatch(video_id):
        raise HTTPException(400, "invalid video id")
    return video_id


# --- Error handling: turn our exceptions into clean HTTP errors -------------


@app.exception_handler(ResolveError)
async def _resolve_error(_req, exc: ResolveError):
    log.warning("resolve failed: %s", exc)
    return JSONResponse({"error": "could not resolve audio", "detail": str(exc)}, status_code=502)


@app.exception_handler(UpstreamError)
async def _upstream_error(_req, exc: UpstreamError):
    log.warning("upstream error: %s", exc)
    return JSONResponse({"error": str(exc)}, status_code=502)


@app.exception_handler(RangeNotSatisfiable)
async def _bad_range(_req, exc: RangeNotSatisfiable):
    return Response(status_code=416, headers={"Content-Range": f"bytes */{exc.total}"})


# --- Routes -----------------------------------------------------------------


def _memory() -> dict:
    """Current and peak memory, in MB. Current RSS is only available on Linux
    (via /proc); peak works everywhere. 'children' covers Deno subprocesses."""
    # ru_maxrss is bytes on macOS but kilobytes on Linux.
    unit = 1 if sys.platform == "darwin" else 1024
    to_mb = lambda v: round(v * unit / 1024 / 1024, 1)  # noqa: E731
    mem = {
        "peak_rss_mb": to_mb(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss),
        "children_peak_rss_mb": to_mb(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss),
    }
    try:
        with open("/proc/self/statm") as f:
            pages = int(f.read().split()[1])
        mem["rss_mb"] = round(pages * resource.getpagesize() / 1024 / 1024, 1)
    except OSError:
        pass
    return mem


@app.get("/health")
async def health():
    mem = _memory()
    if (rss := jsworker.worker.rss_mb()) is not None:
        mem["js_worker_rss_mb"] = rss
    return {"ok": True, "memory": mem, "cache": app.state.cache.stats()}


@app.get("/search")
async def search_route(
    request: Request,
    q: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(config.SEARCH_LIMIT, ge=1, le=50),
):
    started = time.monotonic()
    results = await search(q, limit)
    base = str(request.base_url).rstrip("/")
    for r in results:
        r["stream_url"] = f"{base}/stream/{r['id']}"
    log.info("search %r -> %d results in %.1fs", q, len(results), time.monotonic() - started)
    return {"query": q, "results": results}


@app.get("/radio/{video_id}")
async def radio_route(request: Request, video_id: str, limit: int = Query(25, ge=1, le=50)):
    """Similar songs, for "start radio" and autoplay when the queue runs out."""
    video_id = check_id(video_id)
    try:
        # YouTube Music's radio gives album recordings (audio only).
        songs = await music.radio(video_id, limit)
    except Exception as e:  # noqa: BLE001 - any trouble: fall back to YouTube's Mix
        log.warning("music radio failed for %s (%s); using the YouTube Mix", video_id, str(e)[:200])
        songs = []
    if not songs:
        songs = await radio(video_id, limit)
    base = str(request.base_url).rstrip("/")
    for s in songs:
        s["stream_url"] = f"{base}/stream/{s['id']}"
    return {"seed": video_id, "results": songs}


@app.get("/resolve/{video_id}")
async def resolve_route(video_id: str):
    s = await app.state.resolver.get(check_id(video_id))
    return {
        "id": s.video_id,
        "title": s.title,
        "artist": s.artist,
        "duration": s.duration,
        "abr_kbps": s.abr,
        "filesize": s.filesize,
        "mime_type": s.mime_type,
        "expires_in_s": int(s.expires_at - time.time()),
    }


@app.api_route("/stream/{video_id}", methods=["GET", "HEAD"])
async def stream_route(video_id: str, request: Request):
    s = app.state
    return await streaming.respond(request, check_id(video_id), s.cache, s.downloader, s.upstream)


@app.post("/prefetch/{video_id}", status_code=202)
async def prefetch_route(video_id: str):
    """Start downloading a song so it plays instantly later. Returns at once;
    clients call this for the next song(s) in the queue."""
    check_id(video_id)
    if app.state.cache.disk_low() and not app.state.cache.get(video_id):
        return {"id": video_id, "status": "skipped: disk nearly full"}
    dl = app.state.downloader.ensure(video_id)
    return {"id": video_id, "status": "cached" if dl is None else "downloading"}


@app.get("/backup")
async def backup_route():
    """A consistent snapshot of the library database (likes, playlists,
    history). deploy/backup.sh on the Mac saves it; SD cards do die."""
    with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
        dest = sqlite3.connect(tmp.name)
        app.state.library.db.backup(dest)  # safe while the server is running
        dest.close()
        data = open(tmp.name, "rb").read()
    name = time.strftime("pitunes-%Y%m%d-%H%M%S.db")
    return Response(data, media_type="application/vnd.sqlite3",
                    headers={"Content-Disposition": f'attachment; filename="{name}"'})


@app.get("/cache")
async def cache_route():
    downloads = {
        vid: {"written": dl.written, "total": dl.total}
        for vid, dl in app.state.downloader.active.items()
    }
    return {**app.state.cache.stats(), "downloading": downloads}


# The web app (works in any browser; "Add to Home Screen" makes it an app).
WEB_DIR = Path(__file__).parent / "web"


@app.get("/", include_in_schema=False)
async def index():
    # no-cache: the page is tiny, and this way an updated server shows up at once.
    return FileResponse(WEB_DIR / "index.html", headers={"Cache-Control": "no-cache"})


@app.get("/sw.js", include_in_schema=False)
async def service_worker():
    # Served from the top level (not /web/) so it may handle every request
    # the web app makes; see web/sw.js.
    return FileResponse(WEB_DIR / "sw.js", media_type="text/javascript", headers={"Cache-Control": "no-cache"})


app.mount("/web", StaticFiles(directory=WEB_DIR), name="web")



def run() -> None:
    """Entry point for the `pitunes` command."""
    parser = argparse.ArgumentParser(description="pitunes music server")
    parser.add_argument("--host", default=config.HOST)
    parser.add_argument("--port", type=int, default=config.PORT)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    # httpx logs every request at INFO, including full signed googlevideo URLs. Too noisy.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    # access_log=False: fewer writes to the SD card; our own logs cover the important bits.
    server = uvicorn.Server(uvicorn.Config(app, access_log=False))
    server.run(sockets=listening_sockets(args.host, args.port))


def listening_sockets(host: str, port: int) -> list[socket.socket]:
    """Where the server listens. On the Pi that is the Tailscale address (for
    the apps) plus this machine's own loopback address, which nothing outside
    the Pi can reach. The loopback one is for `tailscale serve`, which adds
    HTTPS in front of the server (the web app needs HTTPS for offline use)."""
    hosts = [host]
    if host not in ("127.0.0.1", "localhost", "0.0.0.0"):
        hosts.append("127.0.0.1")
    sockets = []
    for h in hosts:
        sock = socket.socket(socket.AF_INET6 if ":" in h else socket.AF_INET)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((h, port))
        sockets.append(sock)
    return sockets


if __name__ == "__main__":
    run()
