"""Podcasts: search, top charts, show pages, subscriptions, listening progress.

Podcasts are open RSS feeds, so none of this touches YouTube or yt-dlp:
  - Search and charts come from Apple's public podcast directory (no login).
  - A show's episodes come from its RSS feed, fetched and parsed here.
  - The phone plays each episode straight from the publisher's URL (like any
    podcast app). Episodes are big (often 100+ MB), so they are not copied
    onto the Pi's SD card.

Subscriptions and progress are stored per profile.
"""

import asyncio
import hashlib
import ipaddress
import logging
import re
import socket
import time
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
from urllib.parse import urljoin, urlparse

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field

from .library_api import lib, profile

log = logging.getLogger("pitunes.podcasts")
router = APIRouter(prefix="/podcasts")

MAX_FEED_BYTES = 25 * 1024 * 1024
MAX_EPISODES = 300          # newest N per show
FEED_TTL_S = 30 * 60
ITUNES = "https://itunes.apple.com"
NS = {"itunes": "http://www.itunes.com/dtds/podcast-1.0.dtd"}

_feeds: dict[str, tuple[float, dict]] = {}     # feed url -> (expires, parsed show)
_simple: dict[str, tuple[float, object]] = {}  # search/top results


# --- fetching ---------------------------------------------------------------

