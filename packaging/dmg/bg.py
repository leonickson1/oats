#!/usr/bin/env python3
# Oats DMG background: 660x440 pt, drawn at 2x then downscaled for the 1x rep.
from PIL import Image, ImageDraw, ImageFont

W, H = 660, 480  # bottom ~96pt is plain cream: slack for Finder tab-bar chrome
S = 4  # supersample; output at 2x and 1x
img = Image.new("RGB", (W * S, H * S), "#faf9f5")
d = ImageDraw.Draw(img)

INK = (28, 28, 28)
GREY = (111, 111, 108)
PANEL = (240, 239, 233)
ACCENT = (229, 71, 15)      # site accent #e5470f
LIGHT = (213, 210, 202)     # warm light grey for the first chevron


def serif(size_pt, weight=600):
    f = ImageFont.truetype("/System/Library/Fonts/NewYork.ttf", size_pt * S)
    try:
        f.set_variation_by_axes([size_pt, weight, 0])  # axes: opsz, wght, GRAD
    except Exception:
        f = ImageFont.truetype("/System/Library/Fonts/Supplemental/Georgia Bold.ttf", size_pt * S)
    return f


def sans(size_pt, weight=400):
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size_pt * S)
        f.set_variation_by_axes([100, size_pt, 400, weight])  # axes: wdth, opsz, GRAD, wght
        return f
    except Exception:
        return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size_pt * S)


def center_text(y_pt, text, font, fill):
    box = d.textbbox((0, 0), text, font=font)
    x = (W * S - (box[2] - box[0])) / 2 - box[0]
    d.text((x, y_pt * S - box[1]), text, font=font, fill=fill)


# Title
center_text(50, "Drag to Install", serif(44, 640), INK)

# Chevrons between the two icons (icon centers land at x=180 and x=480, y=235)
def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

cy = 215
size = 15          # half-height of chevron in pt
for i in range(5):
    cx = 274 + i * 26
    col = lerp(LIGHT, ACCENT, i / 4)
    pts = [((cx - 6) * S, (cy - size) * S), ((cx + 7) * S, cy * S), ((cx - 6) * S, (cy + size) * S)]
    d.line(pts, fill=col, width=5 * S, joint="curve")
    # round the stroke ends
    r = (5 * S) / 2 - 0.5
    for p in (pts[0], pts[2]):
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=col)

# Bottom note box
bx0, by0, bx1, by1 = 82 * S, 322 * S, 578 * S, 384 * S
d.rounded_rectangle([bx0, by0, bx1, by1], radius=14 * S, fill=PANEL)
center_text(335, "Updating Oats? Drag it in again and choose Replace.", sans(13, 620), INK)
center_text(356, "Your notes and settings stay on your Mac.", sans(12, 430), GREY)

img.resize((W * 2, H * 2), Image.LANCZOS).save("bg@2x.png")
img.resize((W, H), Image.LANCZOS).save("bg.png")
print("ok")
