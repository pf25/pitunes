// PiTunes web app: the same player as the iPhone app, for any browser.
//
// Each screen here mirrors a screen in ios/PiTunes/Views; when you change one,
// change the other. No framework and no build step: this one file draws every
// screen into <main id="view">. The parts, in order:
//   1. Helpers      (making elements, icons, talking to the server)
//   2. Player       (the queue, the <audio> element, lock-screen controls)
//   3. Library      (likes, playlists, pins, profile)
//   4. Player UI    (mini bar, full player, player bar, queue panel, menus)
//   5. Building blocks for screens (nav bar, rows, cards, shelves)
//   6. Screens      (Home, Explore, Podcasts, Search, Library, Settings, detail pages)
//   7. Router       (which screen the address bar's #/... shows)
"use strict";

// ---------------------------------------------------------------- 1. Helpers

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => [...document.querySelectorAll(sel)];
const isDesktop = () => matchMedia("(min-width: 900px)").matches;

/** Make an element: h("div", {class: "row", onclick: fn}, child, "text", ...).
 *  Text is always added as text (never as HTML), so song titles can't inject markup. */
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value == null || value === false) continue;
    if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
    else if (key === "class") el.className = value;
    else el.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    el.append(child instanceof Node ? child : String(child));
  }
  return el;
}

// Icons, drawn as inline SVG so there are no image files to load.
const ICONS = {
  // tabs
  home: "M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z",
  explore: "M12 10.9c-.61 0-1.1.49-1.1 1.1s.49 1.1 1.1 1.1c.61 0 1.1-.49 1.1-1.1s-.49-1.1-1.1-1.1zM12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm2.19 12.19L6 18l3.81-8.19L18 6l-3.81 8.19z",
  mic: "M12 14c1.66 0 2.99-1.34 2.99-3L15 5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.3-3c0 3-2.54 5.1-5.3 5.1S6.7 14 6.7 11H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c3.28-.48 6-3.3 6-6.72h-1.7z",
  search: "M15.5 14h-.79l-.28-.27A6.471 6.471 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z",
  musicList: "M15 6H3v2h12V6zm0 4H3v2h12v-2zM3 16h8v-2H3v2zM17 6v8.18c-.31-.11-.65-.18-1-.18-1.66 0-3 1.34-3 3s1.34 3 3 3 3-1.34 3-3V8h3V6h-5z",
  // playback
  play: "M8 5v14l11-7z",
  pause: "M6 5h4v14H6zM14 5h4v14h-4z",
  next: "M6 6l8.5 6L6 18zM16 6h2v12h-2z",
  prev: "M18 6l-8.5 6L18 18zM6 6h2v12H6z",
  back30: "M12 5V1L7 6l5 5V7c3.31 0 6 2.69 6 6s-2.69 6-6 6-6-2.69-6-6H4c0 4.42 3.58 8 8 8s8-3.58 8-8-3.58-8-8-8z",
  forward30: "M12 5V1l5 5-5 5V7c-3.31 0-6 2.69-6 6s2.69 6 6 6 6-2.69 6-6h2c0 4.42-3.58 8-8 8s-8-3.58-8-8 3.58-8 8-8z",
  shuffle: "M10.59 9.17L5.41 4 4 5.41l5.17 5.17 1.42-1.41zM14.5 4l2.04 2.04L4 18.59 5.41 20 17.96 7.46 20 9.5V4h-5.5zm.33 9.41l-1.41 1.41 3.13 3.13L14.5 20H20v-5.5l-2.04 2.04-3.13-3.13z",
  repeat: "M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z",
  repeatOne: "M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4zm-4-2V9h-1l-2 1v1h1.5v4H13z",
  queue: "M3 10h11v2H3zm0-4h11v2H3zm0 8h7v2H3zm13-1v8l6-4z",
  volume: "M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z",
  volumeLow: "M5 9v6h4l5 5V4L9 9H5zm13.5 3A4.5 4.5 0 0 0 16 7.97v8.05c1.48-.73 2.5-2.25 2.5-4.02z",
  muted: "M16.5 12A4.5 4.5 0 0 0 14 7.97v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51A8.8 8.8 0 0 0 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06a8.99 8.99 0 0 0 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z",
  // arrows and marks
  down: "M7.4 8.6L12 13.2l4.6-4.6L18 10l-6 6-6-6z",
  up: "M7.41 15.41L12 10.83l4.59 4.58L18 14l-6-6-6 6z",
  back: "M15.4 7.4L10.8 12l4.6 4.6L14 18l-6-6 6-6z",
  forward: "M8.6 7.4L13.2 12l-4.6 4.6L10 18l6-6-6-6z",
  more: "M6 10a2 2 0 1 0 0 4 2 2 0 0 0 0-4zm6 0a2 2 0 1 0 0 4 2 2 0 0 0 0-4zm6 0a2 2 0 1 0 0 4 2 2 0 0 0 0-4z",
  plus: "M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z",
  check: "M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z",
  close: "M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z",
  plusCircle: "M13 7h-2v4H7v2h4v4h2v-4h4v-2h-4V7zm-1-5C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z",
  checkCircle: "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z",
  minusCircle: "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm5 11H7v-2h10v2z",
  // things
  heart: "M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z",
  heartOutline: "M16.5 3c-1.74 0-3.41.81-4.5 2.09C10.91 3.81 9.24 3 7.5 3 4.42 3 2 5.42 2 8.5c0 3.78 3.4 6.86 8.55 11.54L12 21.35l1.45-1.32C18.6 15.36 22 12.28 22 8.5 22 5.42 19.58 3 16.5 3zm-4.4 15.55l-.1.1-.1-.1C7.14 14.24 4 11.39 4 8.5 4 6.5 5.5 5 7.5 5c1.54 0 3.04.99 3.57 2.36h1.87C13.46 5.99 14.96 5 16.5 5c2 0 3.5 1.5 3.5 3.5 0 2.89-3.14 5.740-7.9 10.05z",
  history: "M13 3a9 9 0 0 0-9 9H1l3.89 3.89.07.14L9 12H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.94-2.06l-1.42 1.42A8.954 8.954 0 0 0 13 21a9 9 0 0 0 0-18zm-1 5v5l4.28 2.54.72-1.21-3.5-2.08V8H12z",
  gear: "M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.49.49 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.48.48 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96a.49.49 0 0 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6A3.6 3.6 0 1 1 12 8.4a3.6 3.6 0 0 1 0 7.2z",
  chart: "M16 6l2.29 2.29-4.88 4.88-4-4L2 16.59 3.41 18l6-6 4 4 6.3-6.29L22 12V6z",
  smile: "M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm3.5-9c.83 0 1.5-.67 1.5-1.5S16.33 8 15.5 8 14 8.67 14 9.5s.67 1.5 1.5 1.5zm-7 0c.83 0 1.5-.67 1.5-1.5S9.33 8 8.5 8 7 8.67 7 9.5 7.67 11 8.5 11zm3.5 6.5c2.33 0 4.31-1.46 5.11-3.5H6.89c.8 2.04 2.78 3.5 5.11 3.5z",
  radio: "M12 10a2 2 0 1 0 0 4 2 2 0 0 0 0-4zM7.05 7.05a7 7 0 0 0 0 9.9l1.41-1.41a5 5 0 0 1 0-7.08L7.05 7.05zm9.9 0l-1.41 1.41a5 5 0 0 1 0 7.08l1.41 1.41a7 7 0 0 0 0-9.9zM4.22 4.22a11 11 0 0 0 0 15.56l1.42-1.42a9 9 0 0 1 0-12.72L4.22 4.22zm15.56 0l-1.42 1.42a9 9 0 0 1 0 12.72l1.42 1.42a11 11 0 0 0 0-15.56z",
  infinity: "M18.6 6.62c-1.44 0-2.8.56-3.77 1.53L12 10.66 10.48 12h.01L7.8 14.39c-.64.64-1.49.99-2.4.99-1.87 0-3.39-1.51-3.39-3.38S3.53 8.62 5.4 8.62c.91 0 1.76.35 2.44 1.03l1.13 1 1.51-1.34L9.22 8.2A5.37 5.37 0 0 0 5.4 6.62C2.42 6.62 0 9.04 0 12s2.42 5.38 5.4 5.38c1.44 0 2.8-.56 3.77-1.53l2.83-2.5.01.01L13.52 12h-.01l2.69-2.39c.64-.64 1.49-.99 2.4-.99 1.87 0 3.39 1.51 3.39 3.38s-1.52 3.38-3.39 3.38c-.9 0-1.76-.35-2.44-1.03l-1.14-1.01-1.51 1.34 1.27 1.12a5.386 5.386 0 0 0 3.82 1.57c2.98 0 5.4-2.41 5.4-5.38s-2.42-5.37-5.4-5.37z",
  quote: "M6 17h3l2-4V7H5v6h3zm8 0h3l2-4V7h-6v6h3z",
  pin: "M16 9V4h1V2H7v2h1v5l-2 2v2h5.2v7h1.6v-7H18v-2z",
  share: "M16 5l-1.42 1.42-1.59-1.59V16h-1.98V4.83L9.42 6.42 8 5l4-4 4 4zm4 5v11c0 1.1-.9 2-2 2H6a2 2 0 0 1-2-2V10c0-1.11.89-2 2-2h3v2H6v11h12V10h-3V8h3a2 2 0 0 1 2 2z",
  trash: "M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z",
  download: "M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z",
  downloadDone: "M12 2C6.49 2 2 6.49 2 12s4.49 10 10 10 10-4.49 10-10S17.51 2 12 2zm-1 8V6h2v4h3l-4 4-4-4h3zm6 7H7v-2h10v2z",
  moon: "M12 3a9 9 0 1 0 9 9c0-.46-.04-.92-.1-1.36a5.389 5.389 0 0 1-4.4 2.26 5.403 5.403 0 0 1-3.14-9.8c-.44-.06-.9-.1-1.36-.1z",
  playNext: "M3 10h11v2H3zm0-4h11v2H3zm0 8h7v2H3zm13-1v8l6-4z",
  addQueue: "M14 10H3v2h11v-2zm0-4H3v2h11V6zm4 8v-4h-2v4h-4v2h4v4h2v-4h4v-2h-4zM3 16h7v-2H3v2z",
  globe: "M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zm6.93 6h-2.95a15.65 15.65 0 0 0-1.38-3.56A8.03 8.03 0 0 1 18.92 8zM12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96zM4.26 14C4.1 13.36 4 12.69 4 12s.1-1.36.26-2h3.38c-.08.66-.14 1.32-.14 2s.06 1.34.14 2H4.26zm.82 2h2.95c.32 1.25.78 2.45 1.38 3.56A7.987 7.987 0 0 1 5.08 16zm2.95-8H5.08a7.987 7.987 0 0 1 4.33-3.56A15.65 15.65 0 0 0 8.03 8zM12 19.96c-.83-1.2-1.48-2.53-1.91-3.96h3.82c-.43 1.43-1.08 2.76-1.91 3.96zM14.34 14H9.66c-.09-.66-.16-1.32-.16-2s.07-1.35.16-2h4.68c.09.65.16 1.32.16 2s-.07 1.34-.16 2zm.25 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95a8.03 8.03 0 0 1-4.33 3.56zM16.36 14c.08-.66.14-1.32.14-2s-.06-1.34-.14-2h3.38c.16.64.26 1.31.26 2s-.1 1.36-.26 2h-3.38z",
  info: "M11 7h2v2h-2zm0 4h2v6h-2zm1-9C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z",
};
function icon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", ICONS[name]);
  svg.append(path);
  return svg;
}
function setIcon(button, name) {
  if (button.dataset.icon === name) return;      // already showing it
  button.dataset.icon = name;
  button.replaceChildren(icon(name));
}
/** A button or link label with an icon in front, like SwiftUI's Label. */
const label = (iconName, text) => [icon(iconName), h("span", {}, text)];

