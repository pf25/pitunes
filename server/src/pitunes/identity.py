"""Who is calling? Asks Tailscale which person owns the phone at an address.

Every device on the tailnet is signed in as someone. `tailscale whois <ip>`
tells us who, so each person gets their own profile automatically, with no
passwords or profile pickers in the app.

Returns None when the caller isn't a Tailscale device with a user (the Mac
during development, tests, a tagged server), and the app's X-Profile-Id header
is used instead.
"""

import asyncio
import ipaddress
import json
import logging
import subprocess
import time

log = logging.getLogger("pitunes.identity")

TAILSCALE_NETS = (ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("fd7a:115c:a1e0::/48"))
CACHE_S = 3600
_cache: dict[str, tuple[float, dict | None]] = {}


def _whois_sync(ip: str) -> dict | None:
    try:
        out = subprocess.run(["tailscale", "whois", "--json", ip], capture_output=True, text=True, timeout=5)
        user = json.loads(out.stdout).get("UserProfile") or {}
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        log.warning("tailscale whois %s failed: %s", ip, e)
        return None
    # Tagged devices (servers) have no real person behind them.
    if not user.get("ID") or user.get("LoginName") == "tagged-devices":
        return None
    return {"id": str(user["ID"]), "name": user.get("DisplayName") or user.get("LoginName") or "Someone"}


async def whois(ip: str | None) -> dict | None:
    """{"id", "name"} of the Tailscale user at `ip`, or None."""
    try:
        addr = ipaddress.ip_address(ip or "")
    except ValueError:
        return None
    if not any(addr in net for net in TAILSCALE_NETS):
        return None
    hit = _cache.get(ip)
    # A "don't know" answer is only trusted briefly: a phone that has just
    # joined the tailnet may not be recognised on the very first try.
    if hit and time.monotonic() - hit[0] < (CACHE_S if hit[1] else 60):
        return hit[1]
    who = await asyncio.to_thread(_whois_sync, ip)
    _cache[ip] = (time.monotonic(), who)
    return who


_https: tuple[float, str | None] | None = None


def _https_sync() -> str | None:
    try:
        out = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5)
        names = json.loads(out.stdout).get("CertDomains") or []
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return f"https://{names[0]}" if names else None


async def https_address() -> str | None:
    """This server's secure address (https://<name>.<tailnet>.ts.net), if
    HTTPS is switched on in Tailscale. The web app needs it for offline use."""
    global _https
    if _https is None or time.monotonic() - _https[0] > 600:
        _https = (time.monotonic(), await asyncio.to_thread(_https_sync))
    return _https[1]
