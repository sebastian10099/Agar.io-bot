#!/usr/bin/env python3
"""Zeichnet das Symbol von "GoMining Bot Pro" und schreibt Resources/AppIcon.icns.

Bewusst anders als das Symbol der alten App (dunkle Kachel mit Linie): blau-violette Kachel, Kerzen und ein
goldenes PRO-Schild, damit man die beiden Apps im Dock, im Launchpad und in Spotlight sofort unterscheidet.

    python3 tools/make_icon.py [Pfad/zu/einer/fetten/Schrift.otf]
"""
import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 1024
FONT_CANDIDATES = [
    "/usr/share/fonts/opentype/inter/Inter-ExtraBold.otf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
]


def gradient(size, top, bottom):
    img = Image.new("RGBA", (size, size))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(size):
            px[x, y] = c
    return img


def draw_icon(font_path):
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    inset, radius = 100, 185
    box = (inset, inset, S - inset, S - inset)

    # Schatten unter der Kachel
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 14, box[2], box[3] + 14), radius, fill=(0, 0, 0, 110))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))

    # Kachel mit Verlauf
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    canvas.paste(gradient(S, (37, 99, 235), (109, 40, 217)), (0, 0), mask)
    d = ImageDraw.Draw(canvas)

    # Hilfslinien
    for y in (330, 450, 570):
        d.line((190, y, 834, y), fill=(255, 255, 255, 45), width=4)

    # Kerzen (steigend): x, Docht oben/unten, Koerper oben/unten, gruen?
    candles = [
        (250, 520, 690, 560, 650, True),
        (360, 470, 640, 540, 610, False),
        (470, 400, 600, 430, 560, True),
        (580, 360, 540, 390, 480, False),
        (690, 250, 470, 280, 420, True),
    ]
    green, red = (74, 222, 128, 255), (248, 113, 113, 255)
    for x, wick_top, wick_bottom, body_top, body_bottom, up in candles:
        color = green if up else red
        d.line((x, wick_top, x, wick_bottom), fill=color, width=12)
        d.rounded_rectangle((x - 34, body_top, x + 34, body_bottom), 10, fill=color)

    # Goldenes PRO-Schild
    font = ImageFont.truetype(font_path, 150)
    text = "PRO"
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    tw, th = r - l, b - t
    pad_x, pad_y = 54, 30
    pill_w, pill_h = tw + 2 * pad_x, th + 2 * pad_y
    px0 = (S - pill_w) // 2
    py0 = 712
    d.rounded_rectangle((px0, py0, px0 + pill_w, py0 + pill_h), pill_h // 2, fill=(251, 191, 36, 255),
                        outline=(255, 255, 255, 255), width=10)
    d.text((px0 + pad_x - l, py0 + pad_y - t), text, font=font, fill=(30, 27, 75, 255))
    return canvas


def png(img, size):
    buf = io.BytesIO()
    img.resize((size, size), Image.LANCZOS).save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_icns(img, path):
    # Typ -> Kantenlaenge in Pixeln (PNG-Eintraege, macOS 10.7+)
    entries = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
               ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
    body = b""
    for kind, size in entries:
        data = png(img, size)
        body += kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    Path(path).write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


def main():
    root = Path(__file__).resolve().parent.parent
    fonts = sys.argv[1:] + FONT_CANDIDATES
    font_path = next((f for f in fonts if Path(f).exists()), None)
    if font_path is None:
        sys.exit("Keine fette Schrift gefunden – Pfad als Argument angeben.")
    icon = draw_icon(font_path)
    write_icns(icon, root / "Resources" / "AppIcon.icns")
    icon.save(root / "docs" / "icon.png")
    print("geschrieben:", root / "Resources" / "AppIcon.icns")


if __name__ == "__main__":
    main()
