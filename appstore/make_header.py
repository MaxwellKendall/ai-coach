"""App Store header artwork, built from the committed screenshots in this folder.

    python3 make_header.py                      # both sizes, default copy
    python3 make_header.py "Headline." "Sub."   # 16:9 only, with other copy

Needs Pillow. The text column is capped short of the phones and each line shrinks
to fit, so copy of any length stays clear of the devices.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = str(Path(__file__).resolve().parent) + "/"
SHOTS = OUT = HERE

WORDMARK = "barbrabell"
HEADLINE = "Train with your coach."
SUB = "Their plan, your sets — always free."

BG = (237, 237, 241)
INK = (0, 0, 0)
MUTED = (110, 110, 118)
BEZEL = (24, 24, 27)


def font(size, weight="Bold"):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def fitted(text, size, weight, max_w):
    """Largest font at or below `size` that keeps `text` inside max_w."""
    while size > 8:
        f = font(size, weight)
        if f.getbbox(text)[2] <= max_w:
            return f
        size -= 2
    return font(size, weight)


def device(path, width):
    """A screenshot in a dark bezel with a soft shadow, as RGBA."""
    shot = Image.open(path).convert("RGB")
    h = round(width * shot.height / shot.width)
    shot = shot.resize((width, h), Image.LANCZOS)

    radius = round(width * 0.125)
    mask = Image.new("L", (width, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, width - 1, h - 1], radius, fill=255)

    pad = max(2, round(width * 0.022))
    fw, fh = width + pad * 2, h + pad * 2
    frame = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle([0, 0, fw - 1, fh - 1], radius + pad, fill=BEZEL + (255,))
    frame.paste(shot, (pad, pad), mask)

    blur = round(width * 0.05)
    canvas = Image.new("RGBA", (fw + blur * 4, fh + blur * 4), (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [blur * 2, blur * 2 + blur, blur * 2 + fw, blur * 2 + fh + blur], radius + pad, fill=(0, 0, 0, 70)
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(frame, (blur * 2, blur * 2))
    return canvas


def compose(w, h, phone_w, shots, offsets, gap, text_x, wordmark_px, head_px, sub_px, name,
            headline=None, sub_text=None, outdir=None):
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)

    devices = [device(SHOTS + s, phone_w) for s in shots]
    total = sum(x.width for x in devices) - gap * (len(devices) - 1)
    left = w - round(w * 0.05) - total
    base = h // 2
    spots, x = [], left
    for dev, off in zip(devices, offsets):
        spots.append((dev, x, base - dev.height // 2 + off))
        x += dev.width - gap
    # Left-most in front, so the eye lands on Today first.
    for dev, px, py in reversed(spots):
        img.paste(dev, (px, py), dev)

    # The text never reaches the phones: its column stops a clear gutter short of them.
    max_w = left + round(phone_w * 0.05) - text_x - round(w * 0.045)
    headline = headline or HEADLINE
    sub_text = sub_text or SUB
    wm = fitted(WORDMARK, wordmark_px, "Bold", max_w)
    head = fitted(headline, head_px, "Bold", max_w)
    sub = fitted(sub_text, sub_px, "Regular", max_w)

    block = wordmark_px * 1.5 + head_px * 1.25 + sub_px * 1.5
    y = (h - block) / 2
    d.text((text_x, y), WORDMARK, font=wm, fill=INK)
    y += wordmark_px * 1.5
    d.text((text_x, y), headline, font=head, fill=INK)
    y += head_px * 1.25
    d.text((text_x, y), sub_text, font=sub, fill=MUTED)

    img.save((outdir or OUT) + name)
    print(name, img.size, "| headline", head.size, "sub", sub.size)


def wide(name, headline=None, sub_text=None, outdir=None):
    compose(5244, 2950, 830, ["01-today.png", "05-program.png", "04-progress.png"],
            [0, -70, 0], 70, 360, 260, 168, 122, name, headline, sub_text, outdir)


def ultrawide(name, headline=None, sub_text=None, outdir=None):
    compose(3840, 1646, 590, ["01-today.png", "05-program.png", "04-progress.png"],
            [0, -50, 0], 50, 270, 186, 120, 86, name, headline, sub_text, outdir)


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1:
        headline, sub_text = sys.argv[1], sys.argv[2]
        outdir = sys.argv[3] if len(sys.argv) > 3 else None
        name = sys.argv[4] if len(sys.argv) > 4 else "header-5244x2950.png"
        wide(name, headline, sub_text, outdir)
    else:
        wide("header-5244x2950.png")
        ultrawide("header-3840x1646.png")
