"""Draw Jit's original placeholder sprite (a round lavender octopus) to sprites/placeholder.png.

Usage: python3 tools/make_placeholder.py
"""
from pathlib import Path

from PIL import Image

OUTLINE = (58, 28, 84, 255)
BODY = (167, 123, 214, 255)
SHADE = (124, 84, 170, 255)
LIGHT = (196, 160, 236, 255)
EYE = (255, 255, 255, 255)   # the brightest pixels: Jit closes these when it blinks
CHEEK = (240, 140, 170, 255)

W = H = 32


def in_head(x, y):
    return ((x + 0.5 - 16) / 11.5) ** 2 + ((y + 0.5 - 14) / 10) ** 2 <= 1


def in_tentacle(x, y):
    if not 20 <= y <= 31:
        return False
    for cx, sway in ((7, -1), (12, 1), (19, -1), (24, 1)):
        # Each tentacle drifts one pixel sideways over its lower half.
        offset = sway if y >= 27 else 0
        if cx - 1 + offset <= x <= cx + 1 + offset:
            return True
    return False


def main():
    shape = {(x, y) for x in range(W) for y in range(H) if in_head(x, y) or in_tentacle(x, y)}
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = img.load()
    for x, y in shape:
        edge = any((x + dx, y + dy) not in shape for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        if edge:
            px[x, y] = OUTLINE
        elif x + y > 36 or y > 26:
            px[x, y] = SHADE
        elif (x - 10) ** 2 + (y - 8) ** 2 <= 5:
            px[x, y] = LIGHT
        else:
            px[x, y] = BODY
    for ex in (11, 12, 19, 20):
        for ey in (13, 14, 15):
            px[ex, ey] = EYE
    for cx in (8, 9, 22, 23):
        px[cx, 18] = CHEEK
    out = Path(__file__).resolve().parent.parent / "sprites" / "placeholder.png"
    out.parent.mkdir(exist_ok=True)
    img.save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
