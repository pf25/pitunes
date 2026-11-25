"""Server tests that need no network: range parsing, cache eviction/pinning,
resolve priority, the library API, host checking, and the image allowlist.

Run with:  cd server && uv run pytest
"""

import asyncio
import os
import sqlite3
import tempfile

import pytest

# Point the server at a throwaway data dir before importing it.
_tmp = tempfile.mkdtemp(prefix="pitunes-test-")
os.environ["PITUNES_DATA_DIR"] = _tmp
os.environ["PITUNES_JS_WORKER"] = "0"   # no Deno / network in tests

from fastapi.testclient import TestClient  # noqa: E402

from pitunes import images, main  # noqa: E402
from pitunes.cache import SongCache  # noqa: E402
from pitunes.upstream import RangeNotSatisfiable, parse_range  # noqa: E402
from pitunes.youtube import PriorityGate  # noqa: E402

ID1, ID2, ID3 = "aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc"


# --- Range parsing ----------------------------------------------------------

@pytest.mark.parametrize("header,expected", [
    (None, (0, 999, False)),
    ("bytes=0-", (0, 999, True)),
    ("bytes=100-199", (100, 199, True)),
    ("bytes=-100", (900, 999, True)),
    ("bytes=500-5000", (500, 999, True)),     # end clamped to the file
    ("bytes=0-0,5-9", (0, 0, True)),          # only the first range
    ("garbage", (0, 999, False)),
    ("bytes=-", (0, 999, False)),
])
def test_parse_range(header, expected):
    assert parse_range(header, 1000) == expected


@pytest.mark.parametrize("header", ["bytes=1000-", "bytes=5000-6000", "bytes=10-5"])
def test_parse_range_unsatisfiable(header):
    with pytest.raises(RangeNotSatisfiable):
        parse_range(header, 1000)


# --- Cache ------------------------------------------------------------------

def _song(cache: SongCache, vid: str, size: int, age: float = 0):
    cache.path(vid).write_bytes(b"x" * size)
    cache.add(vid, size)
    cache._entries[vid][1] -= age  # pretend it was last played `age` seconds ago


def test_cache_evicts_least_recently_used(tmp_path):
    cache = SongCache(tmp_path, max_bytes=250)
    _song(cache, ID1, 100, age=300)
    _song(cache, ID2, 100, age=200)
    _song(cache, ID3, 100, age=100)   # 300 > 250: oldest (ID1) goes
    cache._evict()
    assert cache.get(ID1) is None and not cache.path(ID1).exists()
    assert cache.get(ID2) and cache.get(ID3)


def test_cache_never_evicts_pinned(tmp_path):
    cache = SongCache(tmp_path, max_bytes=150)
    cache.pinned = {ID1}
    _song(cache, ID1, 100, age=300)   # oldest, but liked
    cache.path(ID2).write_bytes(b"x" * 100)
    cache.add(ID2, 100)               # over the cap: ID2 goes, not the liked song
    assert cache.get(ID1) and cache.get(ID2) is None and not cache.path(ID2).exists()


def test_cache_rescan_keeps_songs_and_drops_partials(tmp_path):
    (tmp_path / f"{ID1}.m4a").write_bytes(b"x" * 10)
    (tmp_path / f"{ID2}.m4a.part").write_bytes(b"x" * 10)
    cache = SongCache(tmp_path, max_bytes=1000)
    assert cache.get(ID1) and not (tmp_path / f"{ID2}.m4a.part").exists()


# --- Resolve priority -------------------------------------------------------

def test_priority_gate_urgent_goes_first():
    async def run():
        gate, order = PriorityGate(1), []
        await gate.acquire("running", False)

        async def want(key, urgent):
            await gate.acquire(key, urgent)
            order.append(key)
            gate.release()

        tasks = [asyncio.create_task(want("prefetch1", False)),
                 asyncio.create_task(want("prefetch2", False)),
                 asyncio.create_task(want("play", True))]
        await asyncio.sleep(0)
        gate.bump("prefetch2")          # someone pressed play on a queued prefetch
        gate.release()
        await asyncio.gather(*tasks)
        return order

    assert asyncio.run(run()) == ["prefetch2", "play", "prefetch1"]


