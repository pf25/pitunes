#!/usr/bin/env bash
# systemd ExecStart: wait for Tailscale, then serve on the Tailscale IP only
# (so the server is reachable from your tailnet and nowhere else).
set -euo pipefail
IP=""
for _ in $(seq 1 90); do
  IP="$(tailscale ip -4 2>/dev/null | head -1)" && [ -n "$IP" ] && break
  sleep 1
done
[ -n "$IP" ] || { echo "Tailscale has no IPv4 address. Is it logged in? (sudo tailscale up)"; exit 1; }
cd "$(dirname "$0")/../server"
# Run the venv's entry point directly: much faster startup than `uv run`.
exec .venv/bin/pitunes --host "$IP" --port "${PITUNES_PORT:-8000}"
