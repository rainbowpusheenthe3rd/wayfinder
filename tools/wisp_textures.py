"""Render Wayfinder's night-elf wisp into a sprite sheet, in the same camera and frame order as the arrow
(tools/wayfinder_textures.py), so the addon picks frames exactly as it does for the arrow.

The wisp floats above the ground: a bright core with a moonlit halo at the front, and a comet tail of fading motes
streaming back the way you came, swaying a little. Frame i is turned i/FRAMES of a turn counter-clockwise, so
frame 0 heads away from you. Light is drawn as glow (colour and alpha from gaussian splats); the addon blends it
additively, over a faint dark copy so it reads on bright ground. Also writes mote.tga, one soft dot for the motes
that circle it. Usage: python tools/wisp_textures.py addon/Wayfinder
"""
import math
import struct
import sys
from pathlib import Path

import numpy as np

from wayfinder_textures import COLS, DIST, FOV, FRAMES, PITCH

CELL, SS = 128, 2
CORE = np.array([0.92, 1.0, 1.0])        # nearly white
HALO = np.array([0.45, 0.95, 0.85])      # moonlit teal, the night elf wisp
TAIL = np.array([0.35, 0.7, 1.0])        # cooling to blue along the tail


def project(points, theta):
    """World points (x right, y up, z forward) turned by theta, to pixel x, y and depth, as the arrow's camera."""
    n = CELL * SS
    c, s = math.cos(theta), math.sin(theta)
    cp, sp = math.cos(PITCH), math.sin(PITCH)
    f = 0.5 * n / math.tan(FOV / 2)
    w = np.stack([points[:, 0] * c - points[:, 2] * s, points[:, 1], points[:, 0] * s + points[:, 2] * c], axis=1)
    cam = np.array([0.0, sp * DIST, -cp * DIST])
    v = w - cam
    cy = v[:, 1] * cp + v[:, 2] * sp
    cz = -v[:, 1] * sp + v[:, 2] * cp
    return n / 2 + f * v[:, 0] / cz, n / 2 - f * cy / cz, cz


def splat(img, alpha, x, y, radius, colour, strength):
    n = img.shape[0]
    r = int(radius * 3) + 1
    x0, x1, y0, y1 = max(0, int(x) - r), min(n, int(x) + r + 1), max(0, int(y) - r), min(n, int(y) + r + 1)
    if x0 >= x1 or y0 >= y1:
        return
    ys, xs = np.mgrid[y0:y1, x0:x1] + 0.5
    g = strength * np.exp(-((xs - x) ** 2 + (ys - y) ** 2) / (2 * radius ** 2))
    img[y0:y1, x0:x1] += g[..., None] * colour
    alpha[y0:y1, x0:x1] += g


def frame(theta):
    n = CELL * SS
    img = np.zeros((n, n, 3))
    alpha = np.zeros((n, n))
    # the tail: motes from just behind the head back along -z, falling slightly and swaying
    k = 34
    t = np.linspace(0, 1, k)
    tail = np.stack([0.14 * np.sin(t * 8.0) * t, 0.42 - 0.26 * t, 0.45 - 1.6 * t], axis=1)
    px, py, pz = project(tail, theta)
    scale = n / 128 * (DIST / pz)
    for i in range(k)[::-1]:  # far motes first
        colour = TAIL * t[i] + HALO * (1 - t[i])
        sparkle = 1.6 if i % 5 == 2 else 1.0  # every fifth mote a little brighter: sparkle in the tail
        splat(img, alpha, px[i], py[i], (5.0 - 3.6 * t[i]) * scale[i], colour, 0.5 * sparkle * (1 - t[i]) ** 1.3)
    # the head: a wide halo, then a tight bright core
    hx, hy, hz = project(np.array([[0.0, 0.45, 0.55]]), theta)
    s = n / 128 * (DIST / hz[0])
    splat(img, alpha, hx[0], hy[0], 13 * s, HALO, 0.38)
    splat(img, alpha, hx[0], hy[0], 6 * s, (HALO + CORE) / 2, 0.55)
    splat(img, alpha, hx[0], hy[0], 2.2 * s, CORE, 0.9)
    alpha = np.clip(alpha, 0, 1)
    rgb = img / np.maximum(alpha[..., None], 1e-6)   # unpremultiply: colour where it glows, alpha for how much
    rgb = np.clip(rgb, 0, 1)
    down = lambda a: a.reshape(CELL, SS, CELL, SS, *a.shape[2:]).mean(axis=(1, 3))  # noqa: E731
    return down(rgb * alpha[..., None]) / np.maximum(down(alpha)[..., None], 1e-6), down(alpha)


def tga(path, rgb, alpha):
    h, w = alpha.shape
    head = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28)
    v = (np.clip(rgb, 0, 1) * 255).round().astype(np.uint8)
    a = (np.clip(alpha, 0, 1) * 255).round().astype(np.uint8)
    path.write_bytes(head + np.dstack([v[..., 2], v[..., 1], v[..., 0], a]).tobytes())  # BGRA


def main(out: Path):
    size = COLS * CELL
    rgb_sheet, a_sheet = np.zeros((size, size, 3)), np.zeros((size, size))
    for i in range(FRAMES):
        rgb, a = frame(2 * math.pi * i / FRAMES)
        r, c = divmod(i, COLS)
        rgb_sheet[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL] = rgb
        a_sheet[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL] = a
    tga(out / "wisp.tga", rgb_sheet, a_sheet)
    m = 32
    ys, xs = np.mgrid[0:m, 0:m] + 0.5
    g = np.exp(-((xs - m / 2) ** 2 + (ys - m / 2) ** 2) / (2 * 4.5 ** 2))
    tga(out / "mote.tga", np.dstack([g * 0 + 0.85, g * 0 + 1.0, g * 0 + 0.95]), g)
    print("wrote", out / "wisp.tga", "and", out / "mote.tga")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
