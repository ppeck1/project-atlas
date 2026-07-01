"""Generate a multi-resolution app_icon.ico from a source PNG."""
import argparse
from pathlib import Path

from PIL import Image

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DEST = PROJECT_ROOT / "windows" / "runner" / "resources" / "app_icon.ico"

SIZES = [16, 24, 32, 48, 64, 128, 256]

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source_png", type=Path, help="Path to a 1024px source PNG")
parser.add_argument(
    "--dest",
    type=Path,
    default=DEFAULT_DEST,
    help="Destination .ico path",
)
args = parser.parse_args()

# Save from the full-size source so Pillow downscales correctly
img = Image.open(args.source_png).convert("RGBA")
args.dest.parent.mkdir(parents=True, exist_ok=True)
img.save(args.dest, format="ICO", sizes=[(s, s) for s in SIZES])

print(f"Written {args.dest}")
print(f"Size: {args.dest.stat().st_size} bytes")
for s in SIZES:
    print(f"  {s}x{s}")