/** "3:07", or "1:02:45" for long episodes */
function clock(seconds) {
  if (!isFinite(seconds) || seconds < 0) return "0:00";
  const s = Math.floor(seconds), m = Math.floor(s / 60) % 60, hrs = Math.floor(s / 3600);
  const tail = String(s % 60).padStart(2, "0");
  return hrs ? `${hrs}:${String(m).padStart(2, "0")}:${tail}` : `${m}:${tail}`;
}

/** Artwork goes through the server's image proxy (it only fetches YouTube's image hosts). */
function art(url) {
  if (!url) return "";
  try {
    const host = new URL(url).hostname;
    const proxied = [".ytimg.com", ".googleusercontent.com", ".ggpht.com"].some((s) => host.endsWith(s));
    return proxied ? `/img?u=${encodeURIComponent(url)}` : url;
  } catch { return ""; }
}

// Small things remembered in this browser only.
const store = {
  get(key, fallback) { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private mode */ } },
};

/** Call the server. Returns the parsed JSON (or null for empty replies). */
async function api(path, { method = "GET", body } = {}) {
  const response = await fetch(path, {
    method,
    headers: {
      // Which profile: the server ignores this once it knows you by your Tailscale account.
      "X-Profile-Id": String(store.get("profileID", 1)),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) throw new Error(`Server error ${response.status}`);
  return response.status === 204 ? null : response.json().catch(() => null);
}

function toast(text) {
  const el = $("#toast");
  el.textContent = text;
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { el.hidden = true; }, 2200);
}

/** Search results and shelves call the artist "subtitle"; the library calls it "artist". */
function asSong(item) {
  return { id: item.id, title: item.title, artist: item.artist || item.subtitle || "", duration: item.duration ?? null,
           thumbnail: item.thumbnail ?? null, video: item.video || undefined, itemId: item.item_id };
}
/** A podcast episode, shaped like a song so the player and queue treat it the same. */
function asEpisode(e, show = {}) {
  return { id: e.id, title: e.title, artist: e.show || show.title || "", duration: e.duration ?? null,
           thumbnail: e.artwork || show.artwork || null, audioUrl: e.audio_url, feed: e.feed || show.feed,
           position: e.position || 0, finished: !!e.finished, published: e.published, description: e.description, episode: true };
}
/** What the server wants when saving a song (like, playlist, pin, play count). */
function forServer(song) {
  return { id: song.id, title: song.title, artist: song.artist, duration: song.duration, thumbnail: song.thumbnail };
}
function shuffled(list) {
  const out = [...list];
  for (let i = out.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [out[i], out[j]] = [out[j], out[i]]; }
  return out;
}

// ----------------------------------------------------------------- 2. Player

const audio = new Audio();
audio.preload = "auto";

const player = {
  queue: [],          // songs (and episodes), in play order
  index: -1,          // which one is playing (-1 = nothing)
  autoplay: store.get("autoplay", true),    // keep going with similar songs when the queue ends
  repeat: store.get("repeat", "off"),       // "off" | "all" | "one"
  rate: store.get("episodeRate", 1),        // podcast speed; music always plays at 1x
  counted: null,      // queue entry we've already logged as a play
  failures: 0,        // songs in a row that wouldn't load
  radioLoading: false,
  savedAt: 0,         // when we last saved a podcast position

  get current() { return this.queue[this.index] || null; },
  get upNext() { return this.index < 0 ? [] : this.queue.slice(this.index + 1); },

  /** Replace the queue and start playing. */
  play(songs, startAt = 0) {
    if (!songs.length) return;
    this.saveProgress(true);
    this.queue = songs.map((s) => ({ ...s }));   // copies: the same song can be queued twice
    this.start(startAt);
  },
  /** One song now, then similar songs. */
  radio(song) {
    this.play([song]);
    this.loadRadio(true);
  },
  playNext(song) {
    if (this.index < 0) return this.play([song]);
    this.queue.splice(this.index + 1, 0, { ...song });
    this.changed();
  },
  addToQueue(song) {
    if (this.index < 0) return this.play([song]);
    this.queue.push({ ...song });
    this.changed();
  },
  start(i) {
    if (i < 0 || i >= this.queue.length) return;
    this.saveProgress(true);                     // leaving an episode: keep its place
    this.index = i;
    this.counted = null;
    const song = this.current;
    // Episodes play straight from the publisher; songs come through the Pi.
    audio.src = song.audioUrl || `/stream/${song.id}`;
    audio.play().catch(() => { /* the browser wants a tap first; the play button handles it */ });
    this.changed();
    // Running low: fetch similar songs now so there is no gap later.
    if (i === this.queue.length - 1 && this.autoplay && this.repeat === "off" && !song.episode) this.loadRadio();
  },
  toggle() {
    if (!this.current) return;
    if (audio.paused) audio.play().catch(() => {}); else audio.pause();
  },
  /** Stop and forget the queue, so the player goes away. */
  close() {
    this.saveProgress(true);
    audio.pause();
    audio.removeAttribute("src");
    this.queue = [];
    this.index = -1;
    this.changed();
  },
  async next() {
    if (this.index + 1 < this.queue.length) return this.start(this.index + 1);
    if (this.repeat === "all") return this.start(0);
    if (this.autoplay && !this.current?.episode) {
      await this.loadRadio();
      if (this.index + 1 < this.queue.length) this.start(this.index + 1);
    }
  },
  previous() {
    if (audio.currentTime > 3 || this.index <= 0) audio.currentTime = 0;
    else this.start(this.index - 1);
  },
  skip(seconds) { audio.currentTime = Math.max(0, Math.min(audio.currentTime + seconds, (audio.duration || 1e9) - 1)); },
  /** The song finished by itself. */
  ended() {
    this.saveProgress(true, true);
    if (this.repeat === "one") return this.start(this.index);
    this.next();
  },
  shuffleUpNext() {
    this.queue = [...this.queue.slice(0, this.index + 1), ...shuffled(this.upNext)];
    this.changed();
  },
  clearUpNext() {
    this.queue = this.queue.slice(0, this.index + 1);
    this.changed();
  },
  removeAt(i) {
    if (i <= this.index) return;
    this.queue.splice(i, 1);
    this.changed();
  },
  /** Add songs similar to the current one to the end of the queue. */
  async loadRadio(force = false) {
    const seed = this.current;
    if (!seed || seed.episode || this.radioLoading) return;
    if (!force && this.index !== this.queue.length - 1) return;
    this.radioLoading = true;
    try {
      const { results } = await api(`/radio/${seed.id}`);
      const have = new Set(this.queue.map((s) => s.id));
      this.queue.push(...results.filter((s) => !have.has(s.id)).map(asSong));
      this.changed();
    } catch { toast("Couldn't load similar songs"); }
    this.radioLoading = false;
  },
  /** Remember where we are in a podcast episode (every 15 s, on pause, at the end). */
  saveProgress(force = false, finished = false) {
    const ep = this.current;
    if (!ep?.episode || audio.currentTime < 5) return;
    if (!force && Date.now() - this.savedAt < 15000) return;
    this.savedAt = Date.now();
    const total = audio.duration || ep.duration || 0;
    ep.position = audio.currentTime;
    ep.finished = finished || (total > 60 && audio.currentTime >= total - 30);
    api("/podcasts/progress", { method: "PUT", body: {
      id: ep.id, feed: ep.feed, title: ep.title, show: ep.artist, audio_url: ep.audioUrl, artwork: ep.thumbnail,
      duration: ep.duration ? Math.round(ep.duration) : null, position: ep.position, finished: ep.finished } }).catch(() => {});
  },
  /** Something about the queue changed: redraw, and get the next songs ready. */
  changed() {
    // Ask the server to download the next two songs so they start at once.
    // This matters most with the screen locked, where a slow start can make
    // the phone put the page to sleep.
    for (const song of this.upNext.slice(0, 2)) {
      if (!song.episode) fetch(`/prefetch/${song.id}`, { method: "POST" }).catch(() => {});
    }
    updateMediaSession();
    drawPlayer();
    if (currentLyricsFor !== this.current?.id && !$("#panel-lyrics").hidden) showPanel("lyrics");
  },
};

audio.addEventListener("ended", () => player.ended());
audio.addEventListener("play", drawPlayer);
audio.addEventListener("pause", () => { player.saveProgress(true); drawPlayer(); });
audio.addEventListener("waiting", drawPlayer);
audio.addEventListener("playing", () => { player.failures = 0; drawPlayer(); });
audio.addEventListener("loadedmetadata", () => {
  const song = player.current;
  if (!song) return;
  audio.playbackRate = song.episode ? player.rate : 1;
  // Pick a half-heard episode up where you left it (unless it was nearly done).
  if (song.episode && !song.finished && song.position > 10 && song.position < (audio.duration || 1e9) - 30) {
    audio.currentTime = song.position;
  }
});
audio.addEventListener("timeupdate", () => {
  drawProgress();
  player.saveProgress();
  // Count a play after 30 seconds of listening, once per queue entry.
  const song = player.current;
  if (song && !song.episode && audio.currentTime >= 30 && player.counted !== song) {
    player.counted = song;
    api("/plays", { method: "POST", body: forServer(song) }).catch(() => {});
  }
});
audio.addEventListener("error", () => {
  // A song that won't load: say so and move on, but stop after three in a row
  // so a dead connection doesn't burn through the whole queue.
  const song = player.current;
  if (!song) return;
  toast(`Couldn't play ${song.title}`);
  player.failures += 1;
  if (player.failures < 3 && player.index + 1 < player.queue.length) player.start(player.index + 1);
});
window.addEventListener("pagehide", () => player.saveProgress(true));

/** Lock screen, AirPods, car and keyboard media keys. */
function updateMediaSession() {
  if (!("mediaSession" in navigator)) return;
  const song = player.current;
  if (!song) { navigator.mediaSession.metadata = null; return; }
  navigator.mediaSession.metadata = new MediaMetadata({
    title: song.title || "", artist: song.artist || "",
    artwork: song.thumbnail ? [{ src: new URL(art(song.thumbnail), location.href).href, sizes: "512x512" }] : [],
  });
  const on = (action, fn) => { try { navigator.mediaSession.setActionHandler(action, fn); } catch { /* not supported here */ } };
  on("play", () => audio.play());
  on("pause", () => audio.pause());
  on("seekto", (e) => { audio.currentTime = e.seekTime; });
  // Songs get next/previous; podcasts get 30-second skips instead.
  on("nexttrack", song.episode ? null : () => player.next());
  on("previoustrack", song.episode ? null : () => player.previous());
  on("seekforward", song.episode ? () => player.skip(30) : null);
  on("seekbackward", song.episode ? () => player.skip(-30) : null);
}

// ---------------------------------------------------------------- 3. Library

const library = { liked: new Set(), pinned: new Set(), playlists: [], saved: [], me: null };

async function refreshLibrary() {
  try {
    const [likes, playlists, pins, saved] = await Promise.all([
      api("/likes"), api("/playlists"), api("/pins").catch(() => []), api("/saved").catch(() => [])]);
    library.liked = new Set(likes.map((s) => s.id));
    library.playlists = playlists;
    library.pinned = new Set(pins.map((s) => s.id));
    library.saved = saved;
  } catch { /* offline: keep what we had */ }
  drawSidebar();
  markRows();
}

/** Flip something on the server (like, pin), updating the screen first and undoing on failure. */
async function flip(set, id, turnOn, turnOff) {
  const was = set.has(id);
  if (was) set.delete(id); else set.add(id);
  drawPlayer();
  try { await (was ? turnOff() : turnOn()); }
  catch { if (was) set.add(id); else set.delete(id); drawPlayer(); toast("Couldn't save that"); }
  drawSidebar();
}
const toggleLike = (song) => flip(library.liked, song.id,
  () => api("/likes", { method: "PUT", body: forServer(song) }), () => api(`/likes/${song.id}`, { method: "DELETE" }));
const togglePin = (song) => flip(library.pinned, song.id,
  () => api("/pins", { method: "PUT", body: forServer(song) }), () => api(`/pins/${song.id}`, { method: "DELETE" }));

async function newPlaylist() {
  const name = (prompt("New Playlist\n\nName") || "").trim();
  if (!name) return;
  try { await api("/playlists", { method: "POST", body: { name } }); await refreshLibrary(); route(); } catch { toast("Couldn't create it"); }
}
async function deletePlaylist(p) {
  if (!confirm(`Delete the playlist "${p.name}"?`)) return;
  try { await api(`/playlists/${p.id}`, { method: "DELETE" }); await refreshLibrary(); location.hash = "#/library"; route(); }
  catch { toast("Couldn't delete it"); }
}

async function loadMe() {
  try {
    library.me = await api("/me");
    if (library.me.profile) store.set("profileID", library.me.profile.id);
    if (library.me.user && !library.me.profile) chooseProfile(false);
  } catch { /* an older server without /me: keep the default profile */ }
  $("#top-profile").textContent = myProfileName() || "Profile";
}
function myProfileName() {
  return (library.me?.profile || library.me?.profiles?.find((p) => p.id === store.get("profileID", 1)))?.name;
}

// Profiles. On Tailscale the server knows whose device this is, so each
// person picks a profile once. Otherwise this browser remembers a choice.
function chooseProfile(canCancel) {
  const claim = async (body) => {
    try {
      const mine = await api("/me", { method: "POST", body });
      store.set("profileID", mine.id);
      await loadMe(); await refreshLibrary(); route();
    } catch { toast("Couldn't set your profile (name taken?)"); chooseProfile(canCancel); }
  };
  const free = (library.me?.profiles || []).filter((p) => !p.claimed && p.id !== library.me?.profile?.id);
  const name = h("input", { type: "text", placeholder: "Name" });
  const who = library.me?.user ? ` (${library.me.user.name})` : "";
  const extra = h("div", { class: "pad" },
    h("div", { class: "form-head" }, "Or start a new one"), name,
    h("div", { style: "margin-top:10px;display:flex;gap:10px" },
      h("button", { class: "primary", onclick: () => { const n = name.value.trim(); if (n) { closeSheet(); claim({ name: n }); } } }, "Create Profile"),
      canCancel && h("button", { class: "secondary", onclick: closeSheet }, "Cancel")),
    h("p", { class: "dim small" }, `Your likes, playlists, history, speed dial and podcasts are kept in your profile. You're recognised by your Tailscale account${who}, so there is no password.`));
  sheet("Who's listening?", free.map((p) => [p.name, () => claim({ profile_id: p.id })]), extra);
}

// Downloads: songs kept on this device so they play with no connection. The
// audio is stored by the browser; the service worker (sw.js) hands it to the
// player. Browsers only allow this on the secure https address.
const downloads = {
  supported: "serviceWorker" in navigator && window.isSecureContext && "caches" in window,
  songs: store.get("dl.songs", {}),       // id -> song (+ done: true once its audio is stored)
  singles: store.get("dl.singles", []),   // ids downloaded one at a time
  lists: store.get("dl.lists", {}),       // "liked" or "playlist:3" -> { name, ids }
  queue: [],
  working: false,
  onchange: null,                         // the screen showing progress, if any

  has(id) { return !!this.songs[id]?.done; },
  all() { return Object.values(this.songs).filter((s) => s.done).map(asSong); },
  /** [songs stored, songs wanted] for a downloaded list. */
  progress(key) { const ids = this.lists[key]?.ids || []; return [ids.filter((id) => this.has(id)).length, ids.length]; },
  save() { store.set("dl.songs", this.songs); store.set("dl.singles", this.singles); store.set("dl.lists", this.lists); },

  addSong(song) { if (!this.singles.includes(song.id)) this.singles.push(song.id); this.want([song]); },
  addList(key, name, songs) { this.lists[key] = { name, ids: songs.map((s) => s.id) }; this.want(songs); },
  /** Keep a downloaded list in step with the server's copy of it. */
  syncList(key, songs) {
    if (!this.lists[key]) return;
    this.lists[key].ids = songs.map((s) => s.id);
    this.want(songs);
    this.tidy();
  },
  removeSong(id) { this.singles = this.singles.filter((x) => x !== id); return this.tidy(); },
  removeList(key) { delete this.lists[key]; return this.tidy(); },
  removeAll() { this.singles = []; this.lists = {}; return this.tidy(); },

  want(songs) {
    for (const song of songs) {
      if (this.songs[song.id]) continue;
      this.songs[song.id] = { ...forServer(song), done: false };
      this.queue.push(song.id);
    }
    this.save();
    this.run();
  },
  /** Delete stored songs that no list (and no single download) needs any more. */
  async tidy() {
    const keep = new Set([...this.singles, ...Object.values(this.lists).flatMap((l) => l.ids)]);
    const audioStore = await caches.open("pitunes-audio");
    for (const id of Object.keys(this.songs)) {
      if (keep.has(id)) continue;
      delete this.songs[id];
      await audioStore.delete(`/stream/${id}`);
    }
    this.queue = this.queue.filter((id) => keep.has(id));
    this.save();
    markRows();
    this.onchange?.();
  },
  /** Fetch the waiting songs one at a time, which is gentle on the Pi. */
  async run() {
    if (this.working || !this.supported) return;
    this.working = true;
    const audioStore = await caches.open("pitunes-audio"), artStore = await caches.open("pitunes-art");
    while (this.queue.length) {
      const id = this.queue.shift(), song = this.songs[id];
      if (!song || song.done) continue;
      try {
        const response = await fetch(`/stream/${id}`);
        if (!response.ok) throw new Error(`Server error ${response.status}`);
        await audioStore.put(`/stream/${id}`, response);
        const picture = art(song.thumbnail);
        if (picture.startsWith("/img")) {
          const got = await fetch(picture).catch(() => null);
          if (got?.ok) await artStore.put(new URL(picture, location.href).href, got);
        }
        song.done = true;
        this.save();
        markRows();
        this.onchange?.();
      } catch { break; }   // offline, or the Pi is busy: carries on next time the app opens
    }
    this.working = false;
  },
  /** Carry on with downloads that didn't finish last time. */
  resume() {
    if (!this.supported) return;
    navigator.serviceWorker.register("/sw.js").catch(() => {});
    navigator.storage?.persist?.();       // ask the browser not to clear our songs when space is short
    this.queue = Object.keys(this.songs).filter((id) => !this.songs[id].done);
    this.run();
  },
};

/** Nav bar button: download a whole list, show progress, or remove it. */
function downloadButton(key, name, songs) {
  if (!downloads.supported) return null;
  const button = h("button", { class: "navbtn", onclick: async () => {
    if (!downloads.lists[key]) { downloads.addList(key, name, songs); toast("Downloading for offline listening"); }
    else if (confirm(`Remove downloads for ${name}?`)) await downloads.removeList(key);
    draw();
  } });
  const draw = () => {
    const [done, total] = downloads.progress(key);
    if (!downloads.lists[key]) { button.replaceChildren(icon("download"), h("span", {}, "Download")); button.title = "Download"; }
    else if (done < total) { button.replaceChildren(h("b", { class: "count" }, `${done}/${total}`)); button.title = "Downloading"; }
    else { button.replaceChildren(icon("downloadDone"), h("span", {}, "Downloaded")); button.title = "Downloaded"; }
    button.setAttribute("aria-label", button.title);
  };
  downloads.onchange = draw;
  draw();
  return button;
}

// -------------------------------------------------------------- 4. Player UI

/** Fill every element marked data-bind="name". */
function bind(name, fill) { for (const el of $$(`[data-bind="${name}"]`)) fill(el); }

/** Redraw every player control to match the player's state. */
function drawPlayer() {
  const song = player.current;
  document.body.classList.toggle("playing", !!song);
  document.body.classList.toggle("paused", audio.paused);
  $("#mini").hidden = !song;
  $("#bar").hidden = !song;
  if (!song) { $("#player").hidden = true; $("#panel").hidden = true; document.body.classList.remove("panel-open"); markRows(); return; }

  const busy = !audio.paused && audio.readyState < 3;   // asked to play, still loading
  const liked = library.liked.has(song.id);
  bind("art", (el) => { const src = art(song.thumbnail); if (el.getAttribute("src") !== src) el.src = src; });
  bind("title", (el) => { el.textContent = song.title; });
  bind("artist", (el) => { el.textContent = song.artist; });
  bind("status", (el) => { el.textContent = busy ? "Loading…" : song.artist; });
  bind("playicon", (el) => setIcon(el, audio.paused ? "play" : "pause"));
  bind("previcon", (el) => setIcon(el, song.episode ? "back30" : "prev"));
  bind("nexticon", (el) => setIcon(el, song.episode ? "forward30" : "next"));
  bind("likeicon", (el) => { setIcon(el, liked ? "heart" : "heartOutline"); el.classList.toggle("on", liked); el.hidden = !!song.episode; });
  bind("repeaticon", (el) => { setIcon(el, player.repeat === "one" ? "repeatOne" : "repeat"); el.classList.toggle("on", player.repeat !== "off"); el.hidden = !!song.episode; });
  bind("autoplaychip", (el) => { el.classList.toggle("on", player.autoplay); el.hidden = !!song.episode; });
  bind("lyricschip", (el) => { el.hidden = !!song.episode; });
  bind("speedchip", (el) => { el.hidden = !song.episode; el.lastChild.textContent = `${player.rate}x`; el.classList.toggle("on", player.rate !== 1); });
  for (const el of $$('[data-act="shuffle"]')) { el.disabled = player.upNext.length < 2; el.hidden = !!song.episode; }

  bind("queue", (list) => {
    list.replaceChildren();
    if (!player.upNext.length && !song.episode) {
      list.append(
        h("p", { class: "dim" }, player.autoplay ? "Similar songs will be added automatically."
                                                 : "Nothing queued. Turn on Autoplay to keep the music going."),
        h("button", { class: "chip", onclick: () => player.loadRadio(true) }, label("radio", "Add Similar Songs")));
    }
    player.upNext.forEach((s, offset) => {
      const i = player.index + 1 + offset;
      list.append(songRow(s, () => player.start(i), { removeAt: i }));
    });
  });
  drawProgress();
  markRows();
}

function drawProgress() {
  const total = isFinite(audio.duration) && audio.duration > 0 ? audio.duration : (player.current?.duration || 0);
  for (const seek of $$(".seek")) {
    seek.max = Math.max(total, 1);
    if (!seek.matches(":active")) seek.value = audio.currentTime;   // don't fight a finger dragging it
  }
  bind("now", (el) => { el.textContent = clock(audio.currentTime); });
  bind("total", (el) => { el.textContent = busyLoading() ? "Loading…" : clock(total); });
  bind("progress", (el) => { el.style.width = total ? `${Math.min(100, (audio.currentTime / total) * 100)}%` : "0"; });
}
const busyLoading = () => !audio.paused && audio.readyState < 3 && audio.currentTime < 1;

/** Mark rows and tiles for the song that's playing and for liked songs, on whatever screen is showing. */
function markRows() {
  const id = player.current?.id;
  for (const el of $$("[data-song]")) {
    el.classList.toggle("now", el.dataset.song === id);
    el.classList.toggle("liked", library.liked.has(el.dataset.song));
    el.classList.toggle("dl", downloads.has(el.dataset.song));
  }
}

/** A pop-up menu. `items` are [label, action, icon, danger] entries. */
function sheet(title, items, extra) {
  const box = $("#sheet-box");
  box.replaceChildren(h("h3", { class: "two-lines" }, title));
  for (const [text, action, iconName, danger] of items) {
    box.append(h("button", { class: `item${danger ? " danger" : ""}`, onclick: () => { closeSheet(); action(); } },
      h("span", { class: "grow" }, text), iconName && icon(iconName)));
  }
  if (extra) box.append(extra);
  $("#sheet").hidden = false;
}
function closeSheet() { $("#sheet").hidden = true; }

/** The "..." menu for a song. Same entries, in the same order, as the iPhone app. */
function songMenu(song, { isCurrent = false, removeAt = null, extra = [] } = {}) {
  const items = [...extra];
  if (removeAt != null) items.push(["Remove from Queue", () => player.removeAt(removeAt), "minusCircle", true]);
  if (!isCurrent) {
    items.push(["Play Next", () => { player.playNext(song); toast("Playing next"); }, "playNext"]);
    items.push(["Add to Queue", () => { player.addToQueue(song); toast("Added to queue"); }, "addQueue"]);
  }
  if (!song.episode) {
    items.push(["Start Radio", () => player.radio(song), "radio"]);
    if (downloads.supported) {
      if (downloads.singles.includes(song.id)) items.push(["Remove Download", () => downloads.removeSong(song.id), "trash", true]);
      else items.push(["Download", () => { downloads.addSong(song); toast("Downloading for offline listening"); }, "download"]);
    }
    if (!isCurrent) items.push([library.liked.has(song.id) ? "Unlike" : "Like", () => toggleLike(song), library.liked.has(song.id) ? "heart" : "heartOutline"]);
    items.push([library.pinned.has(song.id) ? "Unpin from Speed Dial" : "Pin to Speed Dial",
                () => togglePin(song).then(() => toast(library.pinned.has(song.id) ? "Pinned to speed dial" : "Unpinned")), "pin"]);
    if (navigator.share) {
      items.push(["Share", () => navigator.share({ title: song.title, url: `https://music.youtube.com/watch?v=${song.id}` }).catch(() => {}), "share"]);
    }
    items.push(["Add to Playlist", () => choosePlaylist(song), "musicList"]);
  }
  if (isCurrent && player.upNext.length) items.push(["Clear Up Next", () => player.clearUpNext(), "trash", true]);
  if (isCurrent) items.push([sleepLabel(), chooseSleepTimer, "moon"]);
  sheet(song.title, items);
}

function choosePlaylist(song) {
  if (!library.playlists.length) return toast("Create a playlist in Library first");
  sheet("Add to Playlist", library.playlists.map((p) => [p.name, async () => {
    try {
      await api(`/playlists/${p.id}/songs`, { method: "POST", body: forServer(song) });
      toast(`Added to ${p.name}`);
      refreshLibrary();
    } catch { toast("Couldn't add it"); }
  }, "musicList"]));
}

// Sleep timer: pause after a while.
let sleepTimer = null, sleepAt = null;
function sleepLabel() {
  return sleepAt ? `Sleep Timer (stops ${new Date(sleepAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })})` : "Sleep Timer";
}
function chooseSleepTimer() {
  const set = (minutes) => {
    clearTimeout(sleepTimer);
    sleepAt = minutes ? Date.now() + minutes * 60000 : null;
    sleepTimer = minutes ? setTimeout(() => { sleepAt = null; audio.pause(); }, minutes * 60000) : null;
    toast(minutes ? `Stopping in ${minutes} minutes` : "Sleep timer off");
  };
  const items = [15, 30, 45, 60].map((m) => [`${m} minutes`, () => set(m)]);
  if (sleepAt) items.push(["Turn Off", () => set(0)]);
  sheet("Sleep Timer", items);
}

function chooseSpeed() {
  sheet("Playback Speed", [0.8, 1, 1.2, 1.5, 1.75, 2].map((r) => [r === 1 ? "Normal" : `${r}x`, () => {
    player.rate = r; store.set("episodeRate", r); audio.playbackRate = r; drawPlayer();
  }, player.rate === r ? "check" : null]));
}

// Lyrics: a pop-up on a phone, a tab in the right-hand panel on a computer.
let currentLyricsFor = null;
async function loadLyrics(into) {
  const song = player.current;
  if (!song || song.episode) { into.replaceChildren(h("p", { class: "dim" }, "No lyrics for this.")); return; }
  currentLyricsFor = song.id;
  into.replaceChildren(spinner());
  try {
    const data = await api(`/music/lyrics/${song.id}`);
    if (currentLyricsFor !== song.id) return;
    into.replaceChildren(data.lyrics ? h("div", {}, data.lyrics, data.source && h("p", { class: "dim small" }, data.source))
                                     : emptyState("quote", "No lyrics", "No lyrics were found for this song."));
  } catch { into.replaceChildren(h("p", { class: "dim" }, "Couldn't load the lyrics.")); }
}
function showLyricsSheet() {
  const body = h("div", { class: "pad lyrics" });
  sheet(player.current?.title || "Lyrics", [], body);
  loadLyrics(body);
}
function showPanel(tab) {
  $("#panel").hidden = false;
  document.body.classList.add("panel-open");
  const lyrics = tab === "lyrics";
  $("#panel-queue").hidden = lyrics;
  $("#panel-lyrics").hidden = !lyrics;
  $('[data-act="panel-queue"]').classList.toggle("on", !lyrics);
  $('[data-act="panel-lyrics"]').classList.toggle("on", lyrics);
  if (lyrics) loadLyrics($("#panel-lyrics"));
}

// Volume. iPhones only let the side buttons change it (the page can't), so
// there the controls are hidden; everywhere else you get a slider and mute.
function setVolume(value) {
  audio.volume = Math.max(0, Math.min(1, value));
  if (audio.volume > 0) audio.muted = false;
  store.set("volume", audio.volume);
  drawVolume();
}
function drawVolume() {
  const level = audio.muted ? 0 : audio.volume;
  for (const slider of $$(".volume")) if (!slider.matches(":active")) slider.value = level;
  bind("volicon", (el) => setIcon(el, level === 0 ? "muted" : level < 0.5 ? "volumeLow" : "volume"));
}

// What each data-act="..." button does.
const actions = {
  toggle: () => player.toggle(),
  next: () => (player.current?.episode ? player.skip(30) : player.next()),
  prev: () => (player.current?.episode ? player.skip(-30) : player.previous()),
  like: () => player.current && toggleLike(player.current),
  menu: () => player.current && songMenu(player.current, { isCurrent: true }),
  shuffle: () => { player.shuffleUpNext(); toast("Up Next shuffled"); },
  repeat: () => {
    player.repeat = { off: "all", all: "one", one: "off" }[player.repeat];
    store.set("repeat", player.repeat);
    toast({ off: "Repeat off", all: "Repeating the queue", one: "Repeating this song" }[player.repeat]);
    drawPlayer();
  },
  mute: () => { audio.muted = !audio.muted; if (!audio.muted && audio.volume === 0) setVolume(0.5); drawVolume(); },
  autoplay: () => { player.autoplay = !player.autoplay; store.set("autoplay", player.autoplay); drawPlayer(); },
  lyrics: showLyricsSheet,
  speed: chooseSpeed,
  "close-player": () => { $("#player").hidden = true; },
  panel: () => {
    if ($("#panel").hidden) return showPanel("queue");
    $("#panel").hidden = true; document.body.classList.remove("panel-open");
  },
  "panel-queue": () => showPanel("queue"),
  "panel-lyrics": () => showPanel("lyrics"),
  back: () => history.back(),
  forward: () => history.forward(),
};

function wirePlayer() {
  // The tab bar (phone) / sidebar (computer). Same five tabs and icons as the iPhone app.
  const tabs = [["home", "Home", "home"], ["explore", "Explore", "explore"], ["podcasts", "Podcasts", "mic"],
                ["search", "Search", "search"], ["library", "Library", "musicList"]];
  $("#nav-tabs").replaceChildren(...tabs.map(([tab, text, iconName]) =>
    h("a", { href: `#/${tab}`, "data-tab": tab, class: tab === "search" ? "phone-only" : "" }, icon(iconName), h("span", {}, text))));
  // Chips in the player that carry an icon.
  bind("lyricschip", (el) => el.replaceChildren(...label("quote", "Lyrics")));
  bind("autoplaychip", (el) => el.replaceChildren(...label("infinity", "Autoplay")));
  bind("speedchip", (el) => el.replaceChildren(...label("history", "1x")));

  for (const el of $$("[data-act]")) {
    el.addEventListener("click", (e) => { e.stopPropagation(); actions[el.dataset.act]?.(); });
  }
  const fixed = { "close-player": "down", menu: "more", shuffle: "shuffle", panel: "queue", back: "back", forward: "forward" };
  for (const [act, name] of Object.entries(fixed)) for (const el of $$(`[data-act="${act}"]`)) setIcon(el, name);
  for (const seek of $$(".seek")) seek.addEventListener("change", (e) => { audio.currentTime = Number(e.target.value); });
  // Can this browser change the volume at all? (An iPhone ignores the request.)
  audio.volume = 0.5;
  document.body.classList.toggle("no-volume", audio.volume !== 0.5);
  audio.volume = store.get("volume", 1);
  for (const slider of $$(".volume")) slider.addEventListener("input", (e) => setVolume(Number(e.target.value)));
  drawVolume();
  $("#sheet").addEventListener("click", (e) => { if (e.target.id === "sheet") closeSheet(); });

  // Phone: tap the mini bar to open the player; swipe it down, or press and
  // hold it, to close the player (like the iPhone app).
  const mini = $("#mini");
  let startY = null;
  mini.addEventListener("click", () => { $("#player").hidden = false; });
  mini.addEventListener("touchstart", (e) => { startY = e.touches[0].clientY; }, { passive: true });
  mini.addEventListener("touchend", (e) => { if (startY != null && e.changedTouches[0].clientY - startY > 30) player.close(); startY = null; });
  mini.addEventListener("contextmenu", (e) => { e.preventDefault(); sheet("Player", [["Close Player", () => player.close(), "close", true]]); });
  // Phone: drag the full player down to close it.
  const full = $("#player");
  let fullY = null;
  full.addEventListener("touchstart", (e) => { fullY = full.scrollTop <= 0 ? e.touches[0].clientY : null; }, { passive: true });
  full.addEventListener("touchend", (e) => {
    if (fullY != null && e.changedTouches[0].clientY - fullY > 110 && full.scrollTop <= 0) full.hidden = true;
    fullY = null;
  });

  // Keyboard: space plays and pauses, up/down change the volume, M mutes,
  // left/right jump 10 seconds, "/" goes to search, Escape closes menus.
  document.addEventListener("keydown", (e) => {
    const typing = ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement.tagName);
    if (e.key === "Escape") { closeSheet(); document.activeElement.blur(); }
    if (typing) return;
    if (e.code === "Space") { e.preventDefault(); player.toggle(); }
    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      e.preventDefault();
      setVolume(audio.volume + (e.key === "ArrowUp" ? 0.05 : -0.05));
      toast("Volume " + Math.round(audio.volume * 100) + "%");
    }
    if (e.key === "ArrowRight" && player.current) player.skip(10);
    if (e.key === "ArrowLeft" && player.current) player.skip(-10);
    if (e.key.toLowerCase() === "m" && !e.metaKey && !e.ctrlKey) actions.mute();
    if (e.key === "/") { e.preventDefault(); (isDesktop() ? $("#top-search") : $("#view input[type=search]"))?.focus(); }
  });

  // Computer: the search box in the top bar drives the Search screen.
  $("#top-search").value = store.get("lastQuery", "");
  $("#top-search").addEventListener("input", (e) => {
    store.set("lastQuery", e.target.value);
    if (!location.hash.startsWith("#/search")) location.hash = "#/search"; else searchSoon();
  });
  $("#top-search").addEventListener("keydown", (e) => { if (e.key === "Enter") { location.hash = "#/search"; searchSoon(0); } });
}

