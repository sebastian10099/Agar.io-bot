#!/usr/bin/env python3
"""Draws the app icon and writes it as AppIcon.icns – pure Python, no Pillow,
no iconutil, so it also runs where macOS tools are missing.

  python3 tools/make_icon.py "New Token Bot.app/Contents/Resources/AppIcon.icns" [preview.png]

The icon: a rounded blue square with a rising white price line and a green
end dot – the same motif as the equity chart on the control page."""
from __future__ import annotations

import math
import struct
import sys
import zlib

BASE = 1024


def _clamp(x: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return lo if x < lo else hi if x > hi else x


def _rounded_rect_sdf(x: float, y: float, half: float, r: float) -> float:
    qx, qy = abs(x) - half + r, abs(y) - half + r
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def _seg_dist(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
    vx, vy, wx, wy = bx - ax, by - ay, px - ax, py - ay
    t = _clamp((vx * wx + vy * wy) / (vx * vx + vy * vy or 1.0))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


# polyline of the price path in icon units (0..1), y grows downwards
LINE = [(0.20, 0.70), (0.36, 0.60), (0.48, 0.66), (0.62, 0.44), (0.72, 0.50), (0.84, 0.30)]
LINE_W = 0.055
DOT_R = 0.065


def render(size: int) -> bytes:
    """RGBA bytes, drawn with analytic anti-aliasing (signed distances)."""
    out = bytearray()
    half = size * 0.5
    radius = size * 0.225                      # macOS-like corner
    aa = 1.0                                   # 1px smoothing band
    lw = LINE_W * size * 0.5
    for j in range(size):
        y = j + 0.5
        for i in range(size):
            x = i + 0.5
            d = _rounded_rect_sdf(x - half, y - half, half - size * 0.02, radius)
            alpha = _clamp(0.5 - d / aa)
            if alpha <= 0.0:
                out += b"\x00\x00\x00\x00"
                continue
            # vertical gradient blue -> deep blue, slight diagonal light
            t = _clamp(y / size * 0.9 + x / size * 0.1)
            r = 0x3b + (0x1e - 0x3b) * t
            g = 0x82 + (0x3a - 0x82) * t
            b = 0xf6 + (0x8a - 0xf6) * t
            # price line (white)
            dl = min(_seg_dist(x / size, y / size, *LINE[k], *LINE[k + 1]) for k in range(len(LINE) - 1)) * size
            cov = _clamp(0.5 - (dl - lw) / aa)
            # dot at the end (green) with a thin surface ring
            ex, ey = LINE[-1][0] * size, LINE[-1][1] * size
            dd = math.hypot(x - ex, y - ey)
            ring = _clamp(0.5 - (dd - DOT_R * size * 0.5 - size * 0.012) / aa)
            dot = _clamp(0.5 - (dd - DOT_R * size * 0.5) / aa)
            # composite: background -> line (white) -> ring (panel) -> dot (green)
            r = r + (255 - r) * cov; g = g + (255 - g) * cov; b = b + (255 - b) * cov
            r = r + (0x16 - r) * ring; g = g + (0x1b - g) * ring; b = b + (0x24 - b) * ring
            r = r + (0x3d - r) * dot; g = g + (0xdc - g) * dot; b = b + (0x84 - b) * dot
            a = int(round(alpha * 255))
            out += bytes((int(r), int(g), int(b), a))
    return bytes(out)


def png(size: int, rgba: bytes) -> bytes:
    raw = b"".join(b"\x00" + rgba[j * size * 4:(j + 1) * size * 4] for j in range(size))
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def downsample(rgba: bytes, size: int, factor: int) -> bytes:
    """Box filter by an integer factor (premultiplied, so edges stay clean)."""
    out = bytearray()
    small = size // factor
    for j in range(small):
        for i in range(small):
            r = g = b = a = 0.0
            for dj in range(factor):
                row = (j * factor + dj) * size * 4
                for di in range(factor):
                    o = row + (i * factor + di) * 4
                    pa = rgba[o + 3] / 255.0
                    r += rgba[o] * pa; g += rgba[o + 1] * pa; b += rgba[o + 2] * pa; a += pa
            n = factor * factor
            if a > 0:
                out += bytes((int(round(r / a)), int(round(g / a)), int(round(b / a)), int(round(a / n * 255))))
            else:
                out += b"\x00\x00\x00\x00"
    return bytes(out)


# icns entry types that carry PNG data, by pixel size
TYPES = {16: b"icp4", 32: b"icp5", 64: b"icp6", 128: b"ic07", 256: b"ic08", 512: b"ic09", 1024: b"ic10"}
RETINA = {32: b"ic11", 64: b"ic12", 256: b"ic13", 512: b"ic14"}   # same pixels, @2x semantics


def build(path: str, preview: str = "") -> None:
    base = render(BASE)
    images = {BASE: base}
    for f in (2, 4, 8, 16, 32, 64):
        images[BASE // f] = downsample(base, BASE, f)
    entries = b""
    for size, tag in sorted(TYPES.items()):
        data = png(size, images[size])
        entries += tag + struct.pack(">I", len(data) + 8) + data
        if size in RETINA:
            entries += RETINA[size] + struct.pack(">I", len(data) + 8) + data
    with open(path, "wb") as fh:
        fh.write(b"icns" + struct.pack(">I", len(entries) + 8) + entries)
    if preview:
        with open(preview, "wb") as fh:
            fh.write(png(256, images[256]))


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "")
    print("ok:", sys.argv[1])