# --- HTTP API ---------------------------------------------------------------

@pytest.fixture(scope="module")
def client():
    with TestClient(main.app) as c:
        yield c


def test_library_roundtrip(client):
    song = {"id": ID1, "title": "Song A", "artist": "Artist", "duration": 200}
    assert client.put("/likes", json=song).status_code == 200
    assert [s["id"] for s in client.get("/likes").json()] == [ID1]
    assert ID1 in main.app.state.cache.pinned

    pl = client.post("/playlists", json={"name": "Mix"}).json()
    for vid in (ID1, ID2, ID3):
        client.post(f"/playlists/{pl['id']}/songs", json={"id": vid, "title": vid})
    items = client.get(f"/playlists/{pl['id']}").json()["songs"]
    order = [items[2]["item_id"], items[0]["item_id"], items[1]["item_id"]]
    after = client.put(f"/playlists/{pl['id']}/order", json={"item_ids": order}).json()["songs"]
    assert [s["id"] for s in after] == [ID3, ID1, ID2]
    assert client.put(f"/playlists/{pl['id']}/order", json={"item_ids": order[:2]}).status_code == 400

    assert client.delete(f"/likes/{ID1}").json() == {"id": ID1, "liked": False}
    assert ID1 not in main.app.state.cache.pinned


def test_import_playlist_and_profiles_are_separate(client):
    body = {"name": "Imported", "songs": [{"id": ID1, "title": "A"}, {"id": ID2, "title": "B"}]}
    created = client.post("/playlists/import", json=body)
    assert created.status_code == 201 and len(created.json()["songs"]) == 2
    other = client.post("/profiles", json={"name": "second"}).json()["id"]
    assert client.get("/playlists", headers={"X-Profile-Id": str(other)}).json() == []
    assert client.get(f"/playlists/{created.json()['id']}", headers={"X-Profile-Id": str(other)}).status_code == 404
    assert client.get("/likes", headers={"X-Profile-Id": "999"}).status_code == 404


def test_bad_ids_rejected(client):
    assert client.get("/stream/short").status_code == 400
    assert client.post("/prefetch/..%2F..%2Fetc").status_code in (400, 404)
    assert client.put("/likes", json={"id": "../../etc/passwd"}).status_code == 422
    assert client.delete("/likes/not-a-valid-id!").status_code == 422
    assert client.get("/music/album/has spaces and $").status_code == 422


def test_backup_is_a_valid_database(client, tmp_path):
    r = client.get("/backup")
    assert r.status_code == 200
    f = tmp_path / "b.db"
    f.write_bytes(r.content)
    names = {row[0] for row in sqlite3.connect(f).execute("SELECT name FROM sqlite_master")}
    assert {"songs", "likes", "playlists", "plays", "profiles"} <= names


def test_unknown_host_refused(client):
    assert client.get("/health").status_code == 200                       # "testserver"
    assert client.get("/health", headers={"Host": "music:8000"}).status_code == 200
    assert client.get("/health", headers={"Host": "100.64.0.1:8000"}).status_code == 200
    assert client.get("/health", headers={"Host": "music.tail1234.ts.net"}).status_code == 200
    assert client.get("/health", headers={"Host": "evil.example.com"}).status_code == 421


@pytest.mark.parametrize("url,ok", [
    ("https://i.ytimg.com/vi/abc/hq720.jpg", True),
    ("https://yt3.googleusercontent.com/abc=w544-h544", True),
    ("http://i.ytimg.com/vi/abc/hq720.jpg", False),            # not https
    ("https://evil.com/i.ytimg.com/x.jpg", False),
    ("https://i.ytimg.com.evil.com/x.jpg", False),
    ("https://user@i.ytimg.com/x.jpg", False),
    ("https://i.ytimg.com:8443/x.jpg", False),
    ("https://127.0.0.1/x.jpg", False),
    ("file:///etc/passwd", False),
])
def test_image_proxy_allowlist(client, url, ok):
    assert images.allowed(url) is ok
    if not ok:
        assert client.get("/img", params={"u": url}).status_code == 400