/** Computer: your playlists in the sidebar. */
function drawSidebar() {
  $("#side-lists").replaceChildren(
    h("button", { class: "secondary new", onclick: newPlaylist }, label("plus", "New Playlist")),
    h("a", { href: "#/liked" }, h("b", {}, "Liked Songs"), `${library.liked.size} songs`),
    ...library.playlists.map((p) => h("a", { href: `#/playlist/${p.id}` }, h("b", { class: "one-line" }, p.name), `${p.song_count} songs`)),
    h("a", { href: "#/settings", class: "settings-link" }, h("b", {}, "Settings")));
}

// ----------------------------------------------- 5. Building blocks for screens

const view = $("#view");

/** The bar at the top of a screen. Root tabs get a large title; pushed
 *  screens get a back arrow and a centred title. `actions` sit on the right. */
function navBar(title, { root = false, actions = [] } = {}) {
  if (root) return h("div", { class: "navbar root" }, h("span", { class: "nav-actions" }, actions), h("h1", {}, title));
  return h("div", { class: "navbar" },
    h("button", { class: "icon back", "aria-label": "Back", onclick: () => history.back() }, icon("back")),
    h("div", { class: "nav-title one-line" }, title),
    h("span", { class: "nav-actions" }, actions));
}
/** A text-and-icon button for the nav bar (Follow, Save to Library...). */
function navButton(iconName, text, onclick, { showText = false } = {}) {
  // On a phone only some buttons show their words; on a computer they all do (see style.css).
  return h("button", { class: `navbtn${showText ? " with-text" : ""}`, "aria-label": text, title: text, onclick }, icon(iconName), h("span", {}, text));
}

