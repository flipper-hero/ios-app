"""Builds docs/banner.png for the README from the screenshots in docs/screenshots.

Run after updating the screenshots:
    nix-shell -p 'python3.withPackages(ps: [ps.pillow])' --run 'python3 scripts/make-banner.py'
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ["chat", "permission", "device", "remote", "files"]
W, H = 2400, 1470
ORANGE = (255, 130, 0)
FONT = "/System/Library/Fonts/SFNSRounded.ttf"


def font(size, weight="Bold"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def background():
    img = Image.new("RGB", (W, H), (10, 10, 12))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse((W * 0.18, -H * 0.55, W * 0.82, H * 0.62), fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    tint = Image.new("RGB", (W, H), ORANGE)
    return Image.composite(tint, img, glow)


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *img.size), radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def phone(name, height):
    shot = Image.open(ROOT / "docs/screenshots" / f"{name}.png").convert("RGB")
    width = round(shot.width * height / shot.height)
    shot = shot.resize((width, height), Image.LANCZOS)
    screen = rounded(shot, round(width * 0.11))
    bezel = round(width * 0.025)
    frame = Image.new("RGBA", (width + 2 * bezel, height + 2 * bezel), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle((0, 0, *frame.size), round(width * 0.13), fill=(38, 38, 42, 255))
    frame.alpha_composite(screen, (bezel, bezel))
    return frame


def shadow(size, radius, blur, opacity):
    pad = blur * 3
    s = Image.new("RGBA", (size[0] + 2 * pad, size[1] + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(s).rounded_rectangle((pad, pad, pad + size[0], pad + size[1]), radius, fill=(0, 0, 0, opacity))
    return s.filter(ImageFilter.GaussianBlur(blur)), pad


def main():
    canvas = background().convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    # Title row: logo and wordmark, centered.
    logo = rounded(Image.open(ROOT / "App/Assets.xcassets/Logo.imageset/Logo.png").convert("RGB").resize((150, 150), Image.LANCZOS), 34)
    title = "FlipperHero"
    title_font = font(124)
    tw = draw.textlength(title, font=title_font)
    x = (W - (150 + 40 + tw)) / 2
    canvas.alpha_composite(logo, (round(x), 70))
    draw.text((x + 190, 74), title, font=title_font, fill=(255, 255, 255))
    tagline = "Your Flipper Zero, driven by an AI agent that asks before it acts."
    tag_font = font(46, "Medium")
    draw.text(((W - draw.textlength(tagline, font=tag_font)) / 2, 250), tagline, font=tag_font, fill=(200, 200, 205))

    # Phones: the middle one largest, the outer ones smaller and lower.
    heights = [800, 900, 1000, 900, 800]
    phones = [phone(n, h) for n, h in zip(SHOTS, heights)]
    gap = 46
    total = sum(p.width for p in phones) + gap * (len(phones) - 1)
    x = (W - total) // 2
    top = 360
    for i, p in enumerate(phones):
        y = top + (max(heights) - heights[i]) // 2 + 20
        sh, pad = shadow(p.size, round(p.width * 0.13), 40, 170)
        canvas.alpha_composite(sh, (x - pad, y - pad + 24))
        canvas.alpha_composite(p, (x, y))
        x += p.width + gap

    out = ROOT / "docs/banner.png"
    canvas.convert("RGB").save(out, optimize=True)
    print(f"wrote {out} ({out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
