"""SQLite library: songs, playlists, likes, play history.

Every user-owned row has a profile_id, so a second person can get their own
likes/playlists/history later. Profile 1 is created automatically.

SQLite calls here are tiny and fast, so we call them directly from async code
(no thread pool). WAL mode + synchronous=NORMAL keeps SD card fsyncs low.
"""

import sqlite3
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS profiles (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    created_at  REAL NOT NULL
);
-- Song metadata, shared by all profiles. id = YouTube video id.
CREATE TABLE IF NOT EXISTS songs (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    artist      TEXT,
    duration    INTEGER,
    thumbnail   TEXT,
    added_at    REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS playlists (
    id          INTEGER PRIMARY KEY,
    profile_id  INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    created_at  REAL NOT NULL,
    updated_at  REAL NOT NULL
);
-- One row per song in a playlist; the same song may appear twice, so items
-- have their own id. `position` orders them (0, 1, 2, ...).
CREATE TABLE IF NOT EXISTS playlist_items (
    id          INTEGER PRIMARY KEY,
    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    song_id     TEXT NOT NULL REFERENCES songs(id),
    position    INTEGER NOT NULL,
    added_at    REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS playlist_items_by_playlist ON playlist_items(playlist_id, position);
CREATE TABLE IF NOT EXISTS likes (
    profile_id  INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    song_id     TEXT NOT NULL REFERENCES songs(id),
    created_at  REAL NOT NULL,
    PRIMARY KEY (profile_id, song_id)
);
-- Artists (and later other pages) a profile follows; shown in the Library.
CREATE TABLE IF NOT EXISTS saved (
    profile_id  INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    type        TEXT NOT NULL,
    id          TEXT NOT NULL,
    title       TEXT NOT NULL,
    subtitle    TEXT,
    thumbnail   TEXT,
    added_at    REAL NOT NULL,
    PRIMARY KEY (profile_id, type, id)
);
CREATE TABLE IF NOT EXISTS plays (
    id          INTEGER PRIMARY KEY,
    profile_id  INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    song_id     TEXT NOT NULL REFERENCES songs(id),
    played_at   REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS plays_by_profile ON plays(profile_id, played_at);
-- Songs a profile pinned to the front of their speed dial.
CREATE TABLE IF NOT EXISTS pins (
    profile_id  INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    song_id     TEXT NOT NULL REFERENCES songs(id),
    pinned_at   REAL NOT NULL,
    PRIMARY KEY (profile_id, song_id)
);
CREATE TABLE IF NOT EXISTS podcast_subs (
    profile_id  INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    feed        TEXT NOT NULL,
    title       TEXT NOT NULL,
    author      TEXT,
    artwork     TEXT,
    added_at    REAL NOT NULL,
    PRIMARY KEY (profile_id, feed)
);
-- Where each profile is in each episode they've started. Enough metadata is
-- kept to show "Continue listening" without re-fetching the feed.
CREATE TABLE IF NOT EXISTS episode_progress (
    profile_id  INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    episode_id  TEXT NOT NULL,
    feed        TEXT NOT NULL,
    title       TEXT NOT NULL,
    show        TEXT,
    audio_url   TEXT NOT NULL,
    artwork     TEXT,
    duration    INTEGER,
    position    REAL NOT NULL,
    finished    INTEGER NOT NULL DEFAULT 0,
    updated_at  REAL NOT NULL,
    PRIMARY KEY (profile_id, episode_id)
);
"""

SONG_COLS = "s.id, s.title, s.artist, s.duration, s.thumbnail"


class NotFound(Exception):
    pass


def _song(row) -> dict:
    return {k: row[k] for k in ("id", "title", "artist", "duration", "thumbnail")}


class Library:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(SCHEMA)
        self.db.execute(
            "INSERT OR IGNORE INTO profiles (id, name, created_at) VALUES (1, 'me', ?)", (time.time(),)
        )
        # Added later: which Tailscale user a profile belongs to (see identity.py).
        if "ts_user" not in [r["name"] for r in self.db.execute("PRAGMA table_info(profiles)")]:
            self.db.execute("ALTER TABLE profiles ADD COLUMN ts_user TEXT")

    def close(self) -> None:
        self.db.close()

    # --- profiles ---------------------------------------------------------

    def profiles(self) -> list[dict]:
        return [dict(r) for r in self.db.execute("SELECT id, name FROM profiles ORDER BY id")]

    def profiles_with_owner(self) -> list[dict]:
        """Profiles, each marked `claimed` if a Tailscale user already owns it."""
        return [{"id": r["id"], "name": r["name"], "claimed": r["ts_user"] is not None}
                for r in self.db.execute("SELECT id, name, ts_user FROM profiles ORDER BY id")]

    def profile_of(self, ts_user: str) -> dict | None:
        row = self.db.execute("SELECT id, name FROM profiles WHERE ts_user = ?", (ts_user,)).fetchone()
        return dict(row) if row else None

    def claim_profile(self, profile_id: int, ts_user: str) -> dict:
        """Make `profile_id` this Tailscale user's profile (and release any
        profile they had before). Fails if someone else owns it."""
        row = self.db.execute("SELECT ts_user FROM profiles WHERE id = ?", (profile_id,)).fetchone()
        if not row:
            raise NotFound(f"profile {profile_id}")
        if row["ts_user"] not in (None, ts_user):
            raise PermissionError("that profile belongs to someone else")
        self.db.execute("UPDATE profiles SET ts_user = NULL WHERE ts_user = ?", (ts_user,))
        self.db.execute("UPDATE profiles SET ts_user = ? WHERE id = ?", (ts_user, profile_id))
        return self.profile_of(ts_user)

    def create_profile(self, name: str) -> dict:
        cur = self.db.execute("INSERT INTO profiles (name, created_at) VALUES (?, ?)", (name, time.time()))
        return {"id": cur.lastrowid, "name": name}

    def check_profile(self, profile_id: int) -> None:
        if not self.db.execute("SELECT 1 FROM profiles WHERE id = ?", (profile_id,)).fetchone():
            raise NotFound(f"profile {profile_id}")

    # --- songs ------------------------------------------------------------

    def upsert_song(self, song: dict) -> None:
        """Insert or refresh a song's metadata (fields left empty are kept)."""
        self.db.execute(
            """INSERT INTO songs (id, title, artist, duration, thumbnail, added_at)
               VALUES (:id, :title, :artist, :duration, :thumbnail, :now)
               ON CONFLICT(id) DO UPDATE SET
                 title = coalesce(excluded.title, title),
                 artist = coalesce(excluded.artist, artist),
                 duration = coalesce(excluded.duration, duration),
                 thumbnail = coalesce(excluded.thumbnail, thumbnail)""",
            {"artist": None, "duration": None, "thumbnail": None, **song,
             "title": song.get("title") or song["id"], "now": time.time()},
        )

    # --- likes ------------------------------------------------------------

    def likes(self, profile_id: int) -> list[dict]:
        rows = self.db.execute(
            f"""SELECT {SONG_COLS}, l.created_at AS liked_at FROM likes l
                JOIN songs s ON s.id = l.song_id
                WHERE l.profile_id = ? ORDER BY l.created_at DESC""",
            (profile_id,),
        )
        return [{**_song(r), "liked_at": r["liked_at"]} for r in rows]

    def like(self, profile_id: int, song_id: str) -> None:
        self.db.execute(
            "INSERT OR IGNORE INTO likes (profile_id, song_id, created_at) VALUES (?, ?, ?)",
            (profile_id, song_id, time.time()),
        )

    def unlike(self, profile_id: int, song_id: str) -> None:
        self.db.execute("DELETE FROM likes WHERE profile_id = ? AND song_id = ?", (profile_id, song_id))

    def liked_ids_all_profiles(self) -> set[str]:
        """Songs liked by anyone. These are pinned in the disk cache."""
        return {r[0] for r in self.db.execute("SELECT DISTINCT song_id FROM likes")}

    # --- playlists --------------------------------------------------------

    def playlists(self, profile_id: int) -> list[dict]:
        rows = self.db.execute(
            """SELECT p.id, p.name, p.updated_at, count(i.id) AS song_count
               FROM playlists p LEFT JOIN playlist_items i ON i.playlist_id = p.id
               WHERE p.profile_id = ? GROUP BY p.id ORDER BY p.name COLLATE NOCASE""",
            (profile_id,),
        )
        return [dict(r) for r in rows]

    def _own_playlist(self, profile_id: int, playlist_id: int) -> sqlite3.Row:
        row = self.db.execute(
            "SELECT id, name, updated_at FROM playlists WHERE id = ? AND profile_id = ?",
            (playlist_id, profile_id),
        ).fetchone()
        if not row:
            raise NotFound(f"playlist {playlist_id}")
        return row

    def _touch_playlist(self, playlist_id: int) -> None:
        self.db.execute("UPDATE playlists SET updated_at = ? WHERE id = ?", (time.time(), playlist_id))

    def create_playlist(self, profile_id: int, name: str) -> dict:
        now = time.time()
        cur = self.db.execute(
            "INSERT INTO playlists (profile_id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
            (profile_id, name, now, now),
        )
        return self.playlist(profile_id, cur.lastrowid)

    def playlist(self, profile_id: int, playlist_id: int) -> dict:
        p = self._own_playlist(profile_id, playlist_id)
        items = self.db.execute(
            f"""SELECT i.id AS item_id, {SONG_COLS} FROM playlist_items i
                JOIN songs s ON s.id = i.song_id
                WHERE i.playlist_id = ? ORDER BY i.position""",
            (playlist_id,),
        )
        return {**dict(p), "songs": [{"item_id": r["item_id"], **_song(r)} for r in items]}

    def rename_playlist(self, profile_id: int, playlist_id: int, name: str) -> dict:
        self._own_playlist(profile_id, playlist_id)
        self.db.execute("UPDATE playlists SET name = ?, updated_at = ? WHERE id = ?",
                        (name, time.time(), playlist_id))
        return self.playlist(profile_id, playlist_id)

    def delete_playlist(self, profile_id: int, playlist_id: int) -> None:
        self._own_playlist(profile_id, playlist_id)
        self.db.execute("DELETE FROM playlists WHERE id = ?", (playlist_id,))

    def add_to_playlist(self, profile_id: int, playlist_id: int, song_id: str) -> dict:
        self._own_playlist(profile_id, playlist_id)
        (nxt,) = self.db.execute(
            "SELECT coalesce(max(position) + 1, 0) FROM playlist_items WHERE playlist_id = ?",
            (playlist_id,),
        ).fetchone()
        self.db.execute(
            "INSERT INTO playlist_items (playlist_id, song_id, position, added_at) VALUES (?, ?, ?, ?)",
            (playlist_id, song_id, nxt, time.time()),
        )
        self._touch_playlist(playlist_id)
        return self.playlist(profile_id, playlist_id)

    def remove_from_playlist(self, profile_id: int, playlist_id: int, item_id: int) -> dict:
        self._own_playlist(profile_id, playlist_id)
        self.db.execute("DELETE FROM playlist_items WHERE id = ? AND playlist_id = ?", (item_id, playlist_id))
        self._touch_playlist(playlist_id)
        return self.playlist(profile_id, playlist_id)

    def reorder_playlist(self, profile_id: int, playlist_id: int, item_ids: list[int]) -> dict:
        """Set the order of a playlist. `item_ids` must list every item exactly once."""
        self._own_playlist(profile_id, playlist_id)
        current = {r[0] for r in self.db.execute(
            "SELECT id FROM playlist_items WHERE playlist_id = ?", (playlist_id,))}
        if set(item_ids) != current or len(item_ids) != len(current):
            raise ValueError("item_ids must contain every item in the playlist exactly once")
        with self.db:  # one transaction
            self.db.execute("BEGIN")
            for pos, item_id in enumerate(item_ids):
                self.db.execute("UPDATE playlist_items SET position = ? WHERE id = ?", (pos, item_id))
        self._touch_playlist(playlist_id)
        return self.playlist(profile_id, playlist_id)

    # --- play history -----------------------------------------------------

    # --- saved pages (followed artists) ----------------------------------

    def saved(self, profile_id: int) -> list[dict]:
        rows = self.db.execute(
            "SELECT type, id, title, subtitle, thumbnail FROM saved WHERE profile_id = ? ORDER BY added_at DESC",
            (profile_id,))
        return [dict(r) for r in rows]

    def save_item(self, profile_id: int, item: dict) -> None:
        self.db.execute(
            """INSERT OR REPLACE INTO saved (profile_id, type, id, title, subtitle, thumbnail, added_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (profile_id, item["type"], item["id"], item["title"], item.get("subtitle"),
             item.get("thumbnail"), time.time()))

    def unsave_item(self, profile_id: int, type_: str, item_id: str) -> None:
        self.db.execute("DELETE FROM saved WHERE profile_id = ? AND type = ? AND id = ?",
                        (profile_id, type_, item_id))

    # --- plays ------------------------------------------------------------

    def record_play(self, profile_id: int, song_id: str) -> None:
        self.db.execute("INSERT INTO plays (profile_id, song_id, played_at) VALUES (?, ?, ?)",
                        (profile_id, song_id, time.time()))

    def history(self, profile_id: int, limit: int) -> list[dict]:
        rows = self.db.execute(
            f"""SELECT {SONG_COLS}, p.played_at FROM plays p JOIN songs s ON s.id = p.song_id
                WHERE p.profile_id = ? ORDER BY p.played_at DESC LIMIT ?""",
            (profile_id, limit),
        )
        return [{**_song(r), "played_at": r["played_at"]} for r in rows]

    def speed_dial(self, profile_id: int, limit: int) -> list[dict]:
        """Your go-to songs: most played first (recent plays count more), then
        recently liked songs to fill the grid."""
        now = time.time()
        rows = self.db.execute(
            f"""SELECT {SONG_COLS},
                       -- each play is worth 1, fading to ~0.37 after 30 days
                       sum(exp(-(? - p.played_at) / (30 * 86400.0))) AS score
                FROM plays p JOIN songs s ON s.id = p.song_id
                WHERE p.profile_id = ? GROUP BY s.id ORDER BY score DESC LIMIT ?""",
            (now, profile_id, limit),
        )
        # Pinned songs always come first, newest pin first.
        songs = self.pins(profile_id)[:limit]
        have = {s["id"] for s in songs}
        songs += [_song(r) for r in rows if r["id"] not in have]
        songs = songs[:limit]
        if len(songs) < limit:
            have = {s["id"] for s in songs}
            for liked in self.likes(profile_id):
                if liked["id"] not in have:
                    songs.append({k: liked[k] for k in ("id", "title", "artist", "duration", "thumbnail")})
                    if len(songs) == limit:
                        break
        return songs

    def pins(self, profile_id: int) -> list[dict]:
        rows = self.db.execute(
            f"""SELECT {SONG_COLS} FROM pins p JOIN songs s ON s.id = p.song_id
                WHERE p.profile_id = ? ORDER BY p.pinned_at DESC""", (profile_id,))
        return [_song(r) for r in rows]

    def pin(self, profile_id: int, song_id: str) -> None:
        self.db.execute("INSERT OR IGNORE INTO pins (profile_id, song_id, pinned_at) VALUES (?, ?, ?)",
                        (profile_id, song_id, time.time()))

    def unpin(self, profile_id: int, song_id: str) -> None:
        self.db.execute("DELETE FROM pins WHERE profile_id = ? AND song_id = ?", (profile_id, song_id))

    # --- podcasts ---------------------------------------------------------

    def subscriptions(self, profile_id: int) -> list[dict]:
        rows = self.db.execute(
            "SELECT feed, title, author, artwork FROM podcast_subs WHERE profile_id = ? "
            "ORDER BY title COLLATE NOCASE", (profile_id,))
        return [dict(r) for r in rows]

    def is_subscribed(self, profile_id: int, feed: str) -> bool:
        return self.db.execute("SELECT 1 FROM podcast_subs WHERE profile_id = ? AND feed = ?",
                               (profile_id, feed)).fetchone() is not None

    def subscribe(self, profile_id: int, show: dict) -> None:
        self.db.execute(
            """INSERT INTO podcast_subs (profile_id, feed, title, author, artwork, added_at)
               VALUES (:pid, :feed, :title, :author, :artwork, :now)
               ON CONFLICT(profile_id, feed) DO UPDATE SET title = excluded.title,
                 author = excluded.author, artwork = excluded.artwork""",
            {**show, "pid": profile_id, "now": time.time()})

    def unsubscribe(self, profile_id: int, feed: str) -> None:
        self.db.execute("DELETE FROM podcast_subs WHERE profile_id = ? AND feed = ?", (profile_id, feed))

    def save_progress(self, profile_id: int, ep: dict) -> None:
        self.db.execute(
            """INSERT INTO episode_progress (profile_id, episode_id, feed, title, show, audio_url,
                                             artwork, duration, position, finished, updated_at)
               VALUES (:pid, :id, :feed, :title, :show, :audio_url, :artwork, :duration, :position, :finished, :now)
               ON CONFLICT(profile_id, episode_id) DO UPDATE SET
                 position = excluded.position, finished = excluded.finished, updated_at = excluded.updated_at,
                 duration = coalesce(excluded.duration, duration)""",
            {**ep, "finished": int(ep["finished"]), "pid": profile_id, "now": time.time()})

    def episode_progress(self, profile_id: int, feed: str) -> dict[str, dict]:
        rows = self.db.execute(
            "SELECT episode_id, position, finished FROM episode_progress WHERE profile_id = ? AND feed = ?",
            (profile_id, feed))
        return {r["episode_id"]: {"position": r["position"], "finished": bool(r["finished"])} for r in rows}

    def in_progress(self, profile_id: int, limit: int = 20) -> list[dict]:
        rows = self.db.execute(
            """SELECT episode_id AS id, feed, title, show, audio_url, artwork, duration, position
               FROM episode_progress WHERE profile_id = ? AND finished = 0 AND position > 30
               ORDER BY updated_at DESC LIMIT ?""", (profile_id, limit))
        return [{**dict(r), "finished": False} for r in rows]
