#!/usr/bin/env python3
"""Generate Smart Badge app icon in all required iOS sizes."""

import os
import math
from PIL import Image, ImageDraw, ImageFont

OUTPUT_DIR = os.path.join(
    os.path.dirname(__file__),
    "../ios/SmartBadgeApp/SmartBadgeApp/Assets.xcassets/AppIcon.appiconset"
)

# iOS icon sizes: filename -> (points, scale factor -> pixels)
SIZES = {
    "icon-20@2x.png":   (20, 2),   # 40x40
    "icon-20@3x.png":   (20, 3),   # 60x60
    "icon-29@2x.png":   (29, 2),   # 58x58
    "icon-29@3x.png":   (29, 3),   # 87x87
    "icon-40@2x.png":   (40, 2),   # 80x80
    "icon-40@3x.png":   (40, 3),   # 120x120
    "icon-60@2x.png":   (60, 2),   # 120x120
    "icon-60@3x.png":   (60, 3),   # 180x180
    "icon-1024.png":    (1024, 1), # 1024x1024 (App Store)
}

# Color palette
BG_TOP = (72, 49, 212)       # deep indigo
BG_BOTTOM = (128, 55, 200)   # purple
BADGE_COLOR = (255, 255, 255, 230)  # semi-transparent white
ACCENT_COLOR = (255, 200, 60)  # warm gold for detail


def gradient_bg(draw, size, top_color, bottom_color):
    """Draw vertical gradient background."""
    w, h = size
    for y in range(h):
        ratio = y / h
        r = int(top_color[0] + (bottom_color[0] - top_color[0]) * ratio)
        g = int(top_color[1] + (bottom_color[1] - top_color[1]) * ratio)
        b = int(top_color[2] + (bottom_color[2] - top_color[2]) * ratio)
        draw.line([(0, y), (w, y)], fill=(r, g, b))


def draw_badge(draw, size, margin_ratio=0.18):
    """Draw a badge/ID card shape outline."""
    w, h = size
    mx = w * margin_ratio
    my = h * margin_ratio
    r = min(w, h) * 0.12  # corner radius

    # Badge body (rounded rect)
    draw.rounded_rectangle(
        [mx, my, w - mx, h - my],
        radius=r,
        outline=BADGE_COLOR,
        width=max(2, int(w * 0.012))
    )

    # Inner horizontal line (like a badge card divider)
    mid_y = h * 0.52
    line_margin = w * 0.22
    draw.line(
        [(line_margin, mid_y), (w - line_margin, mid_y)],
        fill=BADGE_COLOR,
        width=max(1, int(w * 0.006))
    )

    # Top accent (gold bar at top, like a lanyard clip)
    clip_w = w * 0.18
    clip_h = h * 0.03
    clip_x = w / 2 - clip_w / 2
    clip_y = my - clip_h
    draw.rounded_rectangle(
        [clip_x, clip_y, clip_x + clip_w, clip_y + clip_h],
        radius=clip_h / 2,
        fill=ACCENT_COLOR
    )


def draw_text(draw, size):
    """Draw '智能工牌' text in the badge."""
    w, h = size
    font_size = int(w * 0.14)

    # Try to load a system font
    font = None
    for font_path in [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/Library/Fonts/Arial Unicode.ttf",
    ]:
        if os.path.exists(font_path):
            try:
                font = ImageFont.truetype(font_path, font_size)
                break
            except Exception:
                continue

    if font is None:
        font = ImageFont.load_default()

    # Main label at top half
    text1 = "智能工牌"
    bbox1 = draw.textbbox((0, 0), text1, font=font)
    tw1 = bbox1[2] - bbox1[0]
    th1 = bbox1[3] - bbox1[1]
    tx1 = (w - tw1) / 2
    ty1 = h * 0.22 - th1 / 2
    draw.text((tx1, ty1), text1, fill=(255, 255, 255, 240), font=font)

    # Subtitle at bottom half
    font_size2 = int(w * 0.07)
    font2 = None
    for font_path in [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
    ]:
        if os.path.exists(font_path):
            try:
                font2 = ImageFont.truetype(font_path, font_size2)
                break
            except Exception:
                continue
    if font2 is None:
        font2 = font

    text2 = "Smart Badge"
    bbox2 = draw.textbbox((0, 0), text2, font=font2)
    tw2 = bbox2[2] - bbox2[0]
    tx2 = (w - tw2) / 2
    ty2 = h * 0.35
    draw.text((tx2, ty2), text2, fill=(255, 255, 255, 180), font=font2)


