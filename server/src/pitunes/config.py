"""Settings, read from environment variables so the same code runs on Mac and Pi."""

import os
import socket
from pathlib import Path

# Where the HTTP server listens. Default is localhost (safe for Mac dev).
# On the Pi, bind to the Tailscale IP so the server is only reachable via
# your tailnet (see README).
HOST = os.environ.get("PITUNES_HOST", "127.0.0.1")
PORT = int(os.environ.get("PITUNES_PORT", "8000"))

# How many search results to return by default.
SEARCH_LIMIT = int(os.environ.get("PITUNES_SEARCH_LIMIT", "10"))

# Max number of yt-dlp resolves running at once. Each resolve can spawn a
# Deno process (~100+ MB), so on a 512 MB Zero keep this at 1.
MAX_CONCURRENT_RESOLVES = int(os.environ.get("PITUNES_MAX_RESOLVES", "1"))

# The proxy fetches audio from YouTube in chunks of this size. YouTube throttles
# very large single requests; yt-dlp itself uses ~10 MB chunks.
UPSTREAM_CHUNK_BYTES = int(os.environ.get("PITUNES_CHUNK_BYTES", str(10 * 1024 * 1024)))

# Where the song cache (and, from Phase 3, the database) lives.
# Default: server/data/ next to the code (gitignored).
DATA_DIR = Path(os.environ.get("PITUNES_DATA_DIR", Path(__file__).resolve().parents[2] / "data"))

# Song cache size cap. ~4 MB per song, so 4 GB is roughly 1,000 songs.
CACHE_MAX_BYTES = int(float(os.environ.get("PITUNES_CACHE_MAX_GB", "4")) * 1024**3)

# Stop caching (and stream straight from YouTube) when the disk has less free
# space than this. Protects the SD card: liked songs are exempt from the cap.
MIN_FREE_BYTES = int(float(os.environ.get("PITUNES_MIN_FREE_GB", "2")) * 1024**3)

# Hostnames the server answers to (besides IP addresses and localhost).
# Requests with any other Host header are refused, which blocks DNS-rebinding
# attacks from web pages.
# This machine's own name always works (so does <name>.local and any
# Tailscale name ending in .ts.net); PITUNES_ALLOWED_HOSTS adds more.
_OWN_NAME = socket.gethostname().split(".")[0].lower()
ALLOWED_HOSTS = sorted({_OWN_NAME, f"{_OWN_NAME}.local", ".ts.net",
                        *(h.strip().lower() for h in
                          os.environ.get("PITUNES_ALLOWED_HOSTS", "music,music.local").split(",") if h.strip())})

# If the server and the Deno processes it starts together use more memory than
# this, the server restarts itself (systemd starts it again within seconds).
# Normal use is about 220 MB. Without this limit a runaway fills a Pi Zero's
# 512 MB and the whole Pi stops responding. 0 = no limit.
MEMORY_LIMIT_MB = int(os.environ.get("PITUNES_MEMORY_LIMIT_MB", "350"))

# Keep one Deno process warm for YouTube's JS challenges (see jsworker.py).
# Cuts a resolve on the Pi Zero 2 W from ~22 s to ~4 s for ~80 MB of RAM.
JS_WORKER = os.environ.get("PITUNES_JS_WORKER", "1") == "1"
# A song resolved at startup (and after yt-dlp/player updates) to warm the worker.
WARMUP_VIDEO_ID = os.environ.get("PITUNES_WARMUP_VIDEO", "dQw4w9WgXcQ")