/** Square artwork with the "now playing" bars over it. */
function artBox(url, round = false) {
  return h("span", { class: `art${round ? " round" : ""}` },
    h("img", { src: art(url), alt: "", loading: "lazy" }),
    h("i", { class: "eq" }, h("b"), h("b"), h("b")));
}

/** One song (or episode) in a list. `onTap` plays it; "..." opens the menu. */
function songRow(song, onTap, menuOptions = {}) {
  const open = (e) => { e.preventDefault(); e.stopPropagation(); songMenu(song, menuOptions); };
  return h("div", { class: "row", "data-song": song.id, onclick: onTap, oncontextmenu: open },
    artBox(song.thumbnail),
    h("div", { class: "grow" },
      h("div", { class: "t one-line" }, song.title),
      h("div", { class: "s dim one-line" }, song.video ? `Video • ${song.artist}` : song.artist)),
    h("i", { class: "dl-mark" }, icon("downloadDone")),
    h("i", { class: "liked-mark" }, icon("heart")),
    song.duration ? h("span", { class: "len" }, clock(song.duration)) : null,
    h("button", { class: "icon dim", "aria-label": "More", onclick: open }, icon("more")));
}

/** A list of songs where tapping one plays the list from there. */
function songList(songs, menuFor = () => ({})) {
  return h("div", { class: "list" }, songs.map((song, i) => songRow(song, () => player.play(songs, i), menuFor(song))));
}

