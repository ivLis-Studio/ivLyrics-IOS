#!/usr/bin/env python3
"""Cut the rendered PiP frame out of each pip capture (the black letterbox around it is the preview)."""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent / "captures"
for path in sorted(ROOT.glob("*-pip*.png")):
    if path.stem.endswith("-frame"):
        continue
    image = Image.open(path).convert("RGB")
    width, height = image.size
    gray = image.convert("L")
    skip = int(height * 0.08)  # status bar and home indicator
    rows = [y for y in range(skip, height - skip) if gray.crop((0, y, width, y + 1)).getextrema()[1] > 12]
    if not rows:
        continue
    top, bottom = rows[0], rows[-1] + 1
    cols = [x for x in range(width) if gray.crop((x, top, x + 1, bottom)).getextrema()[1] > 12]
    frame = image.crop((cols[0], top, cols[-1] + 1, bottom))
    name = path.stem.replace("-outer", "").replace("-inner", "").replace("-pip", "-pip-frame") + ".png"
    frame.save(ROOT / name)
    print(name, frame.size)

