"""Render Wayfinder's 3D arrow into sprite sheets: arrow.tga (lit, white, tinted in game) and edge.tga (the 1px
rim just outside each frame's silhouette, tinted black in game).

The arrow lies on the ground in front of you and is seen from behind and above, like the game camera. Frame i
has the arrow turned i/FRAMES of a full turn counter-clockwise from straight ahead (seen from above), the same
sense as the addon's relative bearing, so frame 0 points away from you and frame FRAMES/2 points back at you.
Sheets are COLS x COLS frames of CELL px, uncompressed 32-bit TGA, as WoW loads them.
"""
import math
import struct
import sys
from pathlib import Path

import numpy as np

FRAMES, COLS, CELL, SS = 64, 8, 128, 3
PITCH = math.radians(38)     # camera looks down this much
DIST, FOV = 3.6, math.radians(40)
LIGHT = np.array([-0.45, 0.85, 0.35])  # from above, front-left
# outline on the ground (x right, z forward), tip forward; a raised spine runs down the middle
OUTLINE = [(0.0, 1.0), (0.62, -0.25), (0.24, -0.08), (0.24, -0.85), (-0.24, -0.85), (-0.24, -0.08), (-0.62, -0.25)]
THICK, RIDGE = 0.10, 0.16
SPINE = [(0.0, 1.0), (0.0, -0.08), (0.0, -0.85)]


def mesh():
    """Triangles (3x3 arrays): the top as facets from the outline to the spine, the sides, and the base."""
    top = lambda x, z: np.array([x, THICK, z])                     # noqa: E731
    spine = lambda x, z: np.array([x, THICK + RIDGE * (1 - 0.35 * max(0, -z)), z])  # noqa: E731
    base = lambda x, z: np.array([x, 0.0, z])                      # noqa: E731
    tris = []
    n = len(OUTLINE)
    # each outline edge joins to the nearest spine point along z, giving a ridged, faceted top
    def ridge_for(z):
        return min(SPINE, key=lambda p: abs(p[1] - z))
    for i in range(n):
        a, b = OUTLINE[i], OUTLINE[(i + 1) % n]
        ra, rb = ridge_for(a[1]), ridge_for(b[1])
        tris.append([top(*a), top(*b), spine(*rb)])
        if ra != rb:
            tris.append([top(*a), spine(*rb), spine(*ra)])
        tris.append([base(*a), base(*b), top(*b)])   # side wall
        tris.append([base(*a), top(*b), top(*a)])
    return [np.array(t) for t in tris]


def render(theta):
    """Coverage and brightness for one frame."""
    n = CELL * SS
    cov = np.zeros((n, n))
    shade = np.zeros((n, n))
    depth = np.full((n, n), np.inf)
    c, s = math.cos(theta), math.sin(theta)
    cp, sp = math.cos(PITCH), math.sin(PITCH)
    f = 0.5 * n / math.tan(FOV / 2)
    ys, xs = np.mgrid[0:n, 0:n] + 0.5
    for tri in mesh():
        # turn counter-clockwise seen from above: forward (+z) goes to the left (-x)
        w = np.stack([tri[:, 0] * c - tri[:, 2] * s, tri[:, 1], tri[:, 0] * s + tri[:, 2] * c], axis=1)
        normal = np.cross(w[1] - w[0], w[2] - w[0])
        if np.linalg.norm(normal) < 1e-9:
            continue
        normal /= np.linalg.norm(normal)
        # camera behind (-z) and above, looking forward and down at the arrow's centre:
        # forward = (0, -sin p, cos p), up = (0, cos p, sin p), right = +x
        cam = np.array([0.0, sp * DIST, -cp * DIST])
        v = w - cam
        cy = v[:, 1] * cp + v[:, 2] * sp
        cz = -v[:, 1] * sp + v[:, 2] * cp
        px = n / 2 + f * v[:, 0] / cz
        py = n / 2 - f * cy / cz
        if np.dot(normal, cam - w.mean(axis=0)) < 0:  # light the side facing the camera
            normal = -normal
        light = 0.35 + 0.65 * max(0.0, float(np.dot(normal, LIGHT / np.linalg.norm(LIGHT))))
        x0, x1 = int(max(0, px.min())), int(min(n, px.max() + 1))
        y0, y1 = int(max(0, py.min())), int(min(n, py.max() + 1))
        if x0 >= x1 or y0 >= y1:
            continue
        X, Y = xs[y0:y1, x0:x1], ys[y0:y1, x0:x1]
        (ax, bx, cx), (ay, by, cyy) = px, py
        d = (by - cyy) * (ax - cx) + (cx - bx) * (ay - cyy)
        if abs(d) < 1e-9:
            continue
        l1 = ((by - cyy) * (X - cx) + (cx - bx) * (Y - cyy)) / d
        l2 = ((cyy - ay) * (X - cx) + (ax - cx) * (Y - cyy)) / d
        l3 = 1 - l1 - l2
        inside = (l1 >= 0) & (l2 >= 0) & (l3 >= 0)
        z = l1 * cz[0] + l2 * cz[1] + l3 * cz[2]
        win = inside & (z < depth[y0:y1, x0:x1])
        depth[y0:y1, x0:x1][win] = z[win]
        shade[y0:y1, x0:x1][win] = light
        cov[y0:y1, x0:x1][win] = 1
    # downsample the supersampled frame
    cov = cov.reshape(CELL, SS, CELL, SS).mean(axis=(1, 3))
    lit = shade.reshape(CELL, SS, CELL, SS).sum(axis=(1, 3)) / np.maximum(1, (shade > 0).reshape(
        CELL, SS, CELL, SS).sum(axis=(1, 3)))
    return cov, lit


def rim(cov):
    pad = np.pad(cov, 1)
    near = np.max([pad[1 + dy:1 + dy + CELL, 1 + dx:1 + dx + CELL] for dy in (-1, 0, 1) for dx in (-1, 0, 1)], axis=0)
    return np.clip(near - cov, 0, 1)


def tga(path, rgb, alpha):
    size = COLS * CELL
    head = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x28)  # top-left origin, 8 alpha bits
    v = (np.clip(rgb, 0, 1) * 255).round().astype(np.uint8)
    a = (np.clip(alpha, 0, 1) * 255).round().astype(np.uint8)
    path.write_bytes(head + np.dstack([v, v, v, a]).tobytes())  # BGRA, grey so B = G = R


def main(out: Path):
    size = COLS * CELL
    lit_sheet, cov_sheet, rim_sheet = (np.zeros((size, size)) for _ in range(3))
    for i in range(FRAMES):
        cov, lit = render(2 * math.pi * i / FRAMES)
        r, c = divmod(i, COLS)
        sl = (slice(r * CELL, (r + 1) * CELL), slice(c * CELL, (c + 1) * CELL))
        cov_sheet[sl], lit_sheet[sl], rim_sheet[sl] = cov, lit, rim(cov)
    tga(out / "arrow.tga", lit_sheet, cov_sheet)
    tga(out / "edge.tga", np.ones_like(rim_sheet), rim_sheet)
    print(f"wrote {FRAMES} frames to", out / "arrow.tga", out / "edge.tga")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