/** Play and Shuffle, side by side. */
function playShuffle(songs) {
  return h("div", { class: "pair" },
    h("button", { class: "primary", onclick: () => player.play(songs) }, label("play", "Play")),
    h("button", { class: "secondary", onclick: () => player.play(shuffled(songs)) }, label("shuffle", "Shuffle")));
}

/** "Nothing here" message with a big icon. */
function emptyState(iconName, title, detail) {
  return h("div", { class: "empty" }, icon(iconName), h("h3", {}, title), detail && h("p", { class: "dim" }, detail));
}
/** Inline message for errors and notes. */
function notice(text, isError = true) {
  return h("div", { class: `notice${isError ? " error" : ""}` }, icon("info"), h("span", {}, text));
}

/** Where an album, playlist or artist lives. */
function routeFor(item) {
  return { album: `#/album/${item.id}`, playlist: `#/ytplaylist/${item.id}`, artist: `#/artist/${item.id}` }[item.type];
}

/** Play an album or playlist straight from its card. */
async function playItem(item) {
  try {
    const list = await api(item.type === "album" ? `/music/album/${item.id}` : `/music/playlist/${item.id}`);
    player.play(list.tracks.map(asSong));
  } catch { toast("Couldn't play that"); }
}

/** A song, album, playlist or artist as a row (search results, library). */
function itemRow(item) {
  if (item.type === "song") { const song = asSong(item); return songRow(song, () => player.radio(song)); }
  const kind = item.type[0].toUpperCase() + item.type.slice(1);
  return h("a", { class: "row", href: routeFor(item) },
    artBox(item.thumbnail, item.type === "artist"),
    h("div", { class: "grow" }, h("div", { class: "t one-line" }, item.title), h("div", { class: "s dim one-line" }, item.subtitle || kind)),
    h("span", { class: "chev" }, icon("forward")));
}

