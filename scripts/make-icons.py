"""Generates the menu bar template icons and the macOS app icon."""
import os
import subprocess
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
os.makedirs(ASSETS, exist_ok=True)

IDLE = [0.30, 0.55, 0.80, 0.55, 0.30]
ACTIVE = [0.55, 0.85, 1.00, 0.85, 0.55]


def bars(draw, box, heights, thickness, gap, fill):
    left, top, right, bottom = box
    width = len(heights) * thickness + (len(heights) - 1) * gap
    x = left + ((right - left) - width) / 2
    cy = (top + bottom) / 2
    lane = bottom - top
    for ratio in heights:
        h = max(thickness, lane * ratio)
        draw.rounded_rectangle(
            [x, cy - h / 2, x + thickness, cy + h / 2],
            radius=thickness / 2, fill=fill,
        )
        x += thickness + gap


def tray(name, heights, size):
    scale = size / 22
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    bars(draw, (0, 3 * scale, size, size - 3 * scale), heights,
         2.2 * scale, 2.2 * scale, (0, 0, 0, 255))
    img.save(os.path.join(ASSETS, name))


for name, heights in (("trayTemplate", IDLE), ("trayActiveTemplate", ACTIVE)):
    tray(f"{name}.png", heights, 22)
    tray(f"{name}@2x.png", heights, 44)

S = 1024
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gradient = Image.new("RGBA", (S, S))
for y in range(S):
    for_x = y / (S - 1)
    gradient.paste(
        (int(167 + (91 - 167) * for_x), int(139 + (108 - 139) * for_x), int(250 + (255 - 250) * for_x), 255),
        (0, y, S, y + 1),
    )
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=255)
icon.paste(gradient, (0, 0), mask)
bars(ImageDraw.Draw(icon), (S * 0.2, S * 0.28, S * 0.8, S * 0.72), ACTIVE,
     S * 0.062, S * 0.056, (255, 255, 255, 255))
icon.save(os.path.join(ASSETS, "icon.png"))

iconset = os.path.join(ASSETS, "icon.iconset")
os.makedirs(iconset, exist_ok=True)
for size in (16, 32, 64, 128, 256, 512, 1024):
    icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
    half = size // 2
    if half >= 16:
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{half}x{half}@2x.png"))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ASSETS, "icon.icns")], check=True)
subprocess.run(["rm", "-rf", iconset], check=True)
print("icons written to", ASSETS)