def test_speed_dial_orders_by_plays_then_likes(client):
    a, b, c = "ddddddddddd", "eeeeeeeeeee", "fffffffffff"
    pid = client.post("/profiles", json={"name": "dial"}).json()["id"]
    h = {"X-Profile-Id": str(pid)}
    assert client.get("/speed-dial", headers=h).json() == []
    client.put("/likes", json={"id": c, "title": "Liked only"}, headers=h)
    for vid, n in ((a, 1), (b, 3)):
        for _ in range(n):
            client.post("/plays", json={"id": vid, "title": vid}, headers=h)
    assert [s["id"] for s in client.get("/speed-dial", headers=h).json()] == [b, a, c]
    assert len(client.get("/speed-dial?limit=2", headers=h).json()) == 2


def test_music_routes_accept_valid_ids(client, monkeypatch):
    """Valid ids must reach the handler (regression: a shared Path() object
    made every /music/{id} route answer 422)."""
    from pitunes import music

    async def fake_cached(key, ttl, fn):
        return {}
    monkeypatch.setattr(music, "cached", fake_cached)
    for path in ("/music/album/MPREb_0A68Xn9lRZr", "/music/playlist/RDCLAK5uy_nDL8KeBrUagwyISwNmyEiSfYgz1gVCesg",
                 "/music/artist/UCDxKh1gFWeYsqePvgVzmPoQ", "/music/lyrics/5NV6Rdv1a3I"):
        assert client.get(path).status_code == 200, path
    monkeypatch.setattr(music, "cached", lambda key, ttl, fn: _async([]))
    assert client.get("/music/mood/ggMPOg1uX1JOQWZFeDByc2Jm").status_code == 200


async def _async(value):
    return value


# --- Podcasts ---------------------------------------------------------------

FEED_XML = b"""<?xml version="1.0"?>
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" version="2.0"><channel>
<title>Test Show</title><itunes:author>Host</itunes:author><description>About &lt;b&gt;things&lt;/b&gt;</description>
<itunes:image href="https://example.com/art.jpg"/>
<item><title>Old one</title><guid>g1</guid><pubDate>Mon, 01 Jan 2024 10:00:00 GMT</pubDate>
  <itunes:duration>1:02:05</itunes:duration><enclosure url="https://example.com/1.mp3" type="audio/mpeg"/></item>
<item><title>New one</title><guid>g2</guid><pubDate>Tue, 02 Jan 2024 10:00:00 GMT</pubDate>
  <itunes:duration>600</itunes:duration><enclosure url="https://example.com/2.mp3" type="audio/mpeg"/></item>
<item><title>No audio</title><guid>g3</guid></item>
</channel></rss>"""


def test_parse_feed():
    from pitunes.podcasts import parse_feed
    show = parse_feed("https://example.com/feed", FEED_XML)
    assert show["title"] == "Test Show" and show["author"] == "Host" and show["description"] == "About things"
    assert [e["title"] for e in show["episodes"]] == ["New one", "Old one"]      # newest first, no-audio item dropped
    assert [e["duration"] for e in show["episodes"]] == [600, 3725]
    assert show["episodes"][0]["artwork"] == "https://example.com/art.jpg"
    assert show["episodes"][0]["id"].startswith("ep-")


@pytest.mark.parametrize("url", ["http://127.0.0.1/feed", "http://192.168.1.1/x", "http://localhost:8000/backup",
                                 "file:///etc/passwd", "http://[::1]/x", "ftp://example.com/x"])
def test_feed_must_be_public(url):
    from fastapi import HTTPException
    from pitunes.podcasts import _check_public
    with pytest.raises(HTTPException):
        _check_public(url)


