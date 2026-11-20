#!/usr/bin/env bash
# Save a copy of the library (likes, playlists, history) from the Pi to this Mac.
#   ./deploy/backup.sh                 # -> ~/pitunes-backups/pitunes-<date>.db
# deploy.sh runs this automatically; to restore, copy a backup to
# ~/pitunes/server/data/pitunes.db on the Pi while the service is stopped.
set -euo pipefail
DIR="${PITUNES_BACKUP_DIR:-$HOME/pitunes-backups}"
HOST="${1:-}"
if [ -z "$HOST" ]; then
  # Defaults: a Pi called "music" and the same user name as on this computer.
  # Override with PITUNES_PI=user@host, or pass the destination as an argument.
  for h in ${PITUNES_PI:-$USER@music $USER@music.local}; do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$h" true 2>/dev/null; then HOST="$h"; break; fi
  done
  [ -n "$HOST" ] || { echo "backup: can't reach the Pi"; exit 1; }
fi
mkdir -p "$DIR"
OUT="$DIR/pitunes-$(date +%Y%m%d-%H%M%S).db"
# Ask the server for a consistent snapshot (over ssh, so it works from home Wi-Fi too).
ssh "$HOST" 'curl -sf "http://$(tailscale ip -4 | head -1):8000/backup"' > "$OUT" || { rm -f "$OUT"; echo "backup: server has no /backup yet (first deploy of it?)"; exit 0; }
sqlite3 "$OUT" "PRAGMA integrity_check" | grep -qx ok || { echo "backup: $OUT failed its integrity check"; exit 1; }
ls -t "$DIR"/pitunes-*.db | tail -n +31 | xargs rm -f   # keep the newest 30
echo "backup: $OUT ($(sqlite3 "$OUT" 'select count(*) from likes') likes, $(sqlite3 "$OUT" 'select count(*) from playlists') playlists)"
