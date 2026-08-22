#!/usr/bin/env python3
"""Generate Auster app icon layer SVGs: three tapered wind swooshes."""
import math, os

W = 1024

def bez(p0, p1, p2, t):
    x = (1-t)**2*p0[0] + 2*(1-t)*t*p1[0] + t**2*p2[0]
    y = (1-t)**2*p0[1] + 2*(1-t)*t*p1[1] + t**2*p2[1]
    return (x, y)

def sample_centerline(p0, ctrl, p1, curl=None, n=140):
    """Quad bezier sweep p0->p1, then optional curl arc (radius, degrees, dir)."""
    pts = [bez(p0, ctrl, p1, i/(n-1)) for i in range(n)]
    if curl:
        r, total_deg, d = curl
        tx = p1[0] - ctrl[0]; ty = p1[1] - ctrl[1]
        L = math.hypot(tx, ty); tx, ty = tx/L, ty/L
        nx, ny = -d*ty, d*tx
        cx, cy = p1[0] + r*nx, p1[1] + r*ny
        a0 = math.atan2(p1[1]-cy, p1[0]-cx)
        steps = 100
        for i in range(1, steps+1):
            a = a0 + d * math.radians(total_deg) * i/steps
            ri = r * (1 - 0.30*i/steps)
            pts.append((cx + ri*math.cos(a), cy + ri*math.sin(a)))
    return pts

def width_at(t, h):
    """Near-uniform width; gentle taper over last 35% to 45%, tiny ease at start."""
    w = h
    if t > 0.65:
        u = (t-0.65)/0.35
        w = h * (1 - 0.64*u**1.25)
    if t < 0.06:
        u = t/0.06
        w = min(w, h * (0.86 + 0.14*u))
    return w

def outline(pts, h):
    n = len(pts)
    left, right, tang = [], [], []
    for i, (x, y) in enumerate(pts):
        j0, j1 = max(0, i-1), min(n-1, i+1)
        tx, ty = pts[j1][0]-pts[j0][0], pts[j1][1]-pts[j0][1]
        L = math.hypot(tx, ty) or 1.0
        tx, ty = tx/L, ty/L
        tang.append((tx, ty))
        w = width_at(i/(n-1), h)
        left.append((x - ty*w, y + tx*w))
        right.append((x + ty*w, y - tx*w))
    def cap(center, start_pt, a_out, steps=28):
        """Semicircle from start_pt around center, passing through direction a_out."""
        r = math.hypot(start_pt[0]-center[0], start_pt[1]-center[1])
        a0 = math.atan2(start_pt[1]-center[1], start_pt[0]-center[0])
        d = 1 if ((a_out - a0) % (2*math.pi)) < math.pi else -1
        return [(center[0]+r*math.cos(a0 + d*math.pi*i/steps),
                 center[1]+r*math.sin(a0 + d*math.pi*i/steps)) for i in range(steps+1)]
    a_end = math.atan2(tang[-1][1], tang[-1][0])          # outward at end = tangent
    a_start = math.atan2(-tang[0][1], -tang[0][0])        # outward at start = -tangent
    end_cap = cap(pts[-1], left[-1], a_end)
    start_cap = cap(pts[0], right[0], a_start)
    poly = left + end_cap + right[::-1] + start_cap
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in poly) + " Z"

def svg(d, fill="#FFFFFF"):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" '
            f'viewBox="0 0 {W} {W}">\n  <path d="{d}" fill="{fill}"/>\n</svg>\n')

# --- the three gusts (canvas 1024, glyph within ~208..816 square) ----------
back = outline(
    sample_centerline((252, 420), (520, 352), (740, 360), curl=None), h=37)
mid = outline(
    sample_centerline((206, 550), (560, 506), (700, 494), curl=(90, 236, +1)), h=44)
front = outline(
    sample_centerline((296, 678), (500, 660), (628, 626), curl=None), h=31)

out = os.path.join(os.path.dirname(__file__), "icon")
os.makedirs(out, exist_ok=True)
open(f"{out}/wind-back.svg", "w").write(svg(back))
open(f"{out}/wind-middle.svg", "w").write(svg(mid))
open(f"{out}/wind-front.svg", "w").write(svg(front))

preview = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5BBCE9"/>
      <stop offset="1" stop-color="#1C67B8"/>
    </linearGradient>
    <clipPath id="squircle"><rect x="0" y="0" width="{W}" height="{W}" rx="232"/></clipPath>
  </defs>
  <g clip-path="url(#squircle)">
    <rect width="{W}" height="{W}" fill="url(#bg)"/>
    <path d="{back}" fill="#FFFFFF" opacity="0.62"/>
    <path d="{mid}" fill="#FFFFFF" opacity="1.0"/>
    <path d="{front}" fill="#FFFFFF" opacity="0.80"/>
  </g>
</svg>
'''
open(f"{out}/preview.svg", "w").write(preview)
print("ok")
