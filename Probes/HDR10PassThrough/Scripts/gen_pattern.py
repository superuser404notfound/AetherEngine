#!/usr/bin/env python3
"""The HDR10 pass-through pattern: raw 3840x2160 yuv420p10le frames, BT.2020, PQ, video range, on stdout.

    gen_pattern.py FRAMES FPS_NUM FPS_DEN | ffmpeg -f rawvideo -pix_fmt yuv420p10le -s 3840x2160 ...

What is on screen:
- a row of grey patches at known brightness (0.1 to 10000 nit), each labelled with its value. A television
  that tone-maps by the metadata it received clips or rolls off the row at a different patch for a master
  of 1000 nit (the clip's own) than for one of 777 nit (the probe's), so the row is a second witness next
  to the info screen;
- a 777 and a 1000 nit marker patch, side by side, for the same comparison by eye;
- a bar that steps one position per frame across the bottom, and the frame number in digits: a skipped
  or repeated frame shows as a jump or a stall of the bar when the screen is filmed.

The patches and markers drift on a small circle (radius 8 pixels, one turn every 20 seconds), so an OLED
panel never holds one still picture for long. Every patch keeps a black border wider than the radius.

Needs numpy.
"""
import math
import sys

import numpy as np

W, H = 3840, 2160

# SMPTE ST 2084 inverse EOTF.
M1, M2 = 2610 / 16384, 2523 / 4096 * 128
C1, C2, C3 = 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32


def pq_code(nits):
    """10-bit video-range luma code for a grey of `nits`."""
    y = (max(nits, 0.0) / 10000.0) ** M1
    e = ((C1 + C2 * y) / (1 + C3 * y)) ** M2
    return int(round(64 + 876 * e))


# 5x7 digits plus '.', one string per row.
FONT = {
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
}


def draw_text(plane, text, x, y, scale, code):
    """Writes `text` into the luma plane with its top-left corner at (x, y)."""
    for i, ch in enumerate(text):
        glyph = FONT[ch]
        for row, bits in enumerate(glyph):
            for col, bit in enumerate(bits):
                if bit == "1":
                    px = x + (i * 6 + col) * scale
                    py = y + row * scale
                    plane[py:py + scale, px:px + scale] = code


PATCHES = [0.1, 1, 5, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 1000, 1500, 2000, 4000, 10000]
BLACK = pq_code(0)
LABEL = pq_code(100)
BAR_TOP, BAR_HEIGHT, BAR_WIDTH = 1880, 160, 48
DRIFT_RADIUS, DRIFT_SECONDS = 8, 20


def static_planes():
    y = np.full((H, W), BLACK, dtype=np.uint16)
    pw = W // len(PATCHES)
    for i, nits in enumerate(PATCHES):
        y[240:840, i * pw + 8:(i + 1) * pw - 8] = pq_code(nits)
        text = f"{nits:g}"
        draw_text(y, text, i * pw + (pw - len(text) * 6 * 5) // 2, 880, 5, LABEL)
    # The two markers the probe's metadata and the clip's own sit on.
    y[1100:1700, 1080:1800] = pq_code(777)
    y[1100:1700, 2040:2760] = pq_code(1000)
    draw_text(y, "777", 1260, 1730, 10, LABEL)
    draw_text(y, "1000", 2220, 1730, 10, LABEL)
    u = np.full((H // 2, W // 2), 512, dtype=np.uint16)
    return y, u


def main():
    frames = int(sys.argv[1])
    fps = int(sys.argv[2]) / int(sys.argv[3])
    base_y, chroma = static_planes()
    chroma_bytes = chroma.astype("<u2").tobytes()
    # Two seconds per sweep across the width.
    step = max(1, int((W - BAR_WIDTH) / (2 * fps)))
    out = sys.stdout.buffer
    for n in range(frames):
        # The static part drifts; np.roll wraps only black, since no patch comes within 8 px of an edge.
        angle = 2 * math.pi * n / (DRIFT_SECONDS * fps)
        dx = int(round(DRIFT_RADIUS * math.cos(angle)))
        dy = int(round(DRIFT_RADIUS * math.sin(angle)))
        y = np.roll(base_y, (dy, dx), axis=(0, 1))
        y[BAR_TOP:H, :] = BLACK
        x = (n * step) % (W - BAR_WIDTH)
        y[BAR_TOP:BAR_TOP + BAR_HEIGHT, x:x + BAR_WIDTH] = LABEL
        draw_text(y, f"{n:05d}", 60, 1960, 12, LABEL)
        out.write(y.astype("<u2").tobytes())
        out.write(chroma_bytes)
        out.write(chroma_bytes)
    out.flush()


if __name__ == "__main__":
    main()