def test_podcast_subscriptions_and_progress_per_profile(client, monkeypatch):
    from pitunes import podcasts
    monkeypatch.setattr(podcasts, "_check_public", lambda url: None)

    async def fake_fetch(_client, url):
        return FEED_XML
    monkeypatch.setattr(podcasts, "_fetch_public", fake_fetch)
    feed = "https://example.com/feed"
    me = {"X-Profile-Id": "1"}
    other = {"X-Profile-Id": str(client.post("/profiles", json={"name": "podfan"}).json()["id"])}

    show = client.get("/podcasts/show", params={"feed": feed}, headers=me).json()
    assert show["subscribed"] is False and len(show["episodes"]) == 2
    ep = show["episodes"][0]
    client.put("/podcasts/subscriptions", json={"feed": feed, "title": "Test Show"}, headers=me)
    assert [s["feed"] for s in client.get("/podcasts/subscriptions", headers=me).json()] == [feed]
    assert client.get("/podcasts/subscriptions", headers=other).json() == []

    body = {"id": ep["id"], "feed": feed, "title": ep["title"], "show": "Test Show",
            "audio_url": ep["audio_url"], "duration": 600, "position": 120.5}
    assert client.put("/podcasts/progress", json=body, headers=me).status_code == 200
    again = client.get("/podcasts/show", params={"feed": feed}, headers=me).json()
    assert again["subscribed"] is True and again["episodes"][0]["position"] == 120.5
    assert [e["id"] for e in client.get("/podcasts/continue", headers=me).json()] == [ep["id"]]
    assert client.get("/podcasts/continue", headers=other).json() == []
    client.put("/podcasts/progress", json={**body, "position": 598, "finished": True}, headers=me)
    assert client.get("/podcasts/continue", headers=me).json() == []
    client.delete("/podcasts/subscriptions", params={"feed": feed}, headers=me)
    assert client.get("/podcasts/subscriptions", headers=me).json() == []


def test_podcast_browse_shelves(client, monkeypatch):
    """One shelf per category; a category that fails is skipped, not fatal."""
    from fastapi import HTTPException
    from pitunes import podcasts

    async def fake_itunes(_client, path, ttl):
        if "genre=1303" in path:                       # Comedy is down
            raise HTTPException(502, "boom")
        if "/rss/toppodcasts/" in path:
            return {"feed": {"entry": [{"id": {"attributes": {"im:id": "7"}}}]}}
        return {"results": [{"collectionId": 7, "feedUrl": "https://example.com/f.xml",
                             "collectionName": "Show", "artistName": "Host"}]}
    monkeypatch.setattr(podcasts, "_itunes", fake_itunes)
    shelves = client.get("/podcasts/browse").json()["shelves"]
    titles = [s["title"] for s in shelves]
    assert titles[0] == "Top shows" and "Science" in titles and "Comedy" not in titles
    assert shelves[0]["shows"][0]["feed"] == "https://example.com/f.xml"
    assert client.get("/podcasts/top").json()["shows"][0]["title"] == "Show"


def test_saved_artists_are_per_profile(client):
    me = {"X-Profile-Id": "1"}
    other = {"X-Profile-Id": str(client.post("/profiles", json={"name": "follower"}).json()["id"])}
    artist = {"type": "artist", "id": "UC1234567890abcdefghijkl", "title": "Some Artist"}
    assert client.put("/saved", json=artist, headers=me).status_code == 200
    assert client.put("/saved", json=artist, headers=me).status_code == 200   # saving twice is fine
    assert [a["title"] for a in client.get("/saved", headers=me).json()] == ["Some Artist"]
    assert client.get("/saved", headers=other).json() == []
    assert client.put("/saved", json={**artist, "type": "song"}, headers=me).status_code == 422
    client.delete(f"/saved/artist/{artist['id']}", headers=me)
    assert client.get("/saved", headers=me).json() == []


def test_radio_prefers_album_recordings(client, monkeypatch):
    from pitunes import music
    """A radio started from a music video is re-seeded from the audio version,
    and any videos left in the result are dropped."""
    def track(vid, kind):
        return {"videoId": vid, "title": vid, "artists": [{"name": "A"}], "length": "3:05", "videoType": kind}

    class FakeYT:
        def get_watch_playlist(self, video_id, radio, limit):
            if video_id == "videoSeed01":
                return {"tracks": [track("videoSeed01", "MUSIC_VIDEO_TYPE_OMV")]}
            return {"tracks": [track("audioSeed01", music.AUDIO), track("audioNext01", music.AUDIO),
                               track("videoNext01", "MUSIC_VIDEO_TYPE_UGC")]}

        def search(self, q, filter, limit):
            return [{"videoId": "audioSeed01"}]

    monkeypatch.setattr(music, "yt", lambda: FakeYT())
    results = client.get("/radio/videoSeed01").json()["results"]
    assert [(s["id"], s["duration"]) for s in results] == [("audioNext01", 185)]


