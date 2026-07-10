#!/usr/bin/env python3
"""mkmsgpng.py — pre-render the miyoomini phase-message PNGs (#19).

On miyoomini the ONLY safe way to put a transient status line on screen is MinUI's
show.elf drawing a full-screen PNG (self-exits, nothing to kill — see the #19 fix in
Update Lodor.pak/launch.sh). This renders the FIXED message set for the pak phase
keys, 640x480, black background (compresses to a few KB), white DejaVu Sans ~30px,
word-wrapped, with a small "Lodor" header.

The generated PNGs are COMMITTED under each pak's res/ so release builds never need
PIL. Re-run only when the message set changes:

    docker run --rm -v <repo>:/repo python:3-slim sh -c \
        'pip install -q pillow && apt-get update -qq && apt-get install -y -qq fonts-dejavu-core && \
         python3 /repo/release/mkmsgpng.py --root /repo'
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 640, 480
BODY_PX = 30
HEADER_PX = 18
MARGIN = 40

# phase-key -> (pak-relative output path, message)
MESSAGES = {
    "lodoros/paks/Update Lodor.pak/res/connecting-wifi.png": "Connecting to Wi-Fi...",
    "lodoros/paks/Update Lodor.pak/res/checking-updates.png": "Checking for updates...",
    "lodoros/paks/Update Lodor.pak/res/downloading-update.png": "Downloading update...",
    "lodoros/paks/Reset WiFi.pak/res/resetting-wifi.png": "Resetting Wi-Fi...",
}

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "DejaVuSans.ttf",
]


def load_font(px):
    for cand in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(cand, px)
        except OSError:
            continue
    sys.exit("mkmsgpng: DejaVu Sans not found (install fonts-dejavu) — refusing to fall back to a bitmap font")


def wrap(draw, text, font, max_w):
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=font) <= max_w or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def render(msg, body, header):
    img = Image.new("L", (W, H), 0)  # grayscale, black bg — tiny PNGs
    d = ImageDraw.Draw(img)
    d.text((MARGIN, MARGIN), "Lodor", font=header, fill=170)
    lines = wrap(d, msg, body, W - 2 * MARGIN)
    lh = int(BODY_PX * 1.35)
    y = (H - lh * len(lines)) // 2
    for ln in lines:
        d.text((MARGIN, y), ln, font=body, fill=255)
        y += lh
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."),
                    help="repo root (default: parent of this script)")
    args = ap.parse_args()
    body, header = load_font(BODY_PX), load_font(HEADER_PX)
    for rel, msg in MESSAGES.items():
        out = os.path.join(args.root, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        render(msg, body, header).save(out, optimize=True)
        print(f"  wrote {rel} ({os.path.getsize(out)} bytes): {msg!r}")


if __name__ == "__main__":
    main()
