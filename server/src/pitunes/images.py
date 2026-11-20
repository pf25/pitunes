"""Thumbnail proxy: GET /img?u=<https url>.

The app loads artwork through the Pi instead of straight from Google, so
Google's image servers never see the phone. Images are kept on disk (small:
~30 KB each) with a size cap, so each one is fetched from Google only once.

Only https URLs on YouTube's image hosts are allowed; without that check this
endpoint would let any tailnet device make the Pi fetch arbitrary URLs (SSRF).
"""

import hashlib
import logging
import os
from pathlib import Path
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import Response

from . import config

log = logging.getLogger("pitunes.images")
router = APIRouter()

ALLOWED_HOST_SUFFIXES = (".ytimg.com", ".googleusercontent.com", ".ggpht.com")
MAX_IMAGE_BYTES = 2 * 1024 * 1024
CACHE_MAX_BYTES = 200 * 1024 * 1024
_writes_since_prune = 0


def allowed(url: str) -> bool:
    u = urlparse(url)
    host = (u.hostname or "").lower()
    return u.scheme == "https" and u.port in (None, 443) and not u.username \
        and any(host.endswith(s) for s in ALLOWED_HOST_SUFFIXES)


def _dir() -> Path:
    d = config.DATA_DIR / "img"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _prune(d: Path) -> None:
    """Delete the oldest images once the folder is over its cap."""
    files = sorted(((p.stat().st_mtime, p.stat().st_size, p) for p in d.iterdir()), key=lambda t: t[0])
    total = sum(f[1] for f in files)
    for _, size, p in files:
        if total <= CACHE_MAX_BYTES:
            break
        p.unlink(missing_ok=True)
        total -= size


@router.get("/img")
async def image(request: Request, u: str = Query(..., max_length=2000)):
    global _writes_since_prune
    if not allowed(u):
        raise HTTPException(400, "image host not allowed")
    path = _dir() / hashlib.sha1(u.encode()).hexdigest()
    headers = {"Cache-Control": "public, max-age=604800"}
    if path.exists():
        return Response(path.read_bytes(), media_type="image/jpeg", headers=headers)

    client: httpx.AsyncClient = request.app.state.upstream.client
    try:
        # follow_redirects=False: a redirect could point outside the allowed hosts.
        r = await client.get(u, follow_redirects=False)
    except httpx.HTTPError as e:
        raise HTTPException(502, f"image fetch failed: {e}")
    ctype = r.headers.get("content-type", "")
    if r.status_code != 200 or not ctype.startswith("image/") or len(r.content) > MAX_IMAGE_BYTES:
        raise HTTPException(502, "image fetch failed")
    tmp = path.with_suffix(".tmp")
    tmp.write_bytes(r.content)
    os.replace(tmp, path)
    _writes_since_prune += 1
    if _writes_since_prune >= 200:
        _writes_since_prune = 0
        _prune(path.parent)
    return Response(r.content, media_type=ctype, headers=headers)
