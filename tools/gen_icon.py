"""Generate a multi-resolution app_icon.ico from a source PNG."""
from pathlib import Path
from PIL import Image

SRC = Path(r"C:\Users\peckm\Downloads\project_atlas_icon_transparent_1024.png")
DEST = Path(r"B:\dev\Project_Atlas\project-atlas-main\windows\runner\resources\app_icon.ico")

SIZES = [16, 24, 32, 48, 64, 128, 256]

# Save from the full-size source so Pillow downscales correctly
img = Image.open(SRC).convert("RGBA")
img.save(DEST, format="ICO", sizes=[(s, s) for s in SIZES])

print(f"Written {DEST}")
print(f"Size: {DEST.stat().st_size} bytes")
for s in SIZES:
    print(f"  {s}x{s}")
