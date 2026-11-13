#!/usr/bin/env python3
"""The HDR10 pass-through pattern: raw 3840x2160 yuv420p10le frames, BT.2020, PQ, video range, on stdout.

    gen_pattern.py FRAMES FPS_NUM FPS_DEN | ffmpeg -f rawvideo -pix_fmt yuv420p10le -s 3840x2160 ...

What is on screen:
- a row of small grey patches at known brightness (0.1 to 10000 nit), each labelled with its value;
- a 777 and a 1000 nit marker, side by side;
- a bar that steps one position per frame across the bottom, and the frame number in digits: a skipped
  or repeated frame shows as a jump or a stall of the bar when the screen is filmed.

Everything bright is small: about 4% of the screen is above 100 nit. An OLED lowers its peak when a
large part of the screen is bright, and a first version of this pattern (about 30% bright) brought a
77 inch LG G4 below 777 nit, so every patch above that looked the same whatever metadata arrived.

How the television tone-maps the upper patches depends on the metadata it received, so the row reads
differently with the clip's own metadata, with the probe's, and with none. Compare arms against each
other (photos from one spot, exposure locked), not against an expectation of one television's curve.

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


# Patch row: small patches centred in 18 equal cells. Markers: two small squares. About 4% of the
# screen is above 100 nit.
PATCH_TOP, PATCH_HEIGHT, PATCH_WIDTH = 300, 160, 120
MARKER_TOP, MARKER_HEIGHT, MARKER_WIDTH = 1100, 200, 240


def static_planes():
    y = np.full((H, W), BLACK, dtype=np.uint16)
    pw = W // len(PATCHES)
    for i, nits in enumerate(PATCHES):
        x = i * pw + (pw - PATCH_WIDTH) // 2
        y[PATCH_TOP:PATCH_TOP + PATCH_HEIGHT, x:x + PATCH_WIDTH] = pq_code(nits)
        text = f"{nits:g}"
        draw_text(y, text, i * pw + (pw - len(text) * 6 * 5) // 2, PATCH_TOP + PATCH_HEIGHT + 30, 5, LABEL)
    for nits, centre in ((777, 1680), (1000, 2160)):
        x = centre - MARKER_WIDTH // 2
        y[MARKER_TOP:MARKER_TOP + MARKER_HEIGHT, x:x + MARKER_WIDTH] = pq_code(nits)
        text = f"{nits}"
        draw_text(y, text, centre - len(text) * 6 * 8 // 2, MARKER_TOP + MARKER_HEIGHT + 30, 8, LABEL)
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
