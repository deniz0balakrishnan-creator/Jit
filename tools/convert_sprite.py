"""Convert a pixel-art image on a flat background into a 32x32 sprite.

Usage: python3 tools/convert_sprite.py <input.png> <out32.png> <out_preview4x.png>

1. Crop away any bright footer (watermark bar).
2. Flood-fill the background from the four corners, stopping at the dark outline.
3. Detect the source pixel block size.
4. Sample the subject with nearest-neighbour onto a grid at most 32 cells on either side
   (one cell per source block when the subject fits, coarser cells when it doesn't).
5. Place it bottom-centred on a 32x32 transparent canvas.
"""
import sys
from collections import deque

import numpy as np
from PIL import Image

TOLERANCE = 9  # max per-channel distance from the corner colour that still counts as background


def crop_footer(a):
    bright_rows = np.where((a[..., :3].sum(2) > 600).mean(1) > 0.5)[0]
    return a[: bright_rows[0]] if len(bright_rows) else a


def flood_background(a):
    h, w, _ = a.shape
    bg = a[0, 0, :3].astype(int)
    near_bg = (np.abs(a[..., :3].astype(int) - bg).max(2) <= TOLERANCE)
    mask = np.zeros((h, w), bool)
    q = deque([(0, 0), (0, w - 1), (h - 1, 0), (h - 1, w - 1)])
    while q:
        y, x = q.popleft()
        if 0 <= y < h and 0 <= x < w and near_bg[y, x] and not mask[y, x]:
            mask[y, x] = True
            q.extend(((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)))
    return mask


def block_size(a, axis):
    """Smallest spacing (4..16 px) whose grid lines up with colour edges nearly as well as the best one.

    Multiples of the true block size also line up, so take the smallest strong candidate.
    """
    edges = np.abs(np.diff(a[..., :3].astype(int), axis=axis)).sum(2).sum(1 - axis)
    scores = []
    for b in np.arange(4, 16.01, 0.05):
        for off in np.arange(0, b, 0.25):
            idx = np.round(np.arange(off, len(edges), b)).astype(int)
            scores.append((edges[idx[idx < len(edges)]].mean(), b))
    top = max(s for s, _ in scores)
    return min(b for s, b in scores if s >= 0.9 * top)


def main(src, out32, out4x):
    a = crop_footer(np.asarray(Image.open(src).convert("RGBA")))
    a = a.copy()
    a[flood_background(a), 3] = 0
    b = (block_size(a, axis=1) + block_size(a, axis=0)) / 2
    rows, cols = np.where(a[..., 3] > 0)
    top, bottom, left, right = rows.min(), rows.max() + 1, cols.min(), cols.max() + 1
    native_w, native_h = round((right - left) / b), round((bottom - top) / b)
    gw, gh = native_w, native_h
    if max(gw, gh) > 32:
        k = 32 / max(gw, gh)
        gw, gh = max(1, round(gw * k)), max(1, round(gh * k))
    # Nearest-neighbour: take one source pixel per output cell. Small features (like eyes)
    # can fall between sample points, so try sub-cell phase offsets and keep the one that
    # preserves the most colour saturation.
    cw, ch = (right - left) / gw, (bottom - top) / gh
    best = None
    for dx in np.arange(-cw / 2, cw / 2, 0.5):
        for dy in np.arange(-ch / 2, ch / 2, 0.5):
            xs = np.clip((left + dx + (np.arange(gw) + 0.5) * cw).astype(int), 0, a.shape[1] - 1)
            ys = np.clip((top + dy + (np.arange(gh) + 0.5) * ch).astype(int), 0, a.shape[0] - 1)
            g = a[np.ix_(ys, xs)]
            rgb = g[..., :3].astype(int)
            saturation = ((rgb.max(2) - rgb.min(2)) * (g[..., 3] > 0)).sum()
            if best is None or saturation > best[0]:
                best = (saturation, g)
    grid = best[1]
    print(f"block size {b:.2f}px, subject {native_w}x{native_h} blocks -> {gw}x{gh} cells")
    canvas = np.zeros((32, 32, 4), np.uint8)
    x0 = (32 - gw) // 2
    canvas[32 - gh:, x0: x0 + gw] = grid
    img = Image.fromarray(canvas, "RGBA")
    img.save(out32)
    img.resize((128, 128), Image.NEAREST).save(out4x)


if __name__ == "__main__":
    main(*sys.argv[1:4])
