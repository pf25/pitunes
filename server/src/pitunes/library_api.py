"""Library endpoints: profiles, likes, playlists, play history.

Which profile? Clients send an `X-Profile-Id` header; it defaults to 1, so a
single-user app can ignore profiles entirely.

Songs in request bodies: `{"id": "..."}` is enough if the server saw the song
recently in search/radio results; otherwise also send title/artist/duration/
thumbnail so the library can show it.
"""

import sqlite3

from fastapi import APIRouter, Depends, Header, HTTPException, Path, Request
from pydantic import BaseModel, Field

from . import identity, youtube
from .db import Library, NotFound

router = APIRouter()

VIDEO_ID_PATTERN = r"^[A-Za-z0-9_-]{11}$"


class SongIn(BaseModel):
    id: str = Field(pattern=VIDEO_ID_PATTERN)
    title: str | None = None
    artist: str | None = None
    duration: int | None = None
    thumbnail: str | None = None


class NameIn(BaseModel):
    name: str = Field(min_length=1, max_length=100)


class OrderIn(BaseModel):
    item_ids: list[int]


class ImportIn(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    songs: list[SongIn] = Field(max_length=1000)


def lib(request: Request) -> Library:
    return request.app.state.library


async def caller(request: Request) -> dict | None:
    """The Tailscale user making this request, if there is one."""
    ip = request.client.host if request.client else None
    # Requests to the HTTPS address arrive through `tailscale serve` on this
    # machine, which passes the real device's address along in a header. Only
    # trust that header from the machine itself.
    if ip in ("127.0.0.1", "::1"):
        forwarded = request.headers.get("x-forwarded-for", "").split(",")[0].strip()
        ip = forwarded or ip
    return await identity.whois(ip)


async def profile(request: Request, x_profile_id: int = Header(1)) -> int:
    # A Tailscale user who has picked their profile always gets that one,
    # whatever the app sends. Everyone else: the profile the app asks for.
    who = await caller(request)
    mine = who and lib(request).profile_of(who["id"])
    if mine:
        return mine["id"]
    try:
        lib(request).check_profile(x_profile_id)
    except NotFound:
        raise HTTPException(404, f"profile {x_profile_id} not found")
    return x_profile_id


def _store_song(request: Request, song: SongIn) -> str:
    """Save the song's metadata, filling gaps from recent search/radio results."""
    data = {**(youtube.known(song.id) or {}), **song.model_dump(exclude_none=True)}
    data.pop("stream_url", None)
    lib(request).upsert_song(data)
    return song.id


def _not_found(e: NotFound):
    raise HTTPException(404, f"{e} not found")


# --- profiles ---------------------------------------------------------------


@router.get("/profiles")
async def list_profiles(request: Request):
    return lib(request).profiles()


class ClaimIn(BaseModel):
    """Pick an existing profile, or give a name to start a new one."""
    profile_id: int | None = None
    name: str | None = Field(None, min_length=1, max_length=100)


@router.get("/me")
async def me(request: Request):
    """Who the server thinks you are, and the profiles you could pick."""
    who = await caller(request)
    return {"user": who, "profile": who and lib(request).profile_of(who["id"]),
            "profiles": lib(request).profiles_with_owner(),
            # The web app shows this when it's opened on the plain http address.
            "https": await identity.https_address()}


@router.post("/me")
async def claim(body: ClaimIn, request: Request):
    """Tie a profile to the caller's Tailscale account, once per person."""
    who = await caller(request)
    if not who:
        raise HTTPException(400, "this device isn't signed in to Tailscale as a person")
    try:
        pid = body.profile_id
        if pid is None:
            if not body.name:
                raise HTTPException(422, "send profile_id or name")
            pid = lib(request).create_profile(body.name)["id"]
        return lib(request).claim_profile(pid, who["id"])
    except NotFound as e:
        _not_found(e)
    except PermissionError as e:
        raise HTTPException(409, str(e))
    except sqlite3.IntegrityError:
        raise HTTPException(409, "that name is taken")


@router.post("/profiles", status_code=201)
async def create_profile(body: NameIn, request: Request):
    return lib(request).create_profile(body.name)


# --- likes ------------------------------------------------------------------


def _refresh_pins(request: Request) -> None:
    request.app.state.cache.set_pinned(lib(request).liked_ids_all_profiles())


@router.get("/likes")
async def list_likes(request: Request, pid: int = Depends(profile)):
    return lib(request).likes(pid)


@router.put("/likes")
async def like(song: SongIn, request: Request, pid: int = Depends(profile)):
    """Like a song. Liked songs are downloaded and pinned in the server cache."""
    lib(request).like(pid, _store_song(request, song))
    _refresh_pins(request)
    if not request.app.state.cache.disk_low():
        request.app.state.downloader.ensure(song.id)  # make sure it's on disk
    return {"id": song.id, "liked": True}


@router.delete("/likes/{song_id}")
async def unlike(song_id: str = Path(pattern=VIDEO_ID_PATTERN), *, request: Request, pid: int = Depends(profile)):
    lib(request).unlike(pid, song_id)
    _refresh_pins(request)
    return {"id": song_id, "liked": False}


# --- playlists --------------------------------------------------------------


@router.get("/playlists")
async def list_playlists(request: Request, pid: int = Depends(profile)):
    return lib(request).playlists(pid)


@router.post("/playlists", status_code=201)
async def create_playlist(body: NameIn, request: Request, pid: int = Depends(profile)):
    return lib(request).create_playlist(pid, body.name)


@router.post("/playlists/import", status_code=201)
async def import_playlist(body: ImportIn, request: Request, pid: int = Depends(profile)):
    """Create a playlist with songs in one request (Save to Library)."""
    created = lib(request).create_playlist(pid, body.name)
    for song in body.songs:
        lib(request).add_to_playlist(pid, created["id"], _store_song(request, song))
    return lib(request).playlist(pid, created["id"])


@router.get("/playlists/{playlist_id}")
async def get_playlist(playlist_id: int, request: Request, pid: int = Depends(profile)):
    try:
        return lib(request).playlist(pid, playlist_id)
    except NotFound as e:
        _not_found(e)


@router.patch("/playlists/{playlist_id}")
async def rename_playlist(playlist_id: int, body: NameIn, request: Request, pid: int = Depends(profile)):
    try:
        return lib(request).rename_playlist(pid, playlist_id, body.name)
    except NotFound as e:
        _not_found(e)


@router.delete("/playlists/{playlist_id}", status_code=204)
async def delete_playlist(playlist_id: int, request: Request, pid: int = Depends(profile)):
    try:
        lib(request).delete_playlist(pid, playlist_id)
    except NotFound as e:
        _not_found(e)


@router.post("/playlists/{playlist_id}/songs")
async def add_song(playlist_id: int, song: SongIn, request: Request, pid: int = Depends(profile)):
    """Append a song to the end of a playlist."""
    try:
        return lib(request).add_to_playlist(pid, playlist_id, _store_song(request, song))
    except NotFound as e:
        _not_found(e)


@router.delete("/playlists/{playlist_id}/songs/{item_id}")
async def remove_song(playlist_id: int, item_id: int, request: Request, pid: int = Depends(profile)):
    try:
        return lib(request).remove_from_playlist(pid, playlist_id, item_id)
    except NotFound as e:
        _not_found(e)


@router.put("/playlists/{playlist_id}/order")
async def reorder(playlist_id: int, body: OrderIn, request: Request, pid: int = Depends(profile)):
    """Reorder: send every item_id in the new order."""
    try:
        return lib(request).reorder_playlist(pid, playlist_id, body.item_ids)
    except NotFound as e:
        _not_found(e)
    except ValueError as e:
        raise HTTPException(400, str(e))


# --- saved pages (followed artists) ------------------------------------------

SAVED_ID = r"^[A-Za-z0-9_-]{1,100}$"


class SavedIn(BaseModel):
    type: str = Field(pattern="^(artist|album|playlist)$")
    id: str = Field(pattern=SAVED_ID)
    title: str = Field(min_length=1, max_length=300)
    subtitle: str | None = Field(None, max_length=300)
    thumbnail: str | None = Field(None, max_length=2000)


@router.get("/saved")
async def list_saved(request: Request, pid: int = Depends(profile)):
    return lib(request).saved(pid)


@router.put("/saved")
async def save_item(item: SavedIn, request: Request, pid: int = Depends(profile)):
    lib(request).save_item(pid, item.model_dump())
    return {"id": item.id}


@router.delete("/saved/{type_}/{item_id}")
async def unsave_item(request: Request, type_: str = Path(pattern="^(artist|album|playlist)$"),
                      item_id: str = Path(pattern=SAVED_ID), pid: int = Depends(profile)):
    lib(request).unsave_item(pid, type_, item_id)
    return {"id": item_id}


# --- play history -----------------------------------------------------------


@router.post("/plays", status_code=201)
async def record_play(song: SongIn, request: Request, pid: int = Depends(profile)):
    """Clients call this once per listen (e.g. after 30 s of playback)."""
    lib(request).record_play(pid, _store_song(request, song))
    return {"id": song.id}


@router.get("/history")
async def history(request: Request, limit: int = 50, pid: int = Depends(profile)):
    return lib(request).history(pid, min(max(limit, 1), 500))


@router.get("/pins")
async def list_pins(request: Request, pid: int = Depends(profile)):
    """Songs pinned to the front of the speed dial."""
    return lib(request).pins(pid)


@router.put("/pins")
async def pin(song: SongIn, request: Request, pid: int = Depends(profile)):
    lib(request).pin(pid, _store_song(request, song))
    return {"id": song.id}


@router.delete("/pins/{song_id}")
async def unpin(song_id: str = Path(pattern=VIDEO_ID_PATTERN), *, request: Request, pid: int = Depends(profile)):
    lib(request).unpin(pid, song_id)
    return {"id": song_id}


@router.get("/speed-dial")
async def speed_dial(request: Request, limit: int = 9, pid: int = Depends(profile)):
    """Home screen grid: your most played and liked songs."""
    return lib(request).speed_dial(pid, min(max(limit, 1), 27))
