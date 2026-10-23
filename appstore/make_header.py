"""App Store header artwork, built from the committed screenshots in this folder.

    python3 make_header.py                 # both sizes, default headline
    python3 make_header.py "Headline."     # both sizes, other headline

Needs Pillow. The iPhone product page shows only the middle of the header: about the
centre 54% of the width and the top 64% of the height of the 16:9 image (measured on
App Store Connect's preview, 2026-10-23), with the Dynamic Island and the back and
share buttons over the top 11%, and the icon card over everything below. So the
headline and the phones are centred, the headline sits just under the island, and
only the phones' lower halves and the background reach the parts iPad and Mac add.
No price or "free" in the art: Apple's asset guidelines don't allow pricing.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = str(Path(__file__).resolve().parent) + "/"
SHOTS = OUT = HERE

HEADLINE = "Train with your coach."

# The app icon's own gradient, top to bottom.
TOP = (253, 118, 70)
BOTTOM = (216, 44, 81)
INK = (255, 255, 255)
BEZEL = (24, 24, 27)
SHADOW = (90, 0, 20)


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


def gradient(w, h):
    column = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return column.resize((w, h))


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

    blur = round(width * 0.06)
    # Room for the blur on every side, and more below, where the shadow is offset.
    canvas = Image.new("RGBA", (fw + blur * 6, fh + blur * 8), (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [blur * 3, blur * 3 + blur, blur * 3 + fw, blur * 3 + fh + blur], radius + pad, fill=SHADOW + (110,)
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(frame, (blur * 3, blur * 3))
    return canvas, blur * 3


def compose(w, h, name, headline=None, outdir=None):
    """Every measure is a fraction of the height, so the 16:9 and 21:9 files share one centred layout."""
    img = gradient(w, h).convert("RGBA")
    d = ImageDraw.Draw(img)
    cx = w // 2

    # Headline: just under the Dynamic Island and between the back and share buttons.
    head = fitted(headline or HEADLINE, round(h * 0.056), "Bold", round(h * 0.80))
    box = d.textbbox((0, 0), headline or HEADLINE, font=head)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], round(h * 0.135)), headline or HEADLINE, font=head, fill=INK)

    # Program and Progress behind, Today in front: the eye lands on today's session.
    side_w, mid_w = round(h * 0.215), round(h * 0.245)
    spread = round(h * 0.245)
    for shot, dx, top, width in [("05-program.png", -spread, 0.300, side_w),
                                 ("04-progress.png", spread, 0.300, side_w),
                                 ("01-today.png", 0, 0.255, mid_w)]:
        dev, inset = device(SHOTS + shot, width)
        img.alpha_composite(dev, (cx + dx - dev.width // 2, round(h * top) - inset))

    img.convert("RGB").save((outdir or OUT) + name)
    print(name, img.size, "| headline", head.size)


if __name__ == "__main__":
    import sys

    headline = sys.argv[1] if len(sys.argv) > 1 else None
    compose(5244, 2950, "header-5244x2950.png", headline)
    compose(3840, 1646, "header-3840x1646.png", headline)
