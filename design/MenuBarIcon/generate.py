#!/usr/bin/env python3
"""Generate Auster menu bar template icons (monochrome, alpha-only).

A simplified two-gust wind mark on a 36x36 viewBox (drawn for 18x18 pt; ship
as template PDF/SVG assets so AppKit tints them for menu bar light/dark).
State variants carve a knockout circle bottom-right and draw a badge in it:

  idle     — plain mark
  syncing  — 270° spinner arc badge
  paused   — pause bars badge
  error    — exclamation badge
  offline  — hollow ring badge

Same drafted-primitive construction as the app icon (straight runs joined
tangent-continuously to circular-arc curls, uniform width, round caps).
"""
import math, os

VB = 36.0
HALF = 2.5            # half stroke width (stroke = 5)
BADGE_C = (28.5, 26.5)
BADGE_R = 7.2         # knockout radius
BADGE_r = 5.4         # badge artwork radius

def centerline(y, x0, x1, curl=None, arc_steps=90):
    pts = [(x0 + (x1 - x0) * i / 40, y) for i in range(41)]
    if curl:
        R, sweep, direction = curl
        if direction == "up":
            c = (x1, y - R)
            for i in range(1, arc_steps + 1):
                a = math.radians(90 - sweep * i / arc_steps)
                pts.append((c[0] + R * math.cos(a), c[1] + R * math.sin(a)))
        else:
            c = (x1, y + R)
            for i in range(1, arc_steps + 1):
                a = math.radians(-90 + sweep * i / arc_steps)
                pts.append((c[0] + R * math.cos(a), c[1] + R * math.sin(a)))
    return pts

def outline(pts, h=HALF):
    n = len(pts)
    left, right, tang = [], [], []
    for i, (x, y) in enumerate(pts):
        j0, j1 = max(0, i - 1), min(n - 1, i + 1)
        tx, ty = pts[j1][0] - pts[j0][0], pts[j1][1] - pts[j0][1]
        L = math.hypot(tx, ty) or 1.0
        tx, ty = tx / L, ty / L
        tang.append((tx, ty))
        left.append((x - ty * h, y + tx * h))
        right.append((x + ty * h, y - tx * h))
    def cap(center, start_pt, a_out, steps=24):
        r = math.hypot(start_pt[0] - center[0], start_pt[1] - center[1])
        a0 = math.atan2(start_pt[1] - center[1], start_pt[0] - center[0])
        d = 1 if ((a_out - a0) % (2 * math.pi)) < math.pi else -1
        return [(center[0] + r * math.cos(a0 + d * math.pi * i / steps),
                 center[1] + r * math.sin(a0 + d * math.pi * i / steps))
                for i in range(steps + 1)]
    a_end = math.atan2(tang[-1][1], tang[-1][0])
    a_start = math.atan2(-tang[0][1], -tang[0][0])
    poly = left + cap(pts[-1], left[-1], a_end) + right[::-1] + cap(pts[0], right[0], a_start)
    return "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in poly) + " Z"

def arc_stroke(c, R, a0_deg, a1_deg, h, steps=60):
    """Outlined circular arc stroke with round caps."""
    pts = []
    for i in range(steps + 1):
        a = math.radians(a0_deg + (a1_deg - a0_deg) * i / steps)
        pts.append((c[0] + R * math.cos(a), c[1] + R * math.sin(a)))
    return outline(pts, h)

# The two-gust mark: curl on the top gust; bottom gust is a plain run that
# stops short of the bottom-right badge corner.
GUST_TOP = outline(centerline(13.5, 4.0, 22.0, curl=(6.2, 252, "up")))
GUST_BOT = outline(centerline(24.5, 4.0, 26.0, curl=None))

def svg(body, mask_badge=False):
    mask = ""
    use_mask = ""
    if mask_badge:
        mask = (f'<mask id="knockout"><rect width="{VB}" height="{VB}" fill="white"/>'
                f'<circle cx="{BADGE_C[0]}" cy="{BADGE_C[1]}" r="{BADGE_R}" fill="black"/></mask>')
        use_mask = ' mask="url(#knockout)"'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{VB:.0f}" height="{VB:.0f}" '
            f'viewBox="0 0 {VB:.0f} {VB:.0f}">\n<defs>{mask}</defs>\n'
            f'<g fill="#000000"{use_mask}><path d="{GUST_TOP}"/><path d="{GUST_BOT}"/></g>\n'
            f'{body}</svg>\n')

cx, cy, r = *BADGE_C, BADGE_r
badges = {
    "idle": ("", False),
    "syncing": (f'<path d="{arc_stroke((cx, cy), r - 1.4, -80, 155, 1.5)}" fill="#000"/>', True),
    "paused": (f'<rect x="{cx-3.1:.1f}" y="{cy-3.6:.1f}" width="2.2" height="7.2" rx="1.1" fill="#000"/>'
               f'<rect x="{cx+0.9:.1f}" y="{cy-3.6:.1f}" width="2.2" height="7.2" rx="1.1" fill="#000"/>', True),
    "error": (f'<rect x="{cx-1.3:.1f}" y="{cy-4.4:.1f}" width="2.6" height="5.4" rx="1.3" fill="#000"/>'
              f'<circle cx="{cx}" cy="{cy+3.2:.1f}" r="1.5" fill="#000"/>', True),
    "offline": (f'<circle cx="{cx}" cy="{cy}" r="{r-1.2:.1f}" fill="none" stroke="#000" stroke-width="1.8"/>', True),
}

here = os.path.dirname(os.path.abspath(__file__))
for name, (body, masked) in badges.items():
    open(os.path.join(here, f"menubar-{name}.svg"), "w").write(svg(body, masked))
print("ok")
