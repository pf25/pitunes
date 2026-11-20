#!/usr/bin/env bash
# For developers: push your working copy of the server to the Pi and (re)start
# it. (To simply install or update PiTunes, run install.sh on the Pi instead.)
#
#   ./deploy/deploy.sh            # uses "music" (Tailscale), falls back to music.local (home Wi-Fi)
#   ./deploy/deploy.sh some-host  # any ssh destination
#
# Safe to run repeatedly. The song cache and database (server/data/) on the Pi
# are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${1:-}"
if [ -z "$HOST" ]; then
  # Defaults: a Pi called "music" and the same user name as on this computer.
  # Override with PITUNES_PI=user@host, or pass the destination as an argument.
  for h in ${PITUNES_PI:-$USER@music $USER@music.local}; do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$h" true 2>/dev/null; then HOST="$h"; break; fi
  done
  [ -n "$HOST" ] || { echo "Can't reach the Pi as 'music' or 'music.local'. Is Tailscale on?"; exit 1; }
fi
echo "==> Deploying to $HOST"

./deploy/backup.sh "$HOST" || echo "(backup skipped)"   # library snapshot before touching anything

rsync -a --delete --exclude .venv --exclude __pycache__ --exclude data server/ "$HOST:pitunes/server/"
rsync -a --delete deploy/ "$HOST:pitunes/deploy/"
# -t gives sudo a terminal, so it can ask for your Pi password the first time.
T=""; [ -t 0 ] && T="-t"
ssh $T "$HOST" 'bash pitunes/deploy/remote-install.sh'