def add_shine(draw, size):
    """Subtle top-left shine for depth."""
    w, h = size
    cx, cy = w * 0.35, h * 0.35
    max_r = max(w, h) * 0.6
    for i in range(30):
        ratio = i / 30
        r = max_r * (1 - ratio)
        alpha = int(25 * (1 - ratio))
        draw.ellipse(
            [cx - r, cy - r, cx + r, cy + r],
            fill=(255, 255, 255, alpha)
        )


def generate_icons():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Generate master 1024x1024 first
    base_size = 1024
    img = Image.new("RGBA", (base_size, base_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    gradient_bg(draw, (base_size, base_size), BG_TOP, BG_BOTTOM)
    add_shine(draw, (base_size, base_size))
    draw_badge(draw, (base_size, base_size))
    draw_text(draw, (base_size, base_size))

    # Save all sizes
    for filename, (pts, scale) in SIZES.items():
        px = pts * scale
        if px == base_size:
            resized = img
        else:
            resized = img.resize((px, px), Image.LANCZOS)
        filepath = os.path.join(OUTPUT_DIR, filename)
        resized.save(filepath, "PNG")
        print(f"  ✓ {filename} ({px}x{px})")

    # Write Contents.json
    contents = {
        "images": [
            {"size": "20x20", "idiom": "iphone", "filename": "icon-40@2x.png", "scale": "2x"},
            {"size": "20x20", "idiom": "iphone", "filename": "icon-60@3x.png", "scale": "3x"},
            {"size": "29x29", "idiom": "iphone", "filename": "icon-58@2x.png", "scale": "2x"},
            {"size": "29x29", "idiom": "iphone", "filename": "icon-87@3x.png", "scale": "3x"},
            {"size": "40x40", "idiom": "iphone", "filename": "icon-80@2x.png", "scale": "2x"},
            {"size": "40x40", "idiom": "iphone", "filename": "icon-120@3x.png", "scale": "3x"},
            {"size": "60x60", "idiom": "iphone", "filename": "icon-120@2x.png", "scale": "2x"},
            {"size": "60x60", "idiom": "iphone", "filename": "icon-180@3x.png", "scale": "3x"},
            {"size": "1024x1024", "idiom": "ios-marketing", "filename": "icon-1024.png", "scale": "1x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }

    # Fix filenames to match actual generated files
    contents["images"] = [
        {"size": "20x20", "idiom": "iphone", "filename": "icon-20@2x.png", "scale": "2x"},
        {"size": "20x20", "idiom": "iphone", "filename": "icon-20@3x.png", "scale": "3x"},
        {"size": "29x29", "idiom": "iphone", "filename": "icon-29@2x.png", "scale": "2x"},
        {"size": "29x29", "idiom": "iphone", "filename": "icon-29@3x.png", "scale": "3x"},
        {"size": "40x40", "idiom": "iphone", "filename": "icon-40@2x.png", "scale": "2x"},
        {"size": "40x40", "idiom": "iphone", "filename": "icon-40@3x.png", "scale": "3x"},
        {"size": "60x60", "idiom": "iphone", "filename": "icon-60@2x.png", "scale": "2x"},
        {"size": "60x60", "idiom": "iphone", "filename": "icon-60@3x.png", "scale": "3x"},
        {"size": "1024x1024", "idiom": "ios-marketing", "filename": "icon-1024.png", "scale": "1x"},
    ]

    import json
    json_path = os.path.join(OUTPUT_DIR, "Contents.json")
    with open(json_path, "w") as f:
        json.dump(contents, f, indent=2)
    print(f"  ✓ Contents.json")

    # Also write AccentColor
    accent_dir = os.path.join(
        os.path.dirname(__file__),
        "../ios/SmartBadgeApp/SmartBadgeApp/Assets.xcassets/AccentColor.colorset"
    )
    os.makedirs(accent_dir, exist_ok=True)
    accent_json = {
        "colors": [
            {
                "idiom": "universal",
                "color": {
                    "color-space": "srgb",
                    "components": {
                        "red": "0x48",
                        "green": "0x31",
                        "blue": "0xD4",
                        "alpha": "1.000"
                    }
                }
            }
        ],
        "info": {"author": "xcode", "version": 1}
    }
    with open(os.path.join(accent_dir, "Contents.json"), "w") as f:
        json.dump(accent_json, f, indent=2)
    print(f"  ✓ AccentColor")

    print(f"\n✅ All icons generated to: {OUTPUT_DIR}")


if __name__ == "__main__":
    generate_icons()
