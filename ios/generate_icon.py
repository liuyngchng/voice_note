#!/usr/bin/env python3
"""
Generate a modern line-art style app icon for SmartBadge.
Style: light pastel colors, clean outline/line-art aesthetic,
badge motif with subtle audio + AI elements.
"""

from PIL import Image, ImageDraw
import math
import os

SIZE = 1024
OUTPUT_DIR = os.path.join(
    os.path.dirname(__file__),
    "SmartBadgeApp/SmartBadgeApp/Assets.xcassets/AppIcon.appiconset"
)

# ============================================================
# COLOR PALETTE — soft pastel lavender tones (RGB)
# ============================================================
C_BG          = (248, 246, 252)   # very light lavender-white bg
C_BADGE_FILL  = (238, 232, 248)   # soft lavender fill
C_BADGE_LINE  = (150, 132, 192)   # main outline — muted purple
C_INNER_LINE  = (175, 158, 210)   # inner border — lighter
C_CLIP_FILL   = (218, 208, 238)   # clip fill
C_CLIP_LINE   = (140, 120, 175)   # clip border
C_WAVE_FILL   = (172, 148, 208)   # waveform bar fill
C_WAVE_LINE   = (155, 130, 195)   # waveform outline
C_DOT         = (165, 138, 198)   # connected dots
C_SPARKLE     = (185, 162, 218)   # sparkle/star
C_PIN         = (162, 138, 195)   # location pin
C_GLOW        = (240, 234, 250)   # background glow


def rgba(rgb, a):
    """RGB + alpha (0-255)."""
    return rgb + (a,)


# ============================================================
# DRAWING PRIMITIVES
# ============================================================