/** The same, as a square card. On a computer, hovering shows a play button. */
function itemCard(item) {
  const song = item.type === "song" ? asSong(item) : null;
  const playNow = (e) => { e.preventDefault(); e.stopPropagation(); if (song) player.radio(song); else playItem(item); };
  const inside = [
    h("div", { class: "pic" }, h("img", { src: art(item.thumbnail), alt: "", loading: "lazy" }),
      item.type !== "artist" && h("button", { class: "go", "aria-label": "Play", onclick: playNow }, icon("play"))),
    h("div", { class: "t two-lines" }, item.title), item.subtitle && h("div", { class: "s dim one-line" }, item.subtitle)];
  if (song) return h("div", { class: "card", "data-song": song.id, onclick: () => player.radio(song), oncontextmenu: (e) => { e.preventDefault(); songMenu(song); } }, inside);
  return h("a", { class: `card${item.type === "artist" ? " round" : ""}`, href: routeFor(item) }, inside);
}

/** A section title with optional things on the right; on a computer, arrows that scroll `strip`. */
function sectionHead(title, extra, strip) {
  const move = (dir) => strip.scrollBy({ left: dir * strip.clientWidth * 0.85 });
  return h("div", { class: "section" }, h("h3", {}, title), extra,
    strip && h("span", { class: "arrows" },
      h("button", { class: "icon", "aria-label": "Scroll back", onclick: () => move(-1) }, icon("back")),
      h("button", { class: "icon", "aria-label": "Scroll on", onclick: () => move(1) }, icon("forward"))));
}
/** A sideways row of cards with a title. */
function carousel(title, cards, extra) {
  const strip = h("div", { class: "shelf" }, cards);
  return [sectionHead(title, extra, strip), strip];
}

/** A titled shelf from the server. Songs: four rows you swipe sideways (like
 *  "Quick picks"). Anything else: a row of cards. */
function shelf(s) {
  if (!s.items.every((i) => i.type === "song")) return carousel(s.title, s.items.map(itemCard));
  const songs = s.items.map(asSong);
  const strip = h("div", { class: "quick" }, songs.map((song) => songRow(song, () => player.radio(song))));
  return [sectionHead(s.title, h("button", { class: "chip", onclick: () => player.play(songs) }, label("play", "Play all")), strip), strip];
}

/** Mood chips in three rows that scroll sideways (Explore, Moods & genres). */
function moodChips(title, moods) {
  const strip = h("div", { class: "chipgrid" }, moods.map(moodLink));
  return [sectionHead(title, null, strip), strip];
}
const moodLink = (m) => h("a", { class: "chip", href: `#/mood/${encodeURIComponent(m.params)}/${encodeURIComponent(m.title)}` }, m.title);

function spinner() { return h("div", { class: "spinner" }); }

/** Show a spinner, then whatever `build` returns; offer "Try Again" if it fails. */
async function screen(build) {
  const token = (screen.token = {});          // if the user moves on, drop the late result
  view.replaceChildren(spinner());
  window.scrollTo(0, 0);
  try {
    const content = await build();
    if (screen.token === token) { view.replaceChildren(...[content].flat(Infinity).filter(Boolean)); markRows(); }
  } catch (error) {
    if (screen.token === token) {
      view.replaceChildren(navBar(""), emptyState("info", "Couldn't load", error.message),
                           h("div", { class: "pair" }, h("button", { class: "secondary", onclick: route }, "Try Again")));
    }
  }
}

// ---------------------------------------------------------------- 6. Screens

/** Speed dial: up to three pages of nine, swiped sideways, with page dots. */
function speedDial(songs) {
  const pages = [];
  for (let i = 0; i < songs.length && pages.length < 3; i += 9) pages.push(songs.slice(i, i + 9));
  const dots = h("div", { class: "dots" }, pages.map((_, i) => h("i", { class: i ? "" : "on" })));
  const strip = h("div", { class: "dial" }, pages.map((page) => h("div", { class: "page" }, page.map((song) =>
    h("button", { "data-song": song.id, "aria-label": `${song.title}, ${song.artist}`, onclick: () => player.radio(song),
                  oncontextmenu: (e) => { e.preventDefault(); songMenu(song); } },
      h("img", { src: art(song.thumbnail), alt: "", loading: "lazy" }),
      h("i", { class: "eq badge" }, h("b"), h("b"), h("b")),
      library.pinned.has(song.id) && h("i", { class: "pin" }, icon("pin")),
      h("span", {}, h("b", { class: "two-lines" }, song.title)))))));
  strip.addEventListener("scroll", () => {
    const page = Math.round(strip.scrollLeft / Math.max(strip.clientWidth, 1));
    [...dots.children].forEach((dot, i) => dot.classList.toggle("on", i === page));
  }, { passive: true });
  return [sectionHead("Speed dial"), strip, pages.length > 1 && dots];
}

/** "Your mixes": an endless mix of similar songs for each of your top songs. */
function mixShelf(songs) {
  return carousel("Your mixes", songs.map((song) =>
    h("div", { class: "card", onclick: () => player.radio(song) },
      h("div", { class: "pic" }, h("img", { src: art(song.thumbnail), alt: "", loading: "lazy" }), h("i", { class: "badge-br" }, icon("radio"))),
      h("div", { class: "t two-lines" }, `${song.title} Mix`), h("div", { class: "s dim one-line" }, `Like ${song.artist}`))));
}

