# PiTunes design system

All tokens and shared components live in `ios/PiTunes/Design/Theme.swift`.
Views use them instead of hardcoded colors or numbers.

## Principles

1. **Artwork is the color.** The UI is near-black and quiet; album art (and the
   blurred backdrop in Now Playing) provides the color.
2. **One accent, used sparingly.** Coral marks exactly three things: the primary
   action on a screen, what's playing now, and what you've liked.
3. **One primary action per screen.** Play is filled coral; everything beside it
   (Shuffle, Radio, Charts) is a neutral secondary button.
4. **Dark only.** A music app is used at night and in the car; one theme keeps
   contrast decisions simple.

## Color

| Token | Value | Use |
|---|---|---|
| `bg` | `#0B0B0F` | Screen background |
| `surface` | `#17171D` | Notices, tiles |
| `surfaceRaised` | `#25252E` | Mini player, chips, secondary buttons |
| `accent` | `#FF4D67` | Primary button, now-playing, likes, selected chip |
| `accent2` | `#8B5CF6` | Only in `brandGradient` with `accent` (icon tiles) |
| `onAccent` | `#12080D` | Text/icons on accent (white on coral fails contrast) |
| text | white / 62% / 40% | Primary / secondary / tertiary |
| `danger` | `#FF736B` | Error notices |

## Spacing, radius, size

- **Spacing** (4-pt grid): `xs 4 · s 8 · m 12 · l 16` (screen margin) `· xl 24 · xxl 32` (between shelves).
- **Radius:** `s 6` row artwork · `m 10` cards · `l 16` hero artwork, mini player. Artists are circles.
- **Sizes:** row art 48 · mini-player art 40 · card 148 · hero 220 · **minimum tap target 44**.

## Type

System font. Roles: screen title (large title, bold) · section title
(`.sectionTitle()`: title2 bold) · row title (`.rowTitle()`: body, 1 line) ·
row subtitle (`.rowSubtitle()`: caption, secondary) · card title (subheadline medium, 2 lines).

## Components

| Component | Use |
|---|---|
| `.buttonStyle(.primary)` | The main action (Play). One per screen. |
| `.buttonStyle(.secondary)` | Supporting actions (Shuffle, Radio, Charts). |
| `ChipStyle(selected:)` | Filters, moods, toggles like Autoplay. |
| `Artwork` | Every thumbnail (square, circle for artists, placeholder built in). |
| `SongRow` | Every song in every list (now-playing marker, like/download badges, ••• menu). |
| `IconTile` + `LibraryRow` | Library entries. |
| `Notice` | Errors and "offline" notes. Never bare red text. |
| `.themedList()` / `.screenBackground()` / `.themedRow()` | Standard screen and row backgrounds. |
| `MiniPlayer` | Floating card with a progress line; opens Now Playing. |

## Rules of thumb

- New screen: `.themedList()` or `.screenBackground()`, margins `Space.l`.
- Icon-only buttons need a 44-pt frame and an `accessibilityLabel`.
- Don't introduce a new color or size; add a token to `Theme` if one is truly missing.
- `SpeedDial`: 3×3 grid of square tiles at the top of Home (most played, then liked). Title sits on a bottom scrim; coral marks the playing tile.
