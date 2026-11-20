"""Warm JavaScript worker for yt-dlp's YouTube challenge solver (experimental).

Normally yt-dlp starts a fresh Deno process for every song: Deno boots, loads
the solver, runs YouTube's ~4 MB player script to find the "n"/"sig" functions,
solves, and exits. On a Pi Zero 2 W that's ~16 s per song, nearly all of it
start-up work that is identical every time.

This keeps ONE Deno process alive. It runs the player script once per player
version and keeps the extracted solver functions in memory, so later songs
only pay for the actual solve.

How it hooks in (no yt-dlp files are modified):
  - `install()` wraps DenoJCP._real_bulk_solve. Any problem with the worker
    falls back to yt-dlp's normal one-process-per-song path.
  - Inside Deno, the solver calls `Function('_result', code)(obj)` to run the
    player. We wrap `Function` so that call is answered from a cache.

Cost: the worker holds memory while alive, so it exits after
PITUNES_JS_WORKER_IDLE_S seconds without use.
"""

import json
import logging
import os
import subprocess
import tempfile
import threading
import time

log = logging.getLogger("pitunes.jsworker")

# 0 = never stop. The worker settles at ~80 MB, and restarting it costs ~15 s
# on the next song, so by default it stays up.
IDLE_S = float(os.environ.get("PITUNES_JS_WORKER_IDLE_S", "0"))
REPLY_TIMEOUT_S = 120
MARK = "\x01PITUNES "  # prefixes our reply lines, in case player code prints something

# Appended after yt-dlp's own lib + core scripts (which define `jsc`).
WORKER_JS = r"""
const __pt = { solvers: new Map(), key: null };
const __RealFunction = Function;
// The solver runs the player with Function('_result', code)(resultObj).
// Do that once per player version and reuse what it found.
globalThis.Function = function (...args) {
  if (args.length === 2 && args[0] === '_result') {
    return (resultObj) => {
      let found = __pt.solvers.get(__pt.key);
      if (!found) {
        __RealFunction('_result', args[1])(resultObj);
        found = { ...resultObj };
        __pt.solvers.set(__pt.key, found);
        // YouTube serves a few player variants at once; keep the 3 most recent.
        while (__pt.solvers.size > 3) __pt.solvers.delete(__pt.solvers.keys().next().value);
      } else {
        Object.assign(resultObj, found);
      }
    };
  }
  return __RealFunction(...args);
};
globalThis.Function.prototype = __RealFunction.prototype;

function __handle(msg) {
  __pt.key = msg.key;
  if (__pt.solvers.has(msg.key)) {
    return jsc({ type: 'preprocessed', preprocessed_player: '', requests: msg.requests });
  }
  if (msg.player == null) return { type: 'need_player' };
  return jsc({ type: 'player', player: msg.player, requests: msg.requests });
}

const __dec = new TextDecoder();
let __buf = '';
console.log('\x01PITUNES ' + JSON.stringify({ type: 'ready' }));
for await (const chunk of Deno.stdin.readable) {
  __buf += __dec.decode(chunk, { stream: true });
  let i;
  while ((i = __buf.indexOf('\n')) >= 0) {
    const line = __buf.slice(0, i);
    __buf = __buf.slice(i + 1);
    let out;
    try { out = __handle(JSON.parse(line)); }
    catch (e) { out = { type: 'error', error: String(e && e.stack || e) }; }
    console.log('\x01PITUNES ' + JSON.stringify(out));
  }
}
"""