const screens = {
  async home() {
    await screen(async () => {
      const [dial, page] = await Promise.all([api("/speed-dial?limit=27").catch(() => []), api("/music/home")]);
      const songs = dial.map(asSong);
      return [
        navBar("Home", { root: true }),
        page.moods?.length && h("div", { class: "chips" }, page.moods.map(moodLink)),
        songs.length > 0 && speedDial(songs),
        songs.length >= 3 && mixShelf(songs.slice(0, 8)),
        page.shelves.map(shelf),
      ];
    });
  },

  async explore() {
    await screen(async () => {
      const page = await api("/music/explore");
      return [navBar("Explore", { root: true }),
        h("div", { class: "pair" },
          h("a", { class: "secondary", href: "#/charts" }, label("chart", "Charts")),
          h("a", { class: "secondary", href: "#/moods" }, label("smile", "Moods & genres"))),
        page.shelves.map(shelf),
        page.moods?.length && moodChips("Moods & genres", page.moods)];
    });
  },

  async charts() {
    await screen(async () => {
      const country = store.get("chartsCountry", (navigator.language.split("-")[1] || "US").toUpperCase());
      const page = await api(`/music/charts?country=${country}`);
      const names = new Intl.DisplayNames([navigator.language], { type: "region" });
      const name = (c) => { try { return names.of(c) || c; } catch { return c; } };
      // Country picker in the top corner, as on the phone.
      const picker = h("label", { class: "navbtn with-text" }, icon("globe"), h("span", {}, name(country)),
        h("select", { "aria-label": "Country", onchange: (e) => { store.set("chartsCountry", e.target.value); route(); } },
          (page.countries || [country]).map((c) => h("option", { value: c, selected: c === country }, name(c)))));
      return [navBar("Charts", { actions: [picker] }), page.shelves.map(shelf)];
    });
  },

  async moods() {
    await screen(async () => {
      const page = await api("/music/moods");
      return [navBar("Moods & genres"), page.groups.map((g) => moodChips(g.title, g.moods))];
    });
  },

  async mood(params, title) {
    await screen(async () => {
      const page = await api(`/music/mood/${params}`);
      return [navBar(decodeURIComponent(title || "Mood")), h("div", { class: "grid" }, page.items.map(itemCard))];
    });
  },

  // --- Search: the field under the title (in the top bar on a computer),
  // filter chips once you've typed something, recent searches before that.
  async search() {
    const results = h("div", { class: "list" });
    const box = h("input", { type: "search", class: "phone-only", placeholder: "Songs, albums, artists", autocomplete: "off", value: store.get("lastQuery", "") });
    const chips = h("div", { class: "chips" });
    const filters = [["All", null], ["Songs", "songs"], ["Albums", "albums"], ["Artists", "artists"], ["Playlists", "playlists"]];
    let filter = null;
    const drawChips = () => {
      chips.hidden = !store.get("lastQuery", "").trim();
      chips.replaceChildren(...filters.map(([text, value]) =>
        h("button", { class: `chip${filter === value ? " on" : ""}`, onclick: () => { filter = value; drawChips(); run(); } }, text)));
    };
    const useRecent = (q) => { store.set("lastQuery", q); box.value = $("#top-search").value = q; drawChips(); run(); };
    const showRecents = () => {
      const recents = store.get("recentSearches", []);
      if (!recents.length) return results.replaceChildren(emptyState("search", "Search for music", "Tap a song to play it, then similar songs."));
      results.replaceChildren(
        h("div", { class: "list-head" }, h("span", {}, "Recent searches"),
          h("button", { onclick: () => { store.set("recentSearches", []); showRecents(); } }, "Clear")),
        ...recents.map((q) => h("div", { class: "row plain", onclick: () => useRecent(q) },
          h("span", { class: "lead" }, icon("history")), h("div", { class: "grow one-line" }, q),
          h("button", { class: "icon dim", "aria-label": "Remove", onclick: (e) => {
            e.stopPropagation(); store.set("recentSearches", recents.filter((r) => r !== q)); showRecents(); } }, icon("close")))));
    };
    const run = async () => {
      const q = store.get("lastQuery", "").trim();
      drawChips();
      if (!q) return showRecents();
      results.replaceChildren(spinner());
      try {
        const page = await api(`/music/search?q=${encodeURIComponent(q)}${filter ? `&filter=${filter}` : ""}`);
        if (store.get("lastQuery", "").trim() !== q) return;      // the user kept typing; a newer search is on its way
        results.replaceChildren(...(page.items.length ? page.items.map(itemRow) : [emptyState("search", "No results", "Try a different search.")]));
        store.set("recentSearches", [q, ...store.get("recentSearches", []).filter((r) => r.toLowerCase() !== q.toLowerCase())].slice(0, 12));
        markRows();
      } catch (error) { results.replaceChildren(notice(`Search failed. ${error.message}`)); }
    };
    searchRun = run;
    box.addEventListener("input", () => { store.set("lastQuery", box.value); searchSoon(); });
    box.addEventListener("keydown", (e) => { if (e.key === "Enter") { box.blur(); searchSoon(0); } });
    screen.token = {};
    view.replaceChildren(navBar("Search", { root: true }), box, chips, results);
    window.scrollTo(0, 0);
    run();
  },

  // --- Library: the same rows, icon tiles and sections as the phone.
  async library() {
    await screen(async () => {
      await refreshLibrary();
      const row = (iconName, title, subtitle, href, { gradient = true, onclick, trailing } = {}) =>
        h(href ? "a" : "div", { class: "row", href, onclick },
          h("span", { class: `tile${gradient ? " gradient" : ""}` }, icon(iconName)),
          h("div", { class: "grow" }, h("div", { class: "t one-line" }, title), subtitle && h("div", { class: "s dim one-line" }, subtitle)),
          trailing || (href && h("span", { class: "chev" }, icon("forward"))));
      return [
        navBar("Library", { root: true, actions: [h("a", { class: "navbtn", href: "#/settings", "aria-label": "Settings", title: "Settings" }, icon("gear"))] }),
        h("div", { class: "list" },
          row("heart", "Liked Songs", `${library.liked.size} songs`, "#/liked"),
          downloads.supported && row("download", "Downloads", "On this device", "#/downloads"),
          row("history", "History", "Recently played", "#/history")),
        h("div", { class: "list-head" }, h("span", {}, "Playlists")),
        h("div", { class: "list" },
          library.playlists.map((p) => row("musicList", p.name, `${p.song_count} songs`, `#/playlist/${p.id}`, { gradient: false,
            trailing: h("button", { class: "icon dim", "aria-label": "More", onclick: (e) => {
              e.preventDefault(); e.stopPropagation(); sheet(p.name, [["Delete Playlist", () => deletePlaylist(p), "trash", true]]); } }, icon("more")) })),
          row("plus", "New Playlist", null, null, { gradient: false, onclick: newPlaylist })),
        library.saved.length > 0 && [
          h("div", { class: "list-head" }, h("span", {}, "Artists")),
          h("div", { class: "list" }, library.saved.map((item) => {
            const r = itemRow(item);
            r.lastChild.replaceWith(h("button", { class: "icon dim", "aria-label": "More", onclick: (e) => {
              e.preventDefault(); e.stopPropagation();
              sheet(item.title, [["Unfollow", async () => { await api(`/saved/artist/${item.id}`, { method: "DELETE" }).catch(() => {}); route(); }, "minusCircle", true]]); } }, icon("more")));
            return r;
          }))],
      ];
    });
  },

  // --- Settings: profile and server, as on the phone.
  async settings() {
    await screen(async () => {
      await loadMe();
      const me = library.me;
      const status = h("div", { class: "s dim" });
      const test = async () => {
        status.textContent = "Checking…";
        try { await api("/health"); status.textContent = "✅ Connected"; } catch (e) { status.textContent = `❌ ${e.message}`; }
      };
      let profile;
      if (me?.user) {   // the server knows whose device this is: nothing to pick
        profile = [
          h("div", { class: "form" },
            h("div", { class: "form-row" }, h("span", {}, "Listening as"), h("span", { class: "dim" }, me.profile?.name || "Not chosen")),
            h("button", { class: "form-row link", onclick: () => chooseProfile(true) }, "Use a Different Profile")),
          h("p", { class: "form-foot" }, `Recognised by your Tailscale account (${me.user.name}). Each person has their own likes, playlists, history, speed dial and podcasts.`)];
      } else {
        const name = h("input", { type: "text", placeholder: "New profile name" });
        const add = async () => {
          const n = name.value.trim();
          if (!n) return;
          try { const made = await api("/profiles", { method: "POST", body: { name: n } }); store.set("profileID", made.id); await refreshLibrary(); route(); }
          catch { toast("Couldn't create that profile (name taken?)"); }
        };
        name.addEventListener("keydown", (e) => { if (e.key === "Enter") add(); });
        profile = [
          h("div", { class: "form" },
            h("label", { class: "form-row" }, h("span", {}, "Listening as"),
              h("select", { "aria-label": "Listening as", onchange: async (e) => { store.set("profileID", Number(e.target.value)); await loadMe(); await refreshLibrary(); } },
                (me?.profiles || []).map((p) => h("option", { value: p.id, selected: p.id === store.get("profileID", 1) }, p.name)))),
            h("div", { class: "form-row" }, name, h("button", { class: "link", onclick: add }, "Add"))),
          h("p", { class: "form-foot" }, "Each profile has its own likes, playlists, history, speed dial and podcasts. There are no passwords: pick yours once on each device.")];
      }
      return [navBar("Settings"),
        h("div", { class: "form-head" }, "Profile"), profile,
        h("div", { class: "form-head" }, "Server"),
        h("div", { class: "form" },
          h("div", { class: "form-row" }, h("span", {}, "Server"), h("span", { class: "dim one-line" }, location.origin)),
          h("button", { class: "form-row link", onclick: test }, "Test Connection"),
          h("div", { class: "form-row" }, status)),
        h("p", { class: "form-foot" }, "Your PiTunes server on Tailscale. This web app is served by it, so the address is whatever you opened. Tailscale must be connected."),
        h("div", { class: "form-head" }, "About"),
        h("div", { class: "form" },
          h("a", { class: "form-row link", href: "https://pitunes.com", target: "_blank", rel: "noopener" }, "Setup guide at pitunes.com")),
        // Downloads only work on the secure address; point there from the plain one.
        !downloads.supported && me?.https && [
          h("div", { class: "form-head" }, "Offline"),
          h("div", { class: "form" }, h("a", { class: "form-row link", href: me.https }, "Open the secure address")),
          h("p", { class: "form-foot" }, `Downloads for offline listening need the secure address, ${me.https}. Open it and add that one to your home screen.`)],
        h("p", { class: "form-foot" }, "Sound search and CarPlay are in the iPhone app only.")];
    });
  },

  async liked() { await songsScreen({ title: "Liked Songs", load: () => api("/likes"), emptyIcon: "heart", downloadKey: "liked" }); },

  // --- Everything stored on this device, with the space it uses and "Remove All".
  async downloads() {
    await screen(async () => {
      const songs = downloads.all();
      const used = (await navigator.storage?.estimate?.())?.usage || 0;
      const removeAll = navButton("trash", "Remove All", async () => {
        if (!confirm("Remove all downloads from this device?\n\nYour playlists and likes stay; only the files stored here are deleted.")) return;
        await downloads.removeAll(); route();
      }, { showText: true });
      downloads.onchange = null;
      return [navBar("Downloads", { actions: songs.length ? [removeAll] : [] }),
        songs.length > 0 && playShuffle(songs),
        songs.length > 0 && h("p", { class: "dim small" }, `${songs.length} songs · ${(used / 1048576).toFixed(0)} MB on this device`),
        songs.length ? songList(songs) : emptyState("download", "No downloads", "Use ••• → Download on a song, or the download button on a playlist.")];
    });
  },
  async history() { await songsScreen({ title: "History", load: () => api("/history?limit=100"), emptyIcon: "history" }); },

  // --- One of your own playlists, with Edit (remove and reorder songs).
  async playlist(id, mode) {
    const editing = mode === "edit";
    await screen(async () => {
      const p = await api(`/playlists/${id}`);
      let songs = p.songs.map(asSong);
      const list = h("div", { class: "list" });
      const saveOrder = () => api(`/playlists/${id}/order`, { method: "PUT", body: { item_ids: songs.map((s) => s.itemId) } }).catch(() => toast("Couldn't save the order"));
      const draw = () => list.replaceChildren(...songs.map((song, i) => {
        if (!editing) return songRow(song, () => player.play(songs, i), { extra: [["Remove from This Playlist", () => remove(i), "minusCircle", true]] });
        // Edit mode: a remove button in front, up/down arrows behind.
        return h("div", { class: "row" },
          h("button", { class: "icon danger", "aria-label": "Remove", onclick: () => remove(i) }, icon("minusCircle")),
          artBox(song.thumbnail),
          h("div", { class: "grow" }, h("div", { class: "t one-line" }, song.title), h("div", { class: "s dim one-line" }, song.artist)),
          h("button", { class: "icon dim", "aria-label": "Move up", disabled: i === 0, onclick: () => move(i, -1) }, icon("up")),
          h("button", { class: "icon dim", "aria-label": "Move down", disabled: i === songs.length - 1, onclick: () => move(i, 1) }, icon("down")));
      }));
      const remove = async (i) => {
        const [gone] = songs.splice(i, 1);
        draw();
        try { await api(`/playlists/${id}/songs/${gone.itemId}`, { method: "DELETE" }); refreshLibrary(); } catch { toast("Couldn't remove it"); route(); }
      };
      const move = (i, by) => { [songs[i], songs[i + by]] = [songs[i + by], songs[i]]; draw(); saveOrder(); };
      draw();
      const editButton = h("a", { class: "navbtn with-text", href: editing ? `#/playlist/${id}` : `#/playlist/${id}/edit` }, h("span", {}, editing ? "Done" : "Edit"));
      downloads.syncList(`playlist:${id}`, songs);
      return [navBar(p.name, { actions: [!editing && songs.length > 0 && downloadButton(`playlist:${id}`, p.name, songs), editButton] }),
        songs.length > 0 && !editing && playShuffle(songs),
        editing && h("div", { class: "pair" }, h("button", { class: "secondary danger", onclick: () => deletePlaylist(p) }, label("trash", "Delete Playlist"))),
        songs.length ? list : emptyState("musicList", "Empty playlist", "Add songs with the ••• menu on any song.")];
    });
  },

  async album(id) { await trackList(() => api(`/music/album/${id}`)); },
  async ytplaylist(id) { await trackList(() => api(`/music/playlist/${id}`)); },

  async artist(id) {
    await screen(async () => {
      const a = await api(`/music/artist/${id}`);
      const first = a.shelves.find((s) => s.items.every((i) => i.type === "song"))?.items[0];
      const me = { type: "artist", id, title: a.name || "Artist", subtitle: "Artist", thumbnail: a.thumbnail };
      const followed = () => library.saved.some((s) => s.type === "artist" && s.id === id);
      // Follow sits in the top corner; followed artists are listed in Library.
      const follow = navButton("plusCircle", "Follow", async () => {
        try {
          if (followed()) await api(`/saved/artist/${id}`, { method: "DELETE" }); else await api("/saved", { method: "PUT", body: me });
          await refreshLibrary(); drawFollow();
        } catch { toast("Couldn't save that"); }
      }, { showText: true });
      const drawFollow = () => { follow.replaceChildren(icon(followed() ? "checkCircle" : "plusCircle"), h("span", {}, followed() ? "Following" : "Follow")); };
      drawFollow();
      // Play and Shuffle use the artist's full "top songs" playlist.
      const playAll = async (mix) => {
        try { const list = await api(`/music/playlist/${a.songs_playlist}`); const songs = list.tracks.map(asSong); player.play(mix ? shuffled(songs) : songs); }
        catch { toast("Couldn't play that"); }
      };
      return [navBar(a.name || "Artist", { actions: [follow] }),
        h("div", { class: "hero round" }, h("img", { src: art(a.thumbnail), alt: "" }),
          h("div", { class: "hero-text" }, h("h1", {}, a.name || "Artist"), a.subscribers && h("div", { class: "dim" }, `${a.subscribers} subscribers`),
            h("div", { class: "pair" },
              a.songs_playlist && h("button", { class: "primary", onclick: () => playAll(false) }, label("play", "Play")),
              a.songs_playlist && h("button", { class: "secondary", onclick: () => playAll(true) }, label("shuffle", "Shuffle")),
              first && h("button", { class: "secondary", onclick: () => player.radio(asSong(first)) }, label("radio", "Radio"))))),
        a.shelves.map(shelf)];
    });
  },

  // --- Podcasts: search, category chips, continue listening, your shows,
  // the top chart as large cards, then a shelf per category.
  async podcasts(category) {
    await screen(async () => {
      const country = (navigator.language.split("-")[1] || "US").toLowerCase();
      const [browse, mine, unfinished] = await Promise.all([
        api(`/podcasts/browse?country=${country}`).catch(() => ({ shelves: [] })),
        api("/podcasts/subscriptions").catch(() => []), api("/podcasts/continue").catch(() => [])]);
      const picked = category && decodeURIComponent(category);
      const body = h("div");
      const grid = (title, shows) => [h("div", { class: "section" }, h("h3", {}, title)),
        shows.length ? h("div", { class: "grid" }, shows.map((s) => showCard(s))) : h("p", { class: "dim" }, "No podcasts found.")];
      const overview = () => {
        if (picked) return grid(picked, browse.shelves.find((s) => s.title === picked)?.shows || []);
        const episodes = unfinished.map((e) => asEpisode(e));
        return [
          episodes.length > 0 && [h("div", { class: "section" }, h("h3", {}, "Continue listening")), h("div", { class: "list" }, episodes.map(episodeRow))],
          mine.length > 0 && carousel("Your shows", mine.map((s) => showCard(s))),
          browse.shelves.map((s, i) => carousel(s.title, s.shows.map((x) => showCard(x, i === 0)),
            i > 0 && h("a", { class: "chip", href: `#/podcasts/${encodeURIComponent(s.title)}` }, "More"))),
          !browse.shelves.length && notice("Couldn't load the podcast charts right now.")];
      };
      const fill = (content) => { body.replaceChildren(...[content].flat(Infinity).filter(Boolean)); markRows(); };
      const chips = h("div", { class: "chips" }, browse.shelves.slice(1).map((s) =>
        h("a", { class: `chip${picked === s.title ? " on" : ""}`, href: picked === s.title ? "#/podcasts" : `#/podcasts/${encodeURIComponent(s.title)}` }, s.title)));
      const find = h("input", { type: "search", placeholder: "Find a podcast", autocomplete: "off" });
      find.addEventListener("keydown", async (e) => {
        if (e.key !== "Enter" || !find.value.trim()) return;
        find.blur(); chips.hidden = true; fill(spinner());
        try { fill(grid("Results", (await api(`/podcasts/search?q=${encodeURIComponent(find.value.trim())}`)).shows)); }
        catch (error) { fill(notice(error.message)); }
      });
      find.addEventListener("input", () => { if (!find.value) { chips.hidden = false; fill(overview()); } });
      fill(overview());
      return [navBar("Podcasts", { root: true }), find, chips, body];
    });
  },

  async show(feedPart) {
    await screen(async () => {
      const feed = decodeURIComponent(feedPart);
      const show = await api(`/podcasts/show?feed=${encodeURIComponent(feed)}`);
      const episodes = show.episodes.map((e) => asEpisode(e, show));
      const sub = h("button", { class: "secondary", onclick: async () => {
        try {
          if (show.subscribed) await api(`/podcasts/subscriptions?feed=${encodeURIComponent(feed)}`, { method: "DELETE" });
          else await api("/podcasts/subscriptions", { method: "PUT", body: { feed, title: show.title, author: show.author, artwork: show.artwork } });
          show.subscribed = !show.subscribed; drawSub();
        } catch { toast("Couldn't save that"); }
      } });
      const drawSub = () => sub.replaceChildren(...label(show.subscribed ? "check" : "plus", show.subscribed ? "Subscribed" : "Subscribe"));
      drawSub();
      return [navBar(show.title),
        h("div", { class: "hero" }, h("img", { src: art(show.artwork), alt: "" }),
          h("div", { class: "hero-text" }, h("h1", {}, show.title), h("div", { class: "dim" }, show.author || ""),
            h("div", { class: "pair" },
              episodes.length > 0 && h("button", { class: "primary", onclick: () => player.play([episodes[0]]) }, label("play", "Latest")), sub),
            show.description && h("div", { class: "about" }, show.description))),
        h("div", { class: "list" }, episodes.map(episodeRow))];
    });
  },
};

