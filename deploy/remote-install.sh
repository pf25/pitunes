#!/usr/bin/env bash
# Runs ON THE PI (install.sh runs it; so does deploy.sh over ssh). Installs deps, systemd units,
# and SD-card-friendly logging, then restarts the server. Idempotent.
set -euo pipefail
ROOT="$HOME/pitunes"
export PATH="$HOME/.deno/bin:$HOME/.local/bin:$PATH"

# uv runs the Python server; Deno runs the small JavaScript puzzles YouTube
# sets before it hands out a song. Both install into your home folder.
if ! command -v uv >/dev/null; then
  echo "==> Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
fi
if ! command -v deno >/dev/null; then
  echo "==> Installing Deno"
  command -v unzip >/dev/null || sudo apt-get install -y -q unzip >/dev/null
  curl -fsSL https://deno.land/install.sh | sh -s -- -y --no-modify-path >/dev/null 2>&1
fi
command -v uv >/dev/null || { echo "!! uv didn't install; see https://docs.astral.sh/uv/"; exit 1; }
command -v deno >/dev/null || { echo "!! Deno didn't install; see https://deno.com/"; exit 1; }

echo "==> Installing Python deps (and newest yt-dlp)"
cd "$ROOT/server"
uv sync --quiet --no-dev --upgrade-package yt-dlp --upgrade-package yt-dlp-ejs
command -v ffmpeg >/dev/null || { echo "==> Installing ffmpeg"; sudo apt-get install -y -q ffmpeg >/dev/null; }
echo "    yt-dlp $(.venv/bin/python -c 'import yt_dlp.version as v; print(v.__version__)')"

# System files change rarely. Only touch them (with sudo, which may ask for
# your password) when they differ from what's installed. Routine deploys then
# need just one passwordless command: restarting the service.
CHANGED=0
put() {  # put <dest> <mode>  (content on stdin)
  local tmp; tmp="$(mktemp)"; cat > "$tmp"
  if ! cmp -s "$tmp" "$1" 2>/dev/null; then
    if [ "$2" = 440 ]; then
      # sudoers file: visudo only accepts root-owned 0440 files, so install a
      # copy first (a name with a dot is ignored by sudo), check it, then move it.
      sudo install -m 440 -o root -g root "$tmp" "$1.check"
      if ! sudo visudo -cqf "$1.check"; then
        sudo rm -f "$1.check"; echo "!! sudo rule failed validation; not installed"; exit 1
      fi
      sudo mv "$1.check" "$1"
    else
      sudo install -D -m "$2" "$tmp" "$1"
    fi
    echo "    updated $1"; CHANGED=1
  fi
  rm -f "$tmp"
}

echo "==> Checking systemd units, logging config, sudo rule"
for f in "$ROOT"/deploy/systemd/*; do
  # `put ... < <(...)`, not `... | put`: a pipe would run put in a subshell and lose CHANGED.
  put "/etc/systemd/system/$(basename "$f")" 644 < <(sed -e "s|@USER@|$USER|g" -e "s|@HOME@|$HOME|g" "$f")
done
# Logs in RAM only: no SD card writes from logging (logs reset on reboot).
put /etc/systemd/journald.conf.d/pitunes.conf 644 < <(printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=20M\n')
# Let deploys restart pitunes without a password (and nothing else).
# (Check the file itself: `sudo -l` would wrongly succeed while sudo still
# remembers a password you just typed.)
if [ ! -e /etc/sudoers.d/pitunes ]; then
  put /etc/sudoers.d/pitunes 440 < <(printf '# pitunes deploys: restart the service without a password\n%s ALL=(root) NOPASSWD: /usr/bin/systemctl restart pitunes.service\n' "$USER")
fi
chmod +x "$ROOT"/deploy/*.sh

# SSH: keys only. Only done once a key is installed, so you can't lock yourself out.
if [ -s "$HOME/.ssh/authorized_keys" ]; then
  put /etc/ssh/sshd_config.d/pitunes.conf 644 < <(printf '# pitunes: key-based login only\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n')
fi

# Automatic OS security updates.
if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
  echo "==> Installing unattended-upgrades (automatic security updates)"
  sudo apt-get install -y -q unattended-upgrades >/dev/null
  CHANGED=1
fi
put /etc/apt/apt.conf.d/20auto-upgrades 644 < <(printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n')

if [ "$CHANGED" = 1 ] || ! systemctl is-enabled -q pitunes.service || ! systemctl is-enabled -q pitunes-update.timer; then
  sudo systemctl daemon-reload
  sudo systemctl enable --quiet pitunes.service pitunes-update.timer
  sudo systemctl start pitunes-update.timer
  sudo systemctl restart systemd-journald
  if sudo sshd -t 2>/dev/null; then sudo systemctl reload ssh 2>/dev/null || true; else echo "!! sshd config invalid; not reloaded"; fi
fi

echo "==> (Re)starting pitunes"
pkill -u "$USER" -f '[p]itunes/server/.venv/bin/pitunes' || true   # a manually started copy, if any
sudo /usr/bin/systemctl restart pitunes.service

# HTTPS for the web app (it needs a secure address to work offline). Only when
# you've switched on "HTTPS Certificates" in Tailscale's admin page; Tailscale
# then serves https://<name>.<tailnet>.ts.net and passes requests to pitunes.
HTTPS_NAME="$(tailscale status --json 2>/dev/null | python3 -c 'import sys, json; print((json.load(sys.stdin).get("CertDomains") or [""])[0])' 2>/dev/null || true)"
if [ -n "$HTTPS_NAME" ] && ! tailscale serve status 2>/dev/null | grep -q "127.0.0.1:8000"; then
  echo "==> Turning on https://$HTTPS_NAME"
  # Let this user manage `tailscale serve` without sudo from now on.
  tailscale serve --bg 8000 >/dev/null 2>&1 \
    || { sudo tailscale set --operator="$USER" && tailscale serve --bg 8000 >/dev/null; } \
    || echo "!! Couldn't turn on HTTPS. Run this once on the Pi, then install again:  sudo tailscale set --operator=$USER"
fi

IP="$(tailscale ip -4 | head -1)"
for _ in $(seq 1 90); do
  if curl -sf "http://$IP:8000/health" >/dev/null; then
    echo "==> PiTunes is running."
    echo
    echo "    In the PiTunes app, enter this server address:   $(hostname)"
    echo "    (If the name doesn't work, use the address:      $IP)"
    if [ -n "$HTTPS_NAME" ]; then WEB="https://$HTTPS_NAME"; else WEB="http://$(hostname):8000"; fi
    echo "    In a browser, on any device on your tailnet:     $WEB"
    echo
    echo "    health: $(curl -s "http://$IP:8000/health" | cut -c1-100)"
    exit 0
  fi
  sleep 1
done
echo "!! pitunes didn't answer within 90 s. Logs:"; journalctl -u pitunes -n 30 --no-pager; exit 1
