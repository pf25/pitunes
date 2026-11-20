#!/usr/bin/env bash
# Weekly (pitunes-update.timer): update yt-dlp + its JS solver and Deno, since
# YouTube changes often. Runs as the normal user.
#
# Safety: after updating, it resolves one known song. If that fails, the
# previous yt-dlp versions are restored, so a bad release can't break playback.
set -euo pipefail
export PATH="$HOME/.deno/bin:$HOME/.local/bin:$PATH"
cd "$HOME/pitunes/server"

versions() { .venv/bin/python -c 'import yt_dlp.version as v; print("yt-dlp", v.__version__)'; deno --version | head -1; }
# A resolve exercises the whole chain: YouTube API, JS challenge (Deno), formats.
smoke_test() {
  .venv/bin/python - <<'PY'
import sys, yt_dlp
try:
    with yt_dlp.YoutubeDL({"quiet": True, "format": "140/bestaudio[ext=m4a]", "skip_download": True}) as y:
        info = y.extract_info("https://www.youtube.com/watch?v=dQw4w9WgXcQ", download=False)
    sys.exit(0 if info.get("url") else 1)
except Exception as e:
    print("smoke test failed:", e); sys.exit(1)
PY
}

before="$(versions)"
cp uv.lock uv.lock.before-update
uv sync --quiet --no-dev --upgrade-package yt-dlp --upgrade-package yt-dlp-ejs
deno upgrade --quiet || echo "deno upgrade failed (keeping current version)"
after="$(versions)"

if [ "$before" = "$after" ]; then
  echo "already up to date: $(echo $after)"
elif smoke_test; then
  echo "updated: $(echo $before) -> $(echo $after); restarting pitunes"
  sudo -n /usr/bin/systemctl restart pitunes.service
else
  echo "new versions failed the smoke test; rolling back to: $(echo $before)"
  cp uv.lock.before-update uv.lock
  uv sync --quiet --no-dev --frozen
fi
rm -f uv.lock.before-update
uv cache prune --quiet || true