class Worker:
    """Owns the long-lived Deno process. One request at a time."""

    def __init__(self):
        self._lock = threading.Lock()
        self._proc: subprocess.Popen | None = None
        self._script: str | None = None
        self._idle_timer: threading.Timer | None = None
        self.starts = 0

    # -- process management --------------------------------------------------

    def _start(self, provider) -> None:
        opts = [*provider._DENO_BASE_OPTIONS]
        variant = provider._lib_script.variant
        from yt_dlp.extractor.youtube.jsc._builtin.ejs import ScriptVariant
        if variant == ScriptVariant.DENO_NPM:
            if provider._NPM_PACKAGES_CACHED:
                opts.append("--cached-only")
        else:
            opts += ["--no-npm", "--cached-only"]
        code = (f"{provider._lib_script.code}\nObject.assign(globalThis, lib);\n"
                f"{provider._core_script.code}\n{WORKER_JS}")
        fd, self._script = tempfile.mkstemp(prefix="pitunes-jsworker-", suffix=".js")
        with os.fdopen(fd, "w") as f:
            f.write(code)
        started = time.monotonic()
        self._proc = subprocess.Popen(
            [provider.runtime_info.path, "run", *opts, self._script],
            text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=provider._get_env_options(),
        )
        if self._read().get("type") != "ready":
            raise RuntimeError("worker did not start")
        self.starts += 1
        log.info("JS worker started in %.1fs (pid %d)", time.monotonic() - started, self._proc.pid)

    def stop(self) -> None:
        with self._lock:
            self._stop_locked()

    def _stop_locked(self) -> None:
        if self._idle_timer:
            self._idle_timer.cancel()
            self._idle_timer = None
        if self._proc:
            self._proc.kill()
            self._proc.wait()
            self._proc = None
        if self._script:
            try:
                os.unlink(self._script)
            except OSError:
                pass
            self._script = None

    def _idle_stop(self) -> None:
        log.info("JS worker idle for %.0fs: stopping it to free memory", IDLE_S)
        self.stop()

    # -- protocol ------------------------------------------------------------

    def _read(self) -> dict:
        """Next reply line from the worker (with a watchdog, so a hung worker
        can't block playback forever)."""
        proc = self._proc
        watchdog = threading.Timer(REPLY_TIMEOUT_S, proc.kill)
        watchdog.start()
        try:
            while True:
                line = proc.stdout.readline()
                if not line:
                    raise RuntimeError("worker exited")
                if line.startswith(MARK):
                    return json.loads(line[len(MARK):])
        finally:
            watchdog.cancel()

    def _send(self, msg: dict) -> dict:
        self._proc.stdin.write(json.dumps(msg) + "\n")
        self._proc.stdin.flush()
        return self._read()

    def solve(self, provider, key: str, requests: list[dict], get_player) -> dict:
        """Returns the same dict yt-dlp's `jsc()` prints. Raises on worker trouble."""
        with self._lock:
            if self._idle_timer:
                self._idle_timer.cancel()
            try:
                if self._proc is None or self._proc.poll() is not None:
                    self._stop_locked()
                    self._start(provider)
                out = self._send({"key": key, "requests": requests})
                if out.get("type") == "need_player":
                    out = self._send({"key": key, "requests": requests, "player": get_player()})
            except Exception:
                self._stop_locked()
                raise
            if IDLE_S > 0:
                self._idle_timer = threading.Timer(IDLE_S, self._idle_stop)
                self._idle_timer.daemon = True
                self._idle_timer.start()
            return out

    def rss_mb(self) -> float | None:
        """Worker memory right now (Linux only)."""
        try:
            with open(f"/proc/{self._proc.pid}/statm") as f:
                return round(int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE") / 1024 / 1024, 1)
        except (OSError, AttributeError, ValueError):
            return None


worker = Worker()
_installed = False


def install() -> None:
    """Route yt-dlp's Deno challenge solving through the warm worker."""
    global _installed
    if _installed:
        return
    from yt_dlp.extractor.youtube.jsc._builtin import ejs
    from yt_dlp.extractor.youtube.jsc._builtin.deno import DenoJCP

    original = DenoJCP._real_bulk_solve

    def via_worker(self, requests):
        grouped: dict[str, list] = {}
        for request in requests:
            grouped.setdefault(request.input.player_url, []).append(request)
        results = []
        for player_url, group in grouped.items():
            json_requests = [{"type": r.type.value, "challenges": r.input.challenges} for r in group]
            video_id = next((r.video_id for r in group), None)
            started = time.monotonic()
            out = worker.solve(self, player_url, json_requests,
                               lambda: self._get_player(video_id, player_url))
            if out.get("type") == "error":
                raise RuntimeError(out.get("error"))
            log.info("JS challenges solved by warm worker in %.2fs", time.monotonic() - started)
            for request, data in zip(group, out["responses"], strict=True):
                if data["type"] == "error":
                    results.append(ejs.JsChallengeProviderResponse(request, None, data["error"]))
                else:
                    output = (ejs.NChallengeOutput(data["data"]) if request.type is ejs.JsChallengeType.N
                              else ejs.SigChallengeOutput(data["data"]))
                    results.append(ejs.JsChallengeProviderResponse(
                        request, ejs.JsChallengeResponse(request.type, output)))
        return results

    def patched(self, requests):
        requests = list(requests)
        try:
            results = via_worker(self, requests)
        except Exception as e:  # noqa: BLE001 - any worker problem: use the normal path
            log.warning("JS worker failed (%s); falling back to a one-off Deno run", str(e)[:200])
            results = None
        if results is None:
            yield from original(self, requests)
        else:
            yield from results

    DenoJCP._real_bulk_solve = patched
    _installed = True
    log.info("warm JS worker enabled")
