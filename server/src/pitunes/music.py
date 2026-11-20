"""YouTube Music browsing (logged out): home feed, charts, explore, moods &
genres, music search, artist/album/playlist pages, lyrics.

Uses ytmusicapi (the unofficial YouTube Music web API client) with no account.
Everything is converted into one simple "item" shape so the app only has to
understand that:

    {"type": "song" | "album" | "playlist" | "artist",
     "id": videoId (songs) | browseId (albums, artists) | playlistId,
     "title": str, "subtitle": str, "thumbnail": url,
     # songs only:
     "artist": str, "duration": seconds}

Results are cached in memory for a while (home/charts don't change by the
minute), so browsing the app barely touches YouTube or the Pi's CPU.
Playback still goes through /stream/{id}, exactly like search results.
"""

import asyncio
import logging
import re
import time
from typing import Any, Callable

from fastapi import APIRouter, HTTPException, Path, Query
from ytmusicapi import YTMusic

from . import youtube

log = logging.getLogger("pitunes.music")
router = APIRouter(prefix="/music")

_yt: YTMusic | None = None


def yt() -> YTMusic:
    global _yt
    if _yt is None:
        _yt = YTMusic()  # no auth = logged out
    return _yt


# --- tiny TTL cache ---------------------------------------------------------

_cache: dict[str, tuple[float, Any]] = {}
_CACHE_MAX = 300