def rrect(draw, xy, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(xy, radius=r, fill=fill, outline=outline, width=width)

def circ(draw, xy, r, fill=None, outline=None, width=1):
    x, y = xy
    draw.ellipse([x-r, y-r, x+r, y+r], fill=fill, outline=outline, width=width)

def ln(draw, p1, p2, color, width):
    draw.line([p1, p2], fill=color, width=width)

def bar_rounded(draw, x, y, w, h, r, fill, outline, outline_w):
    """Vertical rounded bar — fill with outline."""
    rrect(draw, [x, y, x+w, y+h], r, fill=fill, outline=outline, width=outline_w)


# ============================================================
# ICON COMPOSITION
# ============================================================

def create_icon():
    img = Image.new('RGBA', (SIZE, SIZE), rgba(C_BG, 255))
    draw = ImageDraw.Draw(img)

    # ---- Layout constants ----
    M     = 130                           # margin from edge
    B_W   = SIZE - 2 * M                  # badge width
    B_H   = int(B_W * 1.22)               # badge height (ID-card proportion)
    B_X   = M
    B_Y   = (SIZE - B_H) // 2
    B_R   = 50                            # corner radius

    # ---- Background glow (soft circle behind badge) ----
    circ(draw, (SIZE//2, SIZE//2), 380, fill=rgba(C_GLOW, 90))

    # ---- Badge body (rounded rect) ----
    rrect(draw, [B_X, B_Y, B_X + B_W, B_Y + B_H], B_R,
          fill=rgba(C_BADGE_FILL, 220), outline=C_BADGE_LINE, width=7)

    # ---- Inner double-border (line-art signature) ----
    im = 20
    rrect(draw,
          [B_X + im, B_Y + im, B_X + B_W - im, B_Y + B_H - im],
          B_R - im//2,
          fill=None, outline=C_INNER_LINE, width=3)

    # ---- Badge clip (top, centered) ----
    clip_w, clip_h = 76, 50
    clip_x = B_X + (B_W - clip_w) // 2
    clip_y = B_Y - clip_h + 8

    rrect(draw, [clip_x, clip_y, clip_x + clip_w, clip_y + clip_h], 18,
          fill=rgba(C_CLIP_FILL, 230), outline=C_CLIP_LINE, width=5)

    # Clip hole
    hole_y = clip_y + clip_h // 2
    circ(draw, (clip_x + clip_w // 2, hole_y), 13,
         fill=rgba(C_BG, 255), outline=C_CLIP_LINE, width=4)

    # ---- Neck strap lines (subtle, from clip to badge top corners) ----
    strap_y = clip_y + clip_h - 2
    ln(draw, (clip_x + 6, strap_y), (B_X + B_R, B_Y + 4),
       rgba(C_CLIP_LINE, 80), width=2)
    ln(draw, (clip_x + clip_w - 6, strap_y), (B_X + B_W - B_R, B_Y + 4),
       rgba(C_CLIP_LINE, 80), width=2)

    # ================================================================
    # INTERNAL ELEMENTS (line-art style)
    # ================================================================

    cx  = B_X + B_W // 2                  # horizontal center
    cy  = B_Y + B_H // 2                  # vertical center

    # ---- Row 1: Connected dots + sparkle (AI / smart) ----
    dot_y  = int(B_Y + B_H * 0.30)
    dot_r  = 10
    dots   = [-130, -65, 0, 65, 130]      # x offsets from center

    for dx in dots:
        circ(draw, (cx + dx, dot_y), dot_r,
             fill=rgba(C_DOT, 45), outline=C_DOT, width=3)

    # Connecting lines between dots
    for i in range(len(dots) - 1):
        x1 = cx + dots[i] + dot_r
        x2 = cx + dots[i+1] - dot_r
        ln(draw, (x1, dot_y), (x2, dot_y), rgba(C_DOT, 75), width=2)

    # Small sparkle star at the right end
    sx, sy = cx + dots[-1] + 40, dot_y - 3
    sl = 24
    ln(draw, (sx - sl, sy), (sx + sl, sy), rgba(C_SPARKLE, 170), width=3)
    ln(draw, (sx, sy - sl), (sx, sy + sl), rgba(C_SPARKLE, 170), width=3)
    d45 = int(sl * 0.55)
    ln(draw, (sx-d45, sy-d45), (sx+d45, sy+d45), rgba(C_SPARKLE, 100), width=2)
    ln(draw, (sx+d45, sy-d45), (sx-d45, sy+d45), rgba(C_SPARKLE, 100), width=2)
    circ(draw, (sx, sy), 5, fill=rgba(C_SPARKLE, 170))

    # ---- Row 2: Audio waveform bars (recording feature) ----
    wave_y  = int(B_Y + B_H * 0.54)
    wave_h  = 110
    n_bars  = 7
    bar_w   = 16
    bar_gap = 18
    pitch   = bar_w + bar_gap
    total_w = n_bars * bar_w + (n_bars - 1) * bar_gap
    start_x = cx - total_w // 2

    heights = []
    for i in range(n_bars):
        # Asymmetric sine — looks like a real waveform
        phase = (i / (n_bars - 1)) * math.pi
        h = abs(math.sin(phase * 1.4)) * wave_h * 0.70 + wave_h * 0.30
        heights.append(int(h))

    # Draw each bar
    for i, h in enumerate(heights):
        bx = start_x + i * pitch
        by = wave_y - h // 2
        bar_r = bar_w // 2
        # All bars same style for clean line-art look
        bar_rounded(draw, bx, by, bar_w, h, bar_r,
                    fill=rgba(C_WAVE_FILL, 55), outline=C_WAVE_LINE, outline_w=3)

    # ---- Row 3: Location pin (GPS feature) ----
    pin_y  = int(B_Y + B_H * 0.79)
    pin_r  = 22

    # Pin circle
    circ(draw, (cx, pin_y - 7), pin_r,
         fill=None, outline=rgba(C_PIN, 120), width=3)
    # Pin triangle bottom
    tri_h = 18
    ln(draw, (cx - pin_r + 4, pin_y - 1), (cx, pin_y + tri_h),
       rgba(C_PIN, 120), width=3)
    ln(draw, (cx + pin_r - 4, pin_y - 1), (cx, pin_y + tri_h),
       rgba(C_PIN, 120), width=3)
    # Inner dot
    circ(draw, (cx, pin_y - 7), 7, fill=rgba(C_PIN, 75))

    # ---- Subtle horizontal divider lines (card-like detail) ----
    div_y1 = int(B_Y + B_H * 0.44)
    div_y2 = int(B_Y + B_H * 0.68)
    div_margin = 80
    for dy in (div_y1, div_y2):
        ln(draw, (cx - 120, dy), (cx + 120, dy), rgba(C_INNER_LINE, 90), width=1)

    return img


# ============================================================
# EXPORT ALL SIZES
# ============================================================

def generate_all():
    base = create_icon()

    sizes = {
        # iPhone
        "icon-20@2x.png": 40,
        "icon-20@3x.png": 60,
        "icon-29@2x.png": 58,
        "icon-29@3x.png": 87,
        "icon-40@2x.png": 80,
        "icon-40@3x.png": 120,
        "icon-60@2x.png": 120,
        "icon-60@3x.png": 180,
        # iPad
        "icon-20@1x.png": 20,
        "icon-29@1x.png": 29,
        "icon-40@1x.png": 40,
        "icon-76@1x.png": 76,
        "icon-76@2x.png": 152,
        "icon-83.5@2x.png": 167,
        # App Store
        "icon-1024.png":  1024,
    }

    for name, size in sizes.items():
        path = os.path.join(OUTPUT_DIR, name)
        img = base if size == 1024 else base.resize((size, size), Image.LANCZOS)
        img.save(path, 'PNG')
        print(f"  ✓ {name} ({size}×{size})")

    print(f"\n✅ Done — {len(sizes)} icons written to:")
    print(f"   {OUTPUT_DIR}")


if __name__ == "__main__":
    generate_all()
