#!/usr/bin/env python3
"""Generate Auster app icon layers: a wind glyph drafted from clean primitives.

Each gust is a horizontal straight segment joined tangent-continuously to a
perfect circular-arc curl, stroked at uniform width with round caps, and
emitted as a filled outline (parallel lines + concentric arcs + semicircle
caps). No freeform curves — geometry stays crisp like a drafted symbol.
"""
import math, os

W = 1024          # canvas
HALF = 38         # half stroke width (stroke = 76)

def centerline(y, x0, x1, curl=None, arc_steps=140):
    """Horizontal line (x0..x1 at height y), then optional curl.
    curl = (radius R of the centerline circle, sweep degrees, 'up'|'down')."""
    pts = [(x0 + (x1 - x0) * i / 60, y) for i in range(61)]
    if curl:
        R, sweep, direction = curl
        if direction == "up":
            c = (x1, y - R)                 # circle above; enter at angle +90°, a decreasing (CCW visual)
            for i in range(1, arc_steps + 1):
                a = math.radians(90 - sweep * i / arc_steps)
                pts.append((c[0] + R * math.cos(a), c[1] + R * math.sin(a)))
        else:
            c = (x1, y + R)                 # circle below; enter at angle -90°, a increasing (CW visual)
            for i in range(1, arc_steps + 1):
                a = math.radians(-90 + sweep * i / arc_steps)
                pts.append((c[0] + R * math.cos(a), c[1] + R * math.sin(a)))
    return pts

def outline(pts, h=HALF):
    """Uniform-width offset outline with semicircular caps."""
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
    def cap(center, start_pt, a_out, steps=40):
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

def svg(d, fill="#FFFFFF"):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" '
            f'viewBox="0 0 {W} {W}">\n  <path d="{d}" fill="{fill}"/>\n</svg>\n')

# ---- composition ----------------------------------------------------------
# Three horizontal gusts, uniform 140 px rhythm, centered as a group.
DX, DY = 42, 30   # shifts to optically center the glyph
back  = outline(centerline(372 + DY, 218 + DX, 588 + DX, curl=(88, 252, "up")))
mid   = outline(centerline(512 + DY, 168 + DX, 668 + DX, curl=(100, 252, "down")))
front = outline(centerline(652 + DY, 218 + DX, 452 + DX, curl=None))

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "AppIcon.icon", "Assets")
os.makedirs(out, exist_ok=True)
open(f"{out}/wind-back.svg", "w").write(svg(back))
open(f"{out}/wind-middle.svg", "w").write(svg(mid))
open(f"{out}/wind-front.svg", "w").write(svg(front))

preview = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">
  <defs>
    <clipPath id="squircle"><rect x="0" y="0" width="{W}" height="{W}" rx="232"/></clipPath>
  </defs>
  <g clip-path="url(#squircle)">
    <rect width="{W}" height="{W}" fill="#0E5A50"/>
    <path d="{back}" fill="#FFFFFF" opacity="0.72"/>
    <path d="{mid}" fill="#FFFFFF" opacity="1.0"/>
    <path d="{front}" fill="#FFFFFF" opacity="0.85"/>
  </g>
</svg>
'''
open(os.path.join(here, "preview.svg"), "w").write(preview)
print("ok")
