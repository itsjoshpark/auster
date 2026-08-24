#!/usr/bin/env python3
"""Generate Auster menu bar template icons (monochrome, alpha-only).

The same three-gust wind glyph as the app icon (identical construction and
proportions, scaled to a 36x36 viewBox for 18x18 pt display), with two optical
adjustments for menu bar size: proportionally thicker strokes and slightly
wider line spacing so gusts stay separated on non-retina displays. Ship as
template assets so AppKit tints them for menu bar light/dark.
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
BADGE_C = (28.5, 27.0)
BADGE_R = 8.3         # knockout radius
BADGE_r = 6.6         # badge artwork radius
# Badge artwork was drafted against a 5.4 radius; K rescales it so the badge
# size is one number to change.
K = BADGE_r / 5.4

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

# The app icon's three-gust composition (see ../AppIcon/generate.py), scaled
# by 36/1024 with optical tweaks: stroke width 3.4 (vs 2.67 true-scale) and
# vertical rhythm 5.6 (vs 4.92 true-scale).
S = 36.0 / 1024.0
# The gusts sit on the canvas centre. The glyph's mass is above its middle gust
# (the top gust's curl reaches higher than the short bottom run drops), so CY is
# carried below 18 to bring the group's own centre onto it.
CY = 20.4          # optical center height of the middle gust
RHYTHM = 5.6
STROKE_H = 1.45    # half stroke width
GUST_TOP = outline(centerline(CY - RHYTHM, 260 * S, 630 * S, curl=(88 * S, 252, "up")), h=STROKE_H)
GUST_BOT = outline(centerline(CY + RHYTHM, 260 * S, 494 * S, curl=None), h=STROKE_H)
# Idle carries the full app-icon glyph. Badge states drop the middle gust's
# curl (the knockout would amputate it into an orphaned fragment) and stop its
# plain run short of the badge, so it ends on its own round cap rather than on a
# slice taken out of it by the mask.
def clear_x(y, gap=0.35):
    """Where a run at height y has to stop to leave the knockout alone."""
    dy = abs(BADGE_C[1] - y)
    need = BADGE_R + STROKE_H + gap
    if need <= dy:
        return None
    return BADGE_C[0] - math.sqrt(need * need - dy * dy)

MID_X1 = 710 * S
MID_X1_BADGED = min(MID_X1, clear_x(CY) or MID_X1)

GUSTS_FULL = [GUST_TOP, outline(centerline(CY, 210 * S, MID_X1, curl=(100 * S, 252, "down")), h=STROKE_H), GUST_BOT]
GUSTS_BADGED = [GUST_TOP, outline(centerline(CY, 210 * S, MID_X1_BADGED, curl=None), h=STROKE_H), GUST_BOT]

def svg(body, mask_badge=False):
    mask = ""
    use_mask = ""
    if mask_badge:
        mask = (f'<mask id="knockout"><rect width="{VB}" height="{VB}" fill="white"/>'
                f'<circle cx="{BADGE_C[0]}" cy="{BADGE_C[1]}" r="{BADGE_R}" fill="black"/></mask>')
        use_mask = ' mask="url(#knockout)"'
    gusts = GUSTS_BADGED if mask_badge else GUSTS_FULL
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{VB:.0f}" height="{VB:.0f}" '
            f'viewBox="0 0 {VB:.0f} {VB:.0f}">\n<defs>{mask}</defs>\n'
            f'<g fill="#000000"{use_mask}>' + "".join(f'<path d="{d}"/>' for d in gusts) + '</g>\n'
            f'{body}</svg>\n')

cx, cy, r = *BADGE_C, BADGE_r
badges = {
    "idle": ("", False),
    "syncing": (f'<path d="{arc_stroke((cx, cy), r - 1.4 * K, -80, 155, 1.5 * K)}" fill="#000"/>', True),
    "paused": (f'<rect x="{cx-3.1*K:.1f}" y="{cy-3.6*K:.1f}" width="{2.2*K:.1f}" height="{7.2*K:.1f}" rx="{1.1*K:.1f}" fill="#000"/>'
               f'<rect x="{cx+0.9*K:.1f}" y="{cy-3.6*K:.1f}" width="{2.2*K:.1f}" height="{7.2*K:.1f}" rx="{1.1*K:.1f}" fill="#000"/>', True),
    "error": (f'<rect x="{cx-1.3*K:.1f}" y="{cy-4.4*K:.1f}" width="{2.6*K:.1f}" height="{5.4*K:.1f}" rx="{1.3*K:.1f}" fill="#000"/>'
              f'<circle cx="{cx}" cy="{cy+3.2*K:.1f}" r="{1.5*K:.1f}" fill="#000"/>', True),
    "offline": (f'<circle cx="{cx}" cy="{cy}" r="{r-1.2*K:.1f}" fill="none" stroke="#000" stroke-width="{1.8*K:.1f}"/>', True),
}

here = os.path.dirname(os.path.abspath(__file__))
for name, (body, masked) in badges.items():
    open(os.path.join(here, f"menubar-{name}.svg"), "w").write(svg(body, masked))
print("ok")