/** Liked Songs and History share this layout. */
async function songsScreen({ title, load, emptyIcon, downloadKey }) {
  await screen(async () => {
    const songs = (await load()).map(asSong);
    if (downloadKey) downloads.syncList(downloadKey, songs);   // newly liked songs get downloaded too
    return [navBar(title, { actions: [downloadKey && songs.length > 0 && downloadButton(downloadKey, title, songs)] }),
      songs.length > 0 && playShuffle(songs),
      songs.length ? songList(songs) : emptyState(emptyIcon, title)];
  });
}

/** An album or a YouTube Music playlist. */
async function trackList(load) {
  await screen(async () => {
    const list = await load();
    const songs = list.tracks.map(asSong);
    // Copy into your own playlists.
    const save = navButton("plusCircle", "Save to Library", async () => {
      try {
        await api("/playlists/import", { method: "POST", body: { name: list.title || "Playlist", songs: songs.map(forServer) } });
        toast("Saved to your playlists"); refreshLibrary();
      } catch { toast("Couldn't save it"); }
    });
    return [navBar(list.title || "", { actions: [save] }),
      h("div", { class: "hero" }, h("img", { src: art(list.thumbnail), alt: "" }),
        h("div", { class: "hero-text" }, h("h1", {}, list.title || ""), h("div", { class: "dim" }, list.subtitle || ""),
          songs.length > 0 && playShuffle(songs))),
      songList(songs)];
  });
}

// Podcast pieces
function showCard(show, large = false) {
  return h("a", { class: `card${large ? " large" : ""}`, href: `#/show/${encodeURIComponent(show.feed)}` },
    h("div", { class: "pic" }, h("img", { src: art(show.artwork), alt: "", loading: "lazy" })),
    h("div", { class: "t two-lines" }, show.title), show.author && h("div", { class: "s dim one-line" }, show.author));
}
/** An episode in a list: title, date, length or time left. */
function episodeRow(ep) {
  const parts = [];
  if (ep.artist && !ep.published) parts.push(ep.artist);
  if (ep.published) parts.push(new Date(ep.published * 1000).toLocaleDateString([], { day: "numeric", month: "short", year: "numeric" }));
  if (ep.duration) {
    if (ep.position > 30 && !ep.finished) parts.push(`${Math.max(1, Math.floor((ep.duration - ep.position) / 60))} min left`);
    else parts.push(ep.duration >= 3600 ? `${Math.floor(ep.duration / 3600)} hr ${Math.floor((ep.duration % 3600) / 60)} min` : `${Math.max(1, Math.floor(ep.duration / 60))} min`);
  }
  const open = (e) => { e.preventDefault(); e.stopPropagation(); songMenu(ep); };
  return h("div", { class: `row episode${ep.finished ? " finished" : ""}`, "data-song": ep.id, onclick: () => player.play([ep]), oncontextmenu: open },
    artBox(ep.thumbnail),
    h("div", { class: "grow" },
      h("div", { class: "t two-lines" }, ep.title),
      h("div", { class: "s dim one-line" }, ep.finished && h("i", { class: "inline" }, icon("checkCircle")), parts.join(" · ")),
      ep.position > 30 && ep.duration && !ep.finished && h("div", { class: "epbar" }, h("i", { style: `width:${Math.min(100, (ep.position / ep.duration) * 100)}%` }))),
    h("button", { class: "icon dim", "aria-label": "More", onclick: open }, icon("more")));
}

// Searching waits a moment after the last keystroke.
let searchRun = () => {}, searchTimer = null;
function searchSoon(delay = 450) { clearTimeout(searchTimer); searchTimer = setTimeout(() => searchRun(), delay); }

// ----------------------------------------------------------------- 7. Router

/** Draw the screen named in the address bar: "#/album/XYZ" calls screens.album("XYZ"). */
function route() {
  const [name = "home", ...args] = location.hash.replace(/^#\/?/, "").split("/").filter(Boolean);
  const draw = screens[name] || screens.home;
  // Light up the tab this screen belongs to.
  const tab = { home: "home", mood: "home", explore: "explore", charts: "explore", moods: "explore", search: "search",
                podcasts: "podcasts", show: "podcasts", library: "library", liked: "library", history: "library",
                playlist: "library", settings: "library", downloads: "library" }[name];
  if (tab) for (const a of $$("#nav a[data-tab]")) a.classList.toggle("on", a.dataset.tab === tab);
  if (name !== "search") searchRun = () => {};
  draw(...args);
}

window.addEventListener("hashchange", route);
wirePlayer();
drawPlayer();
drawSidebar();
loadMe().then(refreshLibrary).then(drawPlayer);
downloads.resume();
route();