async def cached(key: str, ttl: float, fn: Callable[[], Any]) -> Any:
    """Run blocking `fn` in a thread, caching its result for `ttl` seconds."""
    hit = _cache.get(key)
    if hit and hit[0] > time.time():
        return hit[1]
    try:
        value = await asyncio.to_thread(fn)
    except Exception as e:  # ytmusicapi raises various errors when YouTube changes
        log.warning("music %s failed: %s", key, e)
        raise HTTPException(502, f"YouTube Music request failed: {e}")
    if len(_cache) >= _CACHE_MAX:  # drop the oldest-expiring entries
        for k, _ in sorted(_cache.items(), key=lambda kv: kv[1][0])[: _CACHE_MAX // 4]:
            _cache.pop(k, None)
    _cache[key] = (time.time() + ttl, value)
    return value


HOUR = 3600

# YouTube ids/params are short URL-safe strings; refuse anything else.
# (A function, not a shared object: FastAPI ties each Path() to one parameter.)
def yt_id():
    return Path(pattern=r"^[A-Za-z0-9_%.=-]{1,200}$")

# --- normalising ytmusicapi results -----------------------------------------


def thumb(thumbnails: list | None, size: int = 544) -> str | None:
    """Pick the biggest thumbnail. googleusercontent URLs end with a size spec
    like '=w60-h60-l90-rj' that we can rewrite to get a sharper image."""
    if not thumbnails:
        return None
    url = thumbnails[-1]["url"]
    if "googleusercontent.com" in url:
        url = re.sub(r"=(w\d+-h\d+|s\d+)[^/]*$", f"=w{size}-h{size}-l90-rj", url)
    return url


def _artists(x: dict) -> str:
    return ", ".join(a["name"] for a in (x.get("artists") or []) if a.get("name"))


# YouTube Music has two kinds of playable things. "ATV" (audio track video) is
# the album recording: a still cover image with studio audio. Everything else
# is a real video (official music video, live clip, fan upload), whose sound
# can have intros, dialogue or lower quality.
AUDIO = "MUSIC_VIDEO_TYPE_ATV"


def _is_video(x: dict) -> bool:
    return x.get("resultType") == "video" or x.get("videoType") not in (None, AUDIO)


def item(x: dict) -> dict | None:
    """Convert any ytmusicapi result (song, album, playlist, artist) to an item."""
    t = thumb(x.get("thumbnails"))
    title = x.get("title") or x.get("artist") or x.get("name")
    browse = x.get("browseId") or ""
    if x.get("videoId"):
        artist = _artists(x)
        out = {"type": "song", "id": x["videoId"], "title": title, "subtitle": artist,
               "artist": artist, "duration": x.get("duration_seconds"), "thumbnail": t}
        if _is_video(x):
            out["video"] = True   # the music video's soundtrack, not the album recording
        return out
    if browse.startswith("MPRE"):
        sub = " • ".join(p for p in (x.get("type") or "Album", _artists(x), str(x.get("year") or "")) if p)
        return {"type": "album", "id": browse, "title": title, "subtitle": sub, "thumbnail": t}
    if browse.startswith("UC") or x.get("resultType") == "artist":
        return {"type": "artist", "id": browse, "title": title or x.get("artist"),
                "subtitle": x.get("subscribers") and f"{x['subscribers']} subscribers" or "Artist",
                "thumbnail": t}
    pid = x.get("playlistId") or (browse[2:] if browse.startswith("VL") else None)
    if pid:
        sub = x.get("description") or x.get("author") or ""
        if isinstance(sub, list):
            sub = ", ".join(a.get("name", "") for a in sub)
        return {"type": "playlist", "id": pid, "title": title, "subtitle": sub, "thumbnail": t}
    return None


def items(xs: list | None) -> list[dict]:
    out = [i for i in (item(x) for x in (xs or [])) if i and i.get("id") and i.get("title")]
    youtube.remember([s for s in out if s["type"] == "song"])  # so likes/playlists can use ids only
    return out


def shelf(title: str, xs: list | None) -> dict | None:
    its = items(xs)
    return {"title": title, "items": its} if its else None


def shelves(*pairs) -> list[dict]:
    return [s for s in (shelf(t, xs) for t, xs in pairs) if s]


# --- endpoints --------------------------------------------------------------


@router.get("/home")
async def home(fresh: bool = False):
    if fresh:  # pull-to-refresh in the app: skip our cache
        _cache.pop("home", None)
    data = await cached("home", HOUR, lambda: yt().get_home(limit=12))
    # Mood chips for the top of Home ("Energize", "Workout"...). Optional: Home
    # still loads if this part fails.
    try:
        groups = await cached("moods", 24 * HOUR, lambda: yt().get_mood_categories())
        first = next(iter(groups.values()), [])
        chips = [{"title": m["title"], "params": m["params"]} for m in first]
    except HTTPException:
        chips = []
    return {"shelves": shelves(*((s["title"], s["contents"]) for s in data)), "moods": chips}


@router.get("/explore")
async def explore():
    e = await cached("explore", HOUR, lambda: yt().get_explore())
    trending = (e.get("trending") or {}).get("items")
    return {
        "shelves": shelves(("New releases", e.get("new_releases")), ("Trending", trending),
                           ("New music videos", e.get("new_videos"))),
        "moods": [{"title": m["title"], "params": m["params"]} for m in e.get("moods_and_genres") or []],
    }


@router.get("/charts")
async def charts(country: str = Query("US", pattern=r"^[A-Z]{2}$")):
    c = await cached(f"charts:{country}", 6 * HOUR, lambda: yt().get_charts(country))
    return {
        "country": country,
        "countries": (c.get("countries") or {}).get("options") or [],
        "shelves": shelves(("Top charts", c.get("videos")), ("By genre", c.get("genres")),
                           ("By language", c.get("languages"))),
    }


@router.get("/moods")
async def moods():
    m = await cached("moods", 24 * HOUR, lambda: yt().get_mood_categories())
    return {"groups": [{"title": g, "moods": [{"title": x["title"], "params": x["params"]} for x in xs]}
                       for g, xs in m.items()]}


@router.get("/mood/{params}")
async def mood(params: str = yt_id()):
    pls = await cached(f"mood:{params}", 12 * HOUR, lambda: yt().get_mood_playlists(params))
    return {"items": items(pls)}


@router.get("/search")
async def search(q: str = Query(..., min_length=1, max_length=200),
                 filter: str | None = Query(None, pattern="^(songs|albums|artists|playlists|videos)$")):
    yt_filter = {"playlists": "community_playlists"}.get(filter, filter)
    res = await cached(f"search:{filter}:{q}", HOUR, lambda: yt().search(q, filter=yt_filter, limit=30))
    found = items(res)
    found.sort(key=lambda i: bool(i.get("video")))   # album recordings before videos (stable)
    return {"query": q, "items": found}


def _seconds(length: str | None) -> int | None:
    """"5:14" -> 314"""
    try:
        total = 0
        for part in (length or "").split(":"):
            total = total * 60 + int(part)
        return total or None
    except ValueError:
        return None


def _radio_sync(video_id: str, limit: int) -> list[dict]:
    tracks = yt().get_watch_playlist(video_id, radio=True, limit=limit + 1).get("tracks") or []
    seed = tracks[0] if tracks else {}
    if seed.get("videoId") == video_id and _is_video(seed):
        # A radio started from a music video is all music videos. Find the
        # album recording of the same song and start from that instead.
        q = f"{seed.get('title', '')} {_artists(seed)}".strip()
        audio = next((r for r in yt().search(q, filter="songs", limit=5) if r.get("videoId")), None)
        if audio:
            tracks = yt().get_watch_playlist(audio["videoId"], radio=True, limit=limit + 1).get("tracks") or []
            video_id = audio["videoId"]
    out = [{"id": t["videoId"], "title": t.get("title"), "artist": _artists(t),
            "duration": _seconds(t.get("length")), "thumbnail": thumb(t.get("thumbnail"))}
           for t in tracks if t.get("videoId") and t["videoId"] != video_id and not _is_video(t)]
    youtube.remember(out)
    return out[:limit]


async def radio(video_id: str, limit: int) -> list[dict]:
    """Similar songs from YouTube Music's radio: album recordings only."""
    return await asyncio.to_thread(_radio_sync, video_id, limit)


@router.get("/artist/{browse_id}")
async def artist(browse_id: str = yt_id()):
    a = await cached(f"artist:{browse_id}", 6 * HOUR, lambda: yt().get_artist(browse_id))
    part = lambda k: (a.get(k) or {}).get("results")  # noqa: E731
    return {
        "name": a.get("name"),
        "thumbnail": thumb(a.get("thumbnails"), 720),
        "description": a.get("description"),
        "subscribers": a.get("subscribers"),
        # "Top songs" lives in a playlist; the full list is at /music/playlist/<id>.
        "songs_playlist": ((a.get("songs") or {}).get("browseId") or "").removeprefix("VL") or None,
        "shelves": shelves(("Top songs", part("songs")), ("Albums", part("albums")),
                           ("Singles & EPs", part("singles")), ("Videos", part("videos")),
                           ("Fans might also like", part("related"))),
    }


@router.get("/album/{browse_id}")
async def album(browse_id: str = yt_id()):
    a = await cached(f"album:{browse_id}", 24 * HOUR, lambda: yt().get_album(browse_id))
    tracks = items([dict(t, thumbnails=t.get("thumbnails") or a.get("thumbnails"))
                    for t in a.get("tracks") or [] if t.get("videoId")])
    return {"title": a.get("title"), "subtitle": " • ".join(p for p in (a.get("type"), _artists(a), a.get("year")) if p),
            "thumbnail": thumb(a.get("thumbnails"), 720), "tracks": tracks}


@router.get("/playlist/{playlist_id}")
async def playlist(playlist_id: str = yt_id()):
    p = await cached(f"playlist:{playlist_id}", 3 * HOUR, lambda: yt().get_playlist(playlist_id, limit=200))
    author = p.get("author")
    author = author.get("name") if isinstance(author, dict) else author
    tracks = items([t for t in p.get("tracks") or [] if t.get("videoId") and t.get("isAvailable", True)])
    return {"title": p.get("title"), "subtitle": " • ".join(x for x in (author, f"{len(tracks)} songs") if x),
            "thumbnail": thumb(p.get("thumbnails"), 720), "tracks": tracks}


@router.get("/lyrics/{video_id}")
async def lyrics(video_id: str = yt_id()):
    def fetch():
        w = yt().get_watch_playlist(video_id, limit=1)
        if not w.get("lyrics"):
            return None
        return yt().get_lyrics(w["lyrics"])
    data = await cached(f"lyrics:{video_id}", 24 * HOUR, fetch)
    return {"lyrics": (data or {}).get("lyrics"), "source": (data or {}).get("source")}
