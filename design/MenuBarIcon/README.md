# Auster Menu Bar Icons

Monochrome **template** icons for the `MenuBarExtra` status item: the **same
three-gust wind glyph as the app icon** (identical construction and
proportions, optically adjusted for 18 pt — slightly thicker strokes and wider
line spacing), with state conveyed by a badge in a knocked-out circle at
bottom-right. In badge states the middle gust drops its curl so the badge gets
clean space; idle shows the full glyph.

| File | State | Badge |
|---|---|---|
| `menubar-idle.svg` | up to date | none |
| `menubar-syncing.svg` | transferring/indexing | spinner arc |
| `menubar-paused.svg` | paused by user | pause bars |
| `menubar-error.svg` | sync issues / fatal error | exclamation |
| `menubar-offline.svg` | connecting / no network | hollow ring |

## Usage (Phase 8, Task 8.1)

- Add each SVG to `Assets.xcassets` as a symbol/image set with
  **Render As: Template Image** — the system then tints for menu bar
  light/dark/tinted automatically. Never hard-code colors.
- Artwork is drawn on a 36×36 viewBox intended for **18×18 pt** display
  (`Image(...).resizable().frame(width: 18, height: 18)` or an `NSImage` with
  `isTemplate = true` and 18 pt size).
- State mapping lives in `StatusIcon` (see `docs/plan/08-app-ui.md`):
  idle → `menubar-idle`, syncing → `menubar-syncing`, paused →
  `menubar-paused`, sync-error/fatal → `menubar-error`, connecting →
  `menubar-offline`. The "error badge only when idle" rule from the UX spec
  still applies.
- The syncing state may stay static in v1; if animation is wanted later,
  rotate only the badge's spinner arc.

## Regenerating

`python3 generate.py` rewrites all five SVGs. Geometry (stroke width, gust
runs, curl radius/sweep, badge center/radii) is parametrized at the top.
