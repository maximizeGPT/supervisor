# Supervisor brand assets

This directory holds the canonical brand exports for Supervisor v0.1.x. The
build pipeline reads from here — don't move files without updating
`Scripts/build-app.sh` and `Sources/SupervisorStatusBar/Resources/`.

## Files

| File                          | Use                                                                                          |
|-------------------------------|----------------------------------------------------------------------------------------------|
| `supervisor-statusbar.svg`    | 16×16 monochrome template image. Source for `Sources/SupervisorStatusBar/Resources/StatusBarIcon.{svg,png,@2x.png}`, loaded as an `NSImage` with `isTemplate = true` for menu-bar light/dark theming. |
| `supervisor-appicon-1024.png` | 1024×1024 RGBA master with the macOS squircle baked in. `Scripts/make-icns.sh` rescales it through the standard 10-size iconset into `AppIcon.icns`. |
| `supervisor-wordmark.svg`     | Three lockup variants in one file: `#lockup-horizontal`, `#lockup-stacked`, `#wordmark-only`. All glyphs are outlined paths from Inter Medium with -2% tracking — zero font dependency at render time. Used in docs, GitHub social card, and the (future v0.1.7+) expanded panel. |
| `AppIcon.icns`                | Generated artifact (committed). Reflects the current state of `supervisor-appicon-1024.png`; `make-icns.sh` rebuilds it whenever the master is newer. The intermediate `AppIcon.iconset/` directory is `.gitignore`d. |
| `supervisor-tiktok-endcard.{svg,png}` | 1080×1920 (9:16) vertical end card for TikTok / Reels / Shorts. Stacked lockup on the dark Ink→Ink-deep ground, mono tagline, and a `6.26.26` launch-date headline in `Signal` green. Built as a minimal hold frame for a voiceover — no buttons/tap targets (there are none in-feed). Symbol + wordmark are the canonical outlined paths; only the tagline/date use a system sans/mono fallback. Regenerate the PNG from the SVG. |

## Palette

Hex values, mapped to their role in the system:

| Color      | Hex       | Role                                                                |
|------------|-----------|---------------------------------------------------------------------|
| Ink        | `#0E0F11` | Primary text, wordmark fill                                         |
| Paper      | `#F7F6F2` | Primary background (light mode), social-card background pairing    |
| Ink-deep   | `#1A1B1E` | Squircle gradient bottom stop on the app icon                       |
| Paper-warm | `#EDEDEB` | Secondary surface, dividers                                         |
| Signal     | `#2D7A4E` | Brand green. Symbol fill on app icon + wordmark. Hover-dot "running" color. |
| Mute       | `#A6A6A2` | Secondary text, deemphasis                                          |

## Type system

| Role               | Family         | Weights        | Notes                                                          |
|--------------------|----------------|----------------|----------------------------------------------------------------|
| UI + body          | Inter          | 400, 500, 600  | Cap at 600 — heavier weights drift toward marketing            |
| Code + timestamps  | JetBrains Mono | 400, 500       | Trace-log viewer, evidence UUIDs, anything monospaced          |
| Wordmark           | Inter Medium   | 500            | Outlined to paths in `supervisor-wordmark.svg` — no runtime    |
|                    |                |                | font dependency                                                |

## Symbol construction

The V1 symbol is defined on a 16-unit grid for sharp pixel snapping at the
16×16 menu-bar size:

- **Outer frame**: 14u × 14u square outline, centered, 1u stroke
- **Inner mass**: 4×4u filled square in the **upper-right corner**, with
  **1u gap to the top** and **1u gap to the right** of the inner area
- At the 16-unit master scale, the inner mass sits at coordinates
  (9, 3) – (12, 6) inclusive

The asymmetric upper-right placement is what makes the mark read as a
"flag" / "marker" rather than a generic framed dot — Supervisor's job is
flagging an action before it lands, and the symbol carries that meaning.

## Updating brand assets

1. Edit / re-export from Claude Design (or whatever the active source-of-truth tool is) and replace files under `branding/`. Don't touch the generated `Sources/SupervisorStatusBar/Resources/StatusBarIcon.*` files directly — they should be regenerated from the SVG.
2. For the status-bar fallbacks, re-run:
   ```bash
   cp branding/supervisor-statusbar.svg Sources/SupervisorStatusBar/Resources/StatusBarIcon.svg
   sips -s format png -z 16 16 branding/supervisor-statusbar.svg --out Sources/SupervisorStatusBar/Resources/StatusBarIcon.png
   sips -s format png -z 32 32 branding/supervisor-statusbar.svg --out Sources/SupervisorStatusBar/Resources/StatusBarIcon@2x.png
   ```
3. For the app icon, `Scripts/build-app.sh` re-runs `make-icns.sh` automatically on the next build whenever the master is newer than `AppIcon.icns`.
4. Visual-smoke: build via `./Scripts/build-app.sh debug`, launch each
   `.app`, confirm the menu-bar icon and the Finder/Dock icons all show
   the updated symbol.
