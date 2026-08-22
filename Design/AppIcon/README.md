# Auster App Icon — Icon Composer Source

App icon artwork following the current HIG app-icon guidance (Liquid Glass,
guidance last refined 2026-06-08): layered, vector, unmasked square canvas,
no baked-in effects — the system supplies specular highlights, refraction, and
shadows.

**Concept:** Auster is the Latin south wind. Three tapered gusts — the longest
curling into a spiral — over an azure gradient. Filled overlapping shapes,
no text, legible down to 16 px.

## Files

| File | Purpose |
|---|---|
| `layers/wind-back.svg` | Rear (top) gust — 1024×1024, fully opaque white |
| `layers/wind-middle.svg` | Main gust with spiral — 1024×1024, fully opaque white |
| `layers/wind-front.svg` | Front (bottom) gust — 1024×1024, fully opaque white |
| `preview.svg` / `preview@512.png` | **Reference only** — composited approximation with gradient, opacities, and corner mask baked in. Never import these into Icon Composer. |
| `generate.py` | Regenerates the layer SVGs (parametric geometry) |

Layers are intentionally opaque and effect-free; opacity and all glass effects
are applied *inside* Icon Composer per the HIG ("import fully opaque layers and
adjust transparency in Icon Composer").

## Assembling in Icon Composer

Requires Xcode 26+ (Icon Composer ships with Xcode and at
developer.apple.com/icon-composer/).

1. New icon → platforms: **macOS** (single 1024×1024 square canvas; leave
   layers unmasked — the system applies the rounded-rectangle mask).
2. **Background**: use Icon Composer's built-in gradient (no image import):
   linear, top `#5BBCE9` → bottom `#1C67B8` (sRGB).
3. Import the three layer SVGs as foreground layers, ordered back → front:
   `wind-back` → `wind-middle` → `wind-front`. They are pre-positioned on the
   full canvas; do not scale or recenter.
4. Set layer opacity: `wind-back` **62%**, `wind-middle` **100%**,
   `wind-front` **80%**.
5. Leave the default Liquid Glass settings (specular on, default shadow).
   Do not add custom shadows/blurs/bevels.
6. **Appearances** (default / dark / clear / tinted): keep the white glyphs
   unchanged everywhere. For **dark**, override the background gradient to
   `#123E63` → `#0A2540`; let the system generate clear and tinted variants
   (white glyphs on system-provided material — verify legibility in preview).
7. Preview at small sizes (16/32 px) and in each appearance, then export the
   `.icon` file as `AppIcon.icon` into the Xcode project root and set it as the
   app icon in the target's Build Settings (Phase 1 scaffolding wires this up
   when the Xcode project exists).

## Regenerating / tweaking

`python3 generate.py` rewrites `layers/*.svg` and `preview.svg` (render the
PNG preview with `qlmanage -t -s 512 -o . preview.svg`). Stroke geometry
(sweep curves, spiral radius/angle, widths, taper) is parametrized at the
bottom of the script.

## HIG conformance checklist

- [x] 1024×1024 square, unmasked layers (system masks corners)
- [x] Layered: background + 3 foreground layers for depth
- [x] Vector (SVG), outlined filled shapes, no strokes, no text
- [x] Fully opaque layer files; transparency applied in Icon Composer
- [x] Hard, clearly defined edges (no feathering/soft edges)
- [x] No baked speculars, shadows, bevels, glows, or blurs
- [x] Simple background (gradient) defined in Icon Composer, not an image
- [x] Primary content centered; safe margins (~200 px) respected
- [x] Consistent core features across default/dark/clear/tinted appearances
- [x] Legible at small sizes (verified at 64 px and 16 px equivalents)