def test_profile_follows_tailscale_user(client, monkeypatch):
    """Once a Tailscale user picks a profile, they get it whatever the app sends."""
    from pitunes import identity, library_api
    who = {"value": None}

    async def fake_whois(ip):
        return who["value"]
    monkeypatch.setattr(identity, "whois", fake_whois)

    assert client.get("/me").json()["user"] is None            # not on Tailscale: header decides
    assert client.post("/me", json={"name": "nobody"}).status_code == 400

    who["value"] = {"id": "111", "name": "Asha"}
    assert client.get("/me").json()["profile"] is None
    mine = client.post("/me", json={"name": "Asha"}).json()
    assert client.get("/me").json()["profile"] == mine
    song = {"id": ID3, "title": "Only Asha's"}
    client.put("/likes", json=song, headers={"X-Profile-Id": "1"})  # header is ignored for her
    assert [s["id"] for s in client.get("/likes").json()] == [ID3]

    who["value"] = {"id": "222", "name": "Ravi"}
    assert client.post("/me", json={"profile_id": mine["id"]}).status_code == 409   # hers, not his
    claimed = {p["id"]: p["claimed"] for p in client.get("/me").json()["profiles"]}
    assert claimed[mine["id"]] is True and claimed[1] is False
    assert client.post("/me", json={"profile_id": 1}).json()["id"] == 1
    assert ID3 not in [s["id"] for s in client.get("/likes").json()]
    who["value"] = None
    main.app.state.library.db.execute("UPDATE profiles SET ts_user = NULL")


def test_pinned_songs_lead_the_speed_dial(client):
    played = {"id": "ppppppppppp", "title": "Played a lot"}
    pinned = {"id": "qqqqqqqqqqq", "title": "Pinned"}
    for _ in range(3):
        client.post("/plays", json=played)
    assert client.put("/pins", json=pinned).status_code == 200
    dial = [s["id"] for s in client.get("/speed-dial").json()]
    assert dial[0] == pinned["id"] and played["id"] in dial
    assert [s["id"] for s in client.get("/pins").json()] == [pinned["id"]]
    client.delete(f"/pins/{pinned['id']}")
    assert pinned["id"] not in [s["id"] for s in client.get("/speed-dial").json()]


def test_memory_guard_restarts_the_server_over_the_limit(monkeypatch):
    """Over the limit the guard sends itself a normal shutdown signal (systemd
    then starts a fresh server); under the limit it leaves things alone."""
    import signal

    async def run(in_use_mb: float) -> list:
        sent, sleeps = [], []

        async def one_tick(_seconds):          # first sleep returns, second ends the loop
            sleeps.append(1)
            if len(sleeps) > 1:
                raise asyncio.CancelledError

        monkeypatch.setattr(main.asyncio, "sleep", one_tick)
        monkeypatch.setattr(main, "memory_in_use_mb", lambda: in_use_mb)
        monkeypatch.setattr(main.os, "kill", lambda pid, sig: sent.append((pid, sig)))
        try:
            await main._memory_guard()
        except asyncio.CancelledError:
            pass
        return sent

    limit = main.config.MEMORY_LIMIT_MB
    assert asyncio.run(run(limit + 50)) == [(os.getpid(), signal.SIGTERM)]
    assert asyncio.run(run(limit - 50)) == []


def test_memory_in_use_counts_this_process():
    """On Linux the number is real and at least a few MB; elsewhere it is None."""
    used = main.memory_in_use_mb()
    if os.path.isdir("/proc/self"):
        assert used and used > 5
        assert main._memory()["limit_mb"] == main.config.MEMORY_LIMIT_MB
    else:
        assert used is None
