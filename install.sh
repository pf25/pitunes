#!/usr/bin/env bash
# PiTunes server: one-command install (and update) for a Raspberry Pi.
#
# Run this ON THE PI, as your normal user (not root):
#
#   curl -fsSL https://raw.githubusercontent.com/pf25/pitunes/main/install.sh | bash
#
# Before running it: flash Raspberry Pi OS Lite (64-bit), install Tailscale and
# run `sudo tailscale up`. Running it again later updates PiTunes to the newest
# version. Your library and song cache (~/pitunes/server/data) are never touched.
set -euo pipefail

REPO="${PITUNES_REPO:-https://github.com/pf25/pitunes.git}"
ROOT="$HOME/pitunes"
die() { echo; echo "!! $*"; exit 1; }

[ "$(id -u)" != 0 ] || die "Run this as your normal user, not with sudo. It asks for your password when it needs to."
case "$(uname -m)" in
  aarch64|arm64|x86_64) ;;
  *) die "This is a 32-bit system ($(uname -m)). Re-flash the SD card with Raspberry Pi OS Lite (64-bit)." ;;
esac
command -v tailscale >/dev/null || die "Tailscale isn't installed yet. Run these two commands, then run this installer again:
     curl -fsSL https://tailscale.com/install.sh | sh
     sudo tailscale up"
tailscale ip -4 >/dev/null 2>&1 || die "Tailscale is installed but not signed in. Run:  sudo tailscale up"

echo "==> Installing system packages (git, curl, unzip, ffmpeg). This can take several minutes."
sudo apt-get update -q >/dev/null
sudo apt-get install -y -q git curl unzip ffmpeg >/dev/null

if [ -d "$ROOT/.git" ]; then
  echo "==> Updating PiTunes in $ROOT"
  # The daily updater rewrites uv.lock when it installs a newer yt-dlp. Put the
  # original back first, or git refuses to pull. (The newest yt-dlp is
  # installed again a few steps further on.)
  git -C "$ROOT" checkout --quiet -- server/uv.lock
  git -C "$ROOT" pull --ff-only --quiet
elif [ -e "$ROOT" ]; then
  die "$ROOT already exists but wasn't installed by this script. Move it away (keep $ROOT/server/data if you want your library) and run this again."
else
  echo "==> Downloading PiTunes to $ROOT"
  git clone --quiet --depth 1 "$REPO" "$ROOT"
fi

exec bash "$ROOT/deploy/remote-install.sh"
