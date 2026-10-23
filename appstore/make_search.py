"""App Store search-results artwork, 3:2, in the header's centred layout (make_header.py).

    python3 make_search.py                 # both scales, default headline
    python3 make_search.py "Headline."

Rendered at 3840 x 2560 and halved to 1920 x 1280, so the small one is the same
composition with 2x supersampled text.
"""
import sys
from pathlib import Path

from PIL import Image

HERE = str(Path(__file__).resolve().parent) + "/"
sys.path.insert(0, HERE)

import make_header as mh  # noqa: E402

headline = sys.argv[1] if len(sys.argv) > 1 else None
mh.compose(3840, 2560, "search-3840x2560.png", headline)

big = Image.open(HERE + "search-3840x2560.png")
big.resize((1920, 1280), Image.LANCZOS).save(HERE + "search-1920x1280.png")
print("search-1920x1280.png (1920, 1280)")
