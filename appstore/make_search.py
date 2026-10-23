"""App Store search-results artwork, 3:2.

    python3 make_search.py                      # both scales, default copy
    python3 make_search.py "Headline." "Sub."

Rendered at 3840 x 2560 and halved to 1920 x 1280, so the small one is the same
composition with 2x supersampled text. Two phones, not three: at 1920 wide a third
makes every screen unreadable.
"""
import sys
from pathlib import Path

from PIL import Image

HERE = str(Path(__file__).resolve().parent) + "/"
sys.path.insert(0, HERE)

import make_header as mh  # noqa: E402

HEADLINE = sys.argv[1] if len(sys.argv) > 1 else mh.HEADLINE
SUB = sys.argv[2] if len(sys.argv) > 2 else mh.SUB
OUTDIR = sys.argv[3] if len(sys.argv) > 3 else HERE

mh.compose(3840, 2560, 780, ["01-today.png", "04-progress.png"],
           [0, -60], 60, 300, 230, 150, 108,
           "search-3840x2560.png", HEADLINE, SUB, OUTDIR)

big = Image.open(OUTDIR + "search-3840x2560.png")
big.resize((1920, 1280), Image.LANCZOS).save(OUTDIR + "search-1920x1280.png")
print("search-1920x1280.png (1920, 1280)")