def _check_public(url: str) -> None:
    """Feed URLs come from clients, so refuse anything that isn't a public web
    address. Otherwise this endpoint could be used to make the Pi fetch things
    on your home network (SSRF)."""
    u = urlparse(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise HTTPException(400, "feed must be an http(s) URL")
    try:
        addrs = {info[4][0] for info in socket.getaddrinfo(u.hostname, None)}
    except socket.gaierror:
        raise HTTPException(502, "feed host not found")
    if not addrs or not all(ipaddress.ip_address(a).is_global for a in addrs):
        raise HTTPException(400, "feed host is not a public address")


async def _fetch_public(client: httpx.AsyncClient, url: str) -> bytes:
    """GET a public URL, checking every redirect hop, with a size cap."""
    for _ in range(6):
        await asyncio.to_thread(_check_public, url)
        async with client.stream("GET", url, follow_redirects=False,
                                 headers={"User-Agent": "pitunes (podcast client)"}) as r:
            if r.status_code in (301, 302, 303, 307, 308) and "location" in r.headers:
                url = urljoin(url, r.headers["location"])
                continue
            if r.status_code != 200:
                raise HTTPException(502, f"feed returned HTTP {r.status_code}")
            chunks, size = [], 0
            async for chunk in r.aiter_bytes():
                size += len(chunk)
                if size > MAX_FEED_BYTES:
                    raise HTTPException(502, "feed is too large")
                chunks.append(chunk)
            return b"".join(chunks)
    raise HTTPException(502, "too many redirects")


async def _itunes(client: httpx.AsyncClient, path: str, ttl: float) -> dict:
    hit = _simple.get(path)
    if hit and hit[0] > time.time():
        return hit[1]
    try:
        r = await client.get(ITUNES + path)
        r.raise_for_status()
        data = r.json()
    except (httpx.HTTPError, ValueError) as e:
        raise HTTPException(502, f"podcast directory request failed: {e}")
    if len(_simple) > 200:
        _simple.clear()
    _simple[path] = (time.time() + ttl, data)
    return data


def _show_from_itunes(x: dict) -> dict | None:
    if not x.get("feedUrl"):
        return None
    return {"feed": x["feedUrl"], "title": x.get("collectionName") or x.get("trackName"),
            "author": x.get("artistName"), "artwork": x.get("artworkUrl600") or x.get("artworkUrl100")}


# --- RSS parsing ------------------------------------------------------------

def _duration(text: str | None) -> int | None:
    """itunes:duration is seconds ("3725") or a clock ("1:02:05")."""
    if not text:
        return None
    try:
        parts = [float(p) for p in text.strip().split(":")]
    except ValueError:
        return None
    seconds = 0.0
    for p in parts:
        seconds = seconds * 60 + p
    return int(seconds) or None


def _clean(html: str | None, limit: int = 600) -> str:
    text = re.sub(r"<[^>]+>", " ", html or "")
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def episode_id(feed: str, guid: str) -> str:
    return "ep-" + hashlib.sha1(f"{feed}\n{guid}".encode()).hexdigest()[:20]


def parse_feed(feed: str, xml: bytes) -> dict:
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as e:
        raise HTTPException(502, f"feed is not valid XML: {e}")
    ch = root.find("channel")
    if ch is None:
        raise HTTPException(502, "not a podcast feed")

    def art(node):
        img = node.find("itunes:image", NS)
        return img.get("href") if img is not None else None

    show_art = art(ch) or (ch.findtext("image/url") or None)
    episodes = []
    for item in ch.iterfind("item"):
        enc = item.find("enclosure")
        if enc is None or not enc.get("url"):
            continue
        guid = (item.findtext("guid") or enc.get("url")).strip()
        published = None
        try:
            published = parsedate_to_datetime(item.findtext("pubDate") or "").timestamp()
        except (TypeError, ValueError):
            pass
        episodes.append({
            "id": episode_id(feed, guid),
            "title": (item.findtext("title") or "Untitled").strip(),
            "published": published,
            "duration": _duration(item.findtext("itunes:duration", namespaces=NS)),
            "audio_url": enc.get("url").strip(),
            "description": _clean(item.findtext("itunes:summary", namespaces=NS) or item.findtext("description")),
            "artwork": art(item) or show_art,
        })
    episodes.sort(key=lambda e: e["published"] or 0, reverse=True)
    return {
        "feed": feed,
        "title": (ch.findtext("title") or "Podcast").strip(),
        "author": (ch.findtext("itunes:author", namespaces=NS) or "").strip(),
        "description": _clean(ch.findtext("description"), 1000),
        "artwork": show_art,
        "episodes": episodes[:MAX_EPISODES],
    }


async def load_show(request: Request, feed: str) -> dict:
    hit = _feeds.get(feed)
    if hit and hit[0] > time.time():
        return hit[1]
    xml = await _fetch_public(request.app.state.upstream.client, feed)
    show = await asyncio.to_thread(parse_feed, feed, xml)
    if len(_feeds) > 30:  # parsed feeds are small, but don't keep them forever
        for k, _ in sorted(_feeds.items(), key=lambda kv: kv[1][0])[:10]:
            _feeds.pop(k, None)
    _feeds[feed] = (time.time() + FEED_TTL_S, show)
    return show


# --- endpoints: directory ---------------------------------------------------

@router.get("/search")
async def search(request: Request, q: str = Query(..., min_length=1, max_length=200)):
    from urllib.parse import quote
    data = await _itunes(request.app.state.upstream.client,
                         f"/search?media=podcast&limit=30&term={quote(q)}", 3600)
    return {"shows": [s for s in map(_show_from_itunes, data.get("results", [])) if s]}


# Apple's podcast categories shown as shelves on the Podcasts tab (name, genre id).
CATEGORIES = [("News", 1489), ("Comedy", 1303), ("True Crime", 1488), ("Science", 1533),
              ("Technology", 1318), ("Business", 1321), ("Health & Fitness", 1512),
              ("Society & Culture", 1324), ("Sports", 1545), ("Education", 1304)]


async def _chart(client: httpx.AsyncClient, country: str, genre: int | None = None, limit: int = 30) -> list[dict]:
    """Apple's top-podcasts chart, overall or for one category."""
    part = f"/genre={genre}" if genre else ""
    chart = await _itunes(client, f"/{country.lower()}/rss/toppodcasts/limit={limit}{part}/json", 6 * 3600)
    entries = chart.get("feed", {}).get("entry", [])
    if isinstance(entries, dict):  # a one-show chart comes back as a single object
        entries = [entries]
    ids = [e["id"]["attributes"]["im:id"] for e in entries]
    if not ids:
        return []
    # The chart has no feed addresses; look them up in one request.
    looked = await _itunes(client, f"/lookup?id={','.join(ids)}", 6 * 3600)
    by_id = {str(x.get("collectionId")): x for x in looked.get("results", [])}
    return [s for s in (_show_from_itunes(by_id[i]) for i in ids if i in by_id) if s]


@router.get("/top")
async def top(request: Request, country: str = Query("us", pattern=r"^[A-Za-z]{2}$")):
    return {"shows": await _chart(request.app.state.upstream.client, country)}


@router.get("/browse")
async def browse(request: Request, country: str = Query("us", pattern=r"^[A-Za-z]{2}$")):
    """The Podcasts tab in one request: the overall chart plus one shelf per
    category. A category that fails to load is left out."""
    client = request.app.state.upstream.client
    wanted = [("Top shows", None), *CATEGORIES]
    charts = await asyncio.gather(*(_chart(client, country, genre, 30 if genre is None else 20)
                                    for _, genre in wanted), return_exceptions=True)
    shelves = [{"title": title, "shows": shows}
               for (title, _), shows in zip(wanted, charts) if isinstance(shows, list) and shows]
    if not shelves:
        raise HTTPException(502, "podcast directory request failed")
    return {"shelves": shelves}


@router.get("/show")
async def show(request: Request, feed: str = Query(..., max_length=2000), pid: int = Depends(profile)):
    data = await load_show(request, feed)
    progress = lib(request).episode_progress(pid, feed)
    return {**data, "subscribed": lib(request).is_subscribed(pid, feed),
            "episodes": [{**e, **progress.get(e["id"], {})} for e in data["episodes"]]}


# --- endpoints: subscriptions & progress (per profile) ----------------------

class ShowIn(BaseModel):
    feed: str = Field(max_length=2000)
    title: str = Field(max_length=300)
    author: str | None = None
    artwork: str | None = None


class ProgressIn(BaseModel):
    id: str = Field(pattern=r"^ep-[0-9a-f]{20}$")
    feed: str = Field(max_length=2000)
    title: str = Field(max_length=500)
    show: str | None = None
    audio_url: str = Field(max_length=3000)
    artwork: str | None = None
    duration: int | None = None
    position: float = Field(ge=0)
    finished: bool = False


@router.get("/subscriptions")
async def subscriptions(request: Request, pid: int = Depends(profile)):
    return lib(request).subscriptions(pid)


@router.put("/subscriptions")
async def subscribe(body: ShowIn, request: Request, pid: int = Depends(profile)):
    await asyncio.to_thread(_check_public, body.feed)
    lib(request).subscribe(pid, body.model_dump())
    return {"feed": body.feed, "subscribed": True}


@router.delete("/subscriptions")
async def unsubscribe(request: Request, feed: str = Query(..., max_length=2000), pid: int = Depends(profile)):
    lib(request).unsubscribe(pid, feed)
    return {"feed": feed, "subscribed": False}


@router.put("/progress")
async def save_progress(body: ProgressIn, request: Request, pid: int = Depends(profile)):
    """The app reports where you are in an episode every ~15 s and on pause."""
    lib(request).save_progress(pid, body.model_dump())
    return {"id": body.id}


@router.get("/continue")
async def continue_listening(request: Request, pid: int = Depends(profile)):
    """Episodes you started but haven't finished, most recent first."""
    return lib(request).in_progress(pid)
