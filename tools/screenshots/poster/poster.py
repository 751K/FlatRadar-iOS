#!/usr/bin/env python3
"""Compose six localized App Store posters from raw screenshots.

Requires Python 3.10+, Pillow and macOS system fonts. See README.md for usage.
All layout dimensions derive from the target canvas; screenshots remain unedited.
"""
from __future__ import annotations

import argparse
import json
import pathlib
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = pathlib.Path(__file__).parent
DEVICES = {
    "iphone67": {"size": (1320, 2868), "display_type": "APP_IPHONE_67", "island": True},
    "iphone61": {"size": (1206, 2622), "display_type": "APP_IPHONE_61", "island": True},
    "ipad13": {"size": (2064, 2752), "display_type": "APP_IPAD_PRO_3GEN_129", "island": False},
    "ipad13l": {"size": (2752, 2064), "display_type": "APP_IPAD_PRO_3GEN_129", "island": False},
}
PLAN = [
    {"out": "00-Alerts", "src": "05-Notifications"},
    {"out": "01-Inbox", "src": "02-Listings"},
    {"out": "02-Map", "src": "03-Map"},
    {"out": "03-Dashboard", "src": "01-Dashboard"},
    {"out": "04-Views", "src": ["01-Dashboard", "02-Listings", "03-Map", "04-Calendar"]},
    {"out": "05-Calendar", "src": "04-Calendar"},
]
# Ink, paper and mint form one visual identity across the sequence.
THEMES = [
    ((13, 35, 49), (247, 249, 244), (168, 238, 205), (29, 65, 76)),
    ((239, 244, 239), (18, 45, 57), (37, 112, 91), (218, 231, 222)),
    ((224, 239, 232), (18, 45, 57), (37, 112, 91), (198, 221, 210)),
    ((236, 241, 248), (18, 45, 57), (41, 95, 155), (211, 223, 240)),
    ((13, 35, 49), (247, 249, 244), (168, 238, 205), (29, 65, 76)),
    ((246, 242, 233), (18, 45, 57), (123, 91, 47), (232, 224, 206)),
]


def _unit(W, H):
    return min(W, H)


def _rounded_mask(size, radius):
    w, h = size
    mask = Image.new("L", (w * 3, h * 3), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w * 3 - 1, h * 3 - 1),
                                          radius=radius * 3, fill=255)
    return mask.resize(size, Image.Resampling.LANCZOS)


LATIN_FONT = "/System/Library/Fonts/SFNS.ttf"
# 没有 PingFang 的机器上 Hiragino Sans GB 是唯一能同时覆盖简繁的系统字体。
# index 0 = W3（细），index 2 = W6（粗）。中文没有西文那么宽的字重轴，两层
# 对比做不到 Light↔Black 那么狠，只能到这个程度。
CJK_FONT, CJK_LIGHT, CJK_HEAVY = "/System/Library/Fonts/Hiragino Sans GB.ttc", 0, 2

def _font(size: int, cjk: bool, heavy: bool) -> ImageFont.FreeTypeFont:
    """Use SF Pro optical sizing and a consistent light/semibold weight pair."""
    if cjk:
        return ImageFont.truetype(CJK_FONT, size,
                                  index=CJK_HEAVY if heavy else CJK_LIGHT)
    f = ImageFont.truetype(LATIN_FONT, size)
    try:
        f.set_variation_by_axes([100, min(max(size / 3, 17), 96), 400,
                                 640 if heavy else 320])
    except Exception:
        try:
            f.set_variation_by_name("Black" if heavy else "Light")
        except Exception:
            pass   # 轴和命名实例都取不到时字还在，只是对比弱一点
    return f


def _stroke(size: int, cjk: bool, heavy: bool) -> int:
    """Slightly strengthen the available CJK semibold face."""
    return round(size * 0.012) if (cjk and heavy) else 0


def _text(d, xy, s, font, fill, stroke=0):
    d.text(xy, s, font=font, fill=fill,
           stroke_width=stroke, stroke_fill=fill if stroke else None)


GEOM = {"bezel": 0.015, "island_w": 0.284, "island_h": 0.0841,
        "island_top": 0.0319, "button_out": 0.006}


def _screen_mask(device_key: str, size) -> Image.Image:
    p = HERE / "masks" / f"{device_key}.png"
    if p.exists():
        m = Image.open(p).convert("L")
        return m if m.size == size else m.resize(size, Image.LANCZOS)
    return _rounded_mask(size, round(size[0] * 0.16))


def _device(shot: Image.Image, device_key: str, island: bool) -> Image.Image:
    W, H = shot.size
    g = GEOM
    bezel, out = round(W * g["bezel"]), round(W * g["button_out"])
    mask = _screen_mask(device_key, (W, H))

    screen = shot.convert("RGBA")
    if island:
        iw, ih = round(W * g["island_w"]), round(W * g["island_h"])
        pill = Image.new("RGBA", (iw, ih), (0, 0, 0, 255))
        pill.putalpha(_rounded_mask((iw, ih), ih // 2))
        screen.alpha_composite(pill, ((W - iw) // 2, round(W * g["island_top"])))
    screen.putalpha(mask)

    # 机身轮廓由屏幕掩膜放大得到。严格说该是"向外等距扩张"，缩放只是近似
    # （圆角少长约 14px），设备缩到版面后差不足两像素，不值得做形态学膨胀。
    fw, fh = W + 2 * bezel, H + 2 * bezel
    pad = out if island else 0
    body = Image.new("RGBA", (fw + 2 * pad, fh), (0, 0, 0, 0))

    shell = Image.new("RGBA", (fw, fh), (118, 118, 126, 255))
    shell.putalpha(mask.resize((fw, fh), Image.LANCZOS))
    inset = max(round(bezel * 0.28), 2)
    dark = Image.new("RGBA", (fw - 2 * inset, fh - 2 * inset), (18, 18, 20, 255))
    dark.putalpha(mask.resize(dark.size, Image.LANCZOS))
    shell.alpha_composite(dark, (inset, inset))
    shell.alpha_composite(screen, (bezel, bezel))

    # 侧键先画、机身后盖，按键内侧被机身压住才像从机身里长出来。
    # 画布左右留出 out，否则凸出的按键被边缘裁掉——裁掉不报错，只是不见了。
    if island:
        d = ImageDraw.Draw(body)
        for x0, x1, y0f, y1f in [
            (0, pad + bezel, 0.150, 0.181), (0, pad + bezel, 0.205, 0.256),
            (0, pad + bezel, 0.268, 0.319),
            (pad + fw - bezel, fw + 2 * pad, 0.212, 0.292),
        ]:
            d.rounded_rectangle([x0, round(fh * y0f), x1, round(fh * y1f)],
                                radius=max(out // 2, 2), fill=(99, 99, 102, 255))
    body.alpha_composite(shell, (pad, 0))
    return body


def _place(canvas, dev, x, y, W, H) -> None:
    """贴设备 + 投影。投影取设备自己的 alpha，不画圆角矩形——设备一旦旋转，
    矩形阴影就对不上机身轮廓。"""
    U = _unit(W, H)
    sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    blot = Image.new("RGBA", dev.size, (0, 0, 0, 255))
    blot.putalpha(dev.getchannel("A").point(lambda v: round(v * 0.45)))
    sh.alpha_composite(blot, (x, y + round(U * 0.008)))
    canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(round(U * 0.024))))
    canvas.alpha_composite(dev, (x, y))


def _fit(text, px, max_w, cjk, heavy):
    """Fit each editorial line, including the stroke, inside its column."""
    for size in range(max(1, px), 0, -1):
        font = _font(size, cjk, heavy)
        box = font.getbbox(text, stroke_width=_stroke(size, cjk, heavy))
        if box[2] - box[0] <= max_w:
            return font
    return _font(1, cjk, heavy)


def _label(canvas, text, x, y, size, width, cjk, heavy, color):
    font = _fit(text, round(size), round(width), cjk, heavy)
    stroke = _stroke(font.size, cjk, heavy)
    box = font.getbbox(text, stroke_width=stroke)
    # Position visible ink, rather than the font's ascender box.
    _text(ImageDraw.Draw(canvas), (round(x - box[0]), round(y - box[1])),
          text, font, color, stroke)
    return box[3] - box[1]


def _brand(canvas, idx, margin, U, color, accent):
    side = round(U * .044)
    x, y = margin, round(U * .072)
    icon_path = HERE / "appicon.png"
    if icon_path.exists():
        with Image.open(icon_path) as image:
            icon = image.convert("RGBA").resize((side, side), Image.Resampling.LANCZOS)
        icon.putalpha(_rounded_mask(icon.size, round(side * .23)))
        canvas.alpha_composite(icon, (x, y))
    _label(canvas, "FlatRadar", x + side + U * .016, y + U * .009,
           U * .029, U * .35, False, True, color)
    _label(canvas, f"0{idx + 1} / 06", canvas.width - margin - U * .13,
           y + U * .012, U * .020, U * .13, False, False, accent)


def _background(size, idx):
    W, H = size
    bg, ink, accent, surface = THEMES[idx]
    canvas = Image.new("RGBA", size, bg + (255,))
    # A single architectural panel anchors the device; rings suggest the radar.
    d = ImageDraw.Draw(canvas)
    U = min(W, H)
    if W > H:
        rect = (round(W * .44), round(H * .17), round(W * .95), round(H * .95))
    else:
        rect = (round(W * .045), round(H * .32), round(W * .955), round(H * 1.08))
    d.rounded_rectangle(rect, radius=round(U * .08), fill=surface)
    if idx in (0, 2, 4):
        cx, cy = W * (.74 if W > H else .52), H * .72
        ring = tuple(round(surface[i] * .85 + accent[i] * .15) for i in range(3))
        for radius in (.28, .44, .60):
            r = U * radius
            d.ellipse((round(cx-r), round(cy-r), round(cx+r), round(cy+r)),
                      outline=ring, width=max(2, round(U * .0015)))
    return canvas


def _headline(canvas, copy, idx, cjk):
    W, H = canvas.size
    U, land = min(W, H), W > H
    margin = round(U * .085)
    _, ink, accent, _ = THEMES[idx]
    _brand(canvas, idx, margin, U, ink, accent)
    x, y = margin, round(H * (.29 if land else .112))
    width = W * .33 if land else W - margin * 2
    lead_size = U * (.056 if cjk else .062)
    head_size = U * (.106 if cjk else .105)
    y += _label(canvas, copy["lead"], x, y, lead_size, width, cjk, False, ink)
    y += U * .024
    y += _label(canvas, copy["head"], x, y, head_size, width, cjk, True, accent)
    return y


def _feature(canvas, badges, top, idx, cjk):
    """One compact supporting fact, without competing with the headline."""
    W, H = canvas.size
    U, land = min(W, H), W > H
    _, ink, accent, surface = THEMES[idx]
    value, label = badges[0]
    x, y = round(U * .085), round(top + U * .05)
    width = round(W * .32 if land else W * .83)
    height = round(U * .064)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((x, y, x + width, y + height), radius=height // 2, fill=surface)
    _label(canvas, f"{value}  {label}", x + U * .024, y + U * .017,
           U * .030, width - U * .048, cjk, True, accent)
    return y + height


def _resize_fit(dev, max_w, max_h):
    scale = min(max_w / dev.width, max_h / dev.height)
    return dev.resize((round(dev.width * scale), round(dev.height * scale)),
                      Image.Resampling.LANCZOS)


def build(spec, copy, src, idx, dev_spec, cjk, device_key, badges=None):
    W, H = dev_spec["size"]
    U, land = min(W, H), W > H
    canvas = _background((W, H), idx)
    top = _headline(canvas, copy, idx, cjk)
    if idx == 0 and badges:
        top = _feature(canvas, badges, top, idx, cjk)

    def load(name):
        with Image.open(src / f"{name}.png") as image:
            return _device(image.convert("RGB"), device_key, dev_spec["island"])

    # Landscape uses a text column and a separate device column.
    left, right = (W * .47, W * .925) if land else (W * .09, W * .91)
    start = H * .21 if land else max(H * .315, top + U * .06)
    bottom = H * .94
    if isinstance(spec["src"], list):
        gap = U * .030
        cell_w = (right - left - gap) / 2
        cell_h = (bottom - start - gap) / 2
        for i, name in enumerate(spec["src"]):
            dev = _resize_fit(load(name), cell_w, cell_h)
            x = left + (i % 2) * (cell_w + gap) + (cell_w - dev.width) / 2
            y = start + (i // 2) * (cell_h + gap)
            _place(canvas, dev, round(x), round(y), W, H)
    else:
        dev = load(spec["src"])
        # Phone portraits deliberately bleed at the bottom; tablets stay whole.
        max_h = H * 1.045 - start if dev_spec["island"] and not land else bottom - start
        dev = _resize_fit(dev, right - left, max_h)
        x = (left + right - dev.width) / 2
        _place(canvas, dev, round(x), round(start), W, H)
    return canvas.convert("RGB")


def build_hero_pair(strings, src, dev_spec, cjk, device_key):
    """An editorial cover: one promise, one proof point, one spanning device."""
    W, H = dev_spec["size"]
    U = min(W, H)
    paper, ink, accent = (247, 246, 242), (24, 31, 46), (44, 83, 220)
    muted = (100, 108, 122)
    canvas = Image.new("RGBA", (2 * W, H), paper + (255,))
    d = ImageDraw.Draw(canvas)
    # A quiet, oversized radar motif connects the pages behind the device.
    cx, cy = W * 1.47, H * .63
    for radius, color in [(W * .95, (239, 241, 246)),
                          (W * .74, (231, 236, 248)),
                          (W * .53, (218, 227, 248))]:
        d.ellipse((round(cx-radius), round(cy-radius), round(cx+radius), round(cy+radius)),
                  fill=color)

    with Image.open(src / "01-Dashboard.png") as shot:
        dev = _device(shot.convert("RGB"), device_key, dev_spec["island"])
    dev = _resize_fit(dev, W * .94, H * .88)
    dev = dev.rotate(-7, resample=Image.Resampling.BICUBIC, expand=True)
    # Anchor the rotated bounding box: keep a real margin at the right edge.
    x = round(2 * W - U * .105 - dev.width)
    y = round(H * .12)
    _place(canvas, dev, x, y, W, H)

    # The column is bounded by the actual rotated silhouette, not a guessed box.
    alpha = dev.getchannel("A")
    left_edge = W
    for row in range(0, min(dev.height, H - y), 8):
        bounds = alpha.crop((0, row, dev.width, row + 1)).getbbox()
        if bounds:
            left_edge = min(left_edge, x + bounds[0])
    left = round(W * .095)
    width = min(round(W * .76), left_edge - left - round(U * .035))
    hero = strings.get("_hero", {})
    title = hero.get("title", [strings["00-Alerts"]["lead"], strings["00-Alerts"]["head"]])
    body = hero.get("body", [])

    # Compact horizontal brand lockup; the headline carries the visual weight.
    side = round(U * .070)
    brand_y = round(H * .065)
    with Image.open(HERE / "appicon.png") as image:
        icon = image.convert("RGBA").resize((side, side), Image.Resampling.LANCZOS)
    icon.putalpha(_rounded_mask(icon.size, round(side * .23)))
    canvas.alpha_composite(icon, (left, brand_y))
    _label(canvas, "FlatRadar", left + side + U * .022, brand_y + U * .015,
           U * .041, width - side - U * .022, False, True, ink)

    # Fit both headline lines to one size, preserving the typographic hierarchy.
    size = min(_fit(line, round(U * (.143 if cjk else .127)), width, cjk, True).size
               for line in title)
    yy = H * .235
    for i, line in enumerate(title):
        height = _label(canvas, line, left, yy, size, width, cjk, True, ink if i == 0 else accent)
        yy += height + U * .033
    yy += U * .040
    for line in body:
        height = _label(canvas, line, left, yy, U * .033, width, cjk, False, muted)
        yy += height + U * .017

    # A single evidence block replaces three evenly spaced feature labels.
    proof_y = max(H * .66, yy + U * .10)
    d.line((left, round(proof_y - U * .055), left + round(width * .91),
            round(proof_y - U * .055)), fill=(207, 212, 221), width=max(2, round(U * .001)))
    value = strings.get("_badges", [["7"]])[0][0]
    _label(canvas, value, left, proof_y, U * .19, U * .20, False, True, accent)
    for i, line in enumerate(hero.get("proof", ["platforms", "One place."])):
        _label(canvas, line, left + U * .17, proof_y + U * (.045 + i * .049),
               U * .036, width - U * .17, cjk, i == 1, ink)

    # Small footer belongs to the left page; it never rides over the device.
    footer_y = H * .89
    _label(canvas, hero.get("tagline", ""), left, footer_y, U * .026, width, cjk, False, muted)
    _label(canvas, "FLATRADAR  /  NETHERLANDS", left, footer_y + U * .051,
           U * .017, width, False, True, muted)
    return [canvas.crop((0, 0, W, H)).convert("RGB"),
            canvas.crop((W, 0, 2 * W, H)).convert("RGB")]


def spread_preview(images, out):
    """Store-like gap is preview-only; exported pages contain no divider."""
    w = 540
    h = round(images[0].height * w / images[0].width)
    preview = Image.new("RGB", (w * 2 + 12, h), (35, 43, 43))
    for i, image in enumerate(images[:2]):
        preview.paste(image.resize((w, h), Image.Resampling.LANCZOS), (i * (w + 12), 0))
    out.parent.mkdir(parents=True, exist_ok=True)
    preview.save(out)


def contact_sheet(images, out):
    """Preview all six posters at a readable, bounded size."""
    thumb_w = 360
    gap = 18
    thumbs = []
    for image in images:
        thumb = image.copy()
        thumb.thumbnail((thumb_w, 780), Image.Resampling.LANCZOS)
        thumbs.append(thumb)
    sheet = Image.new("RGB", (3 * thumb_w + 4 * gap,
                              2 * max(im.height for im in thumbs) + 3 * gap), (216, 223, 222))
    row_h = max(im.height for im in thumbs)
    for i, thumb in enumerate(thumbs):
        sheet.paste(thumb, (gap + (i % 3) * (thumb_w + gap), gap + (i // 3) * (row_h + gap)))
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)


def main():
    ap = argparse.ArgumentParser(description="合成 App Store 海报式截图")
    ap.add_argument("--src", required=True, type=pathlib.Path)
    ap.add_argument("--lang", required=True)
    ap.add_argument("--device", required=True, choices=sorted(DEVICES))
    ap.add_argument("--out", required=True, type=pathlib.Path)
    ap.add_argument("--copy", type=pathlib.Path, default=HERE / "copy.json")
    ap.add_argument("--preview", type=pathlib.Path, help="联系表路径；请放在上传目录外")
    args = ap.parse_args()
    copy = json.loads(args.copy.read_text(encoding="utf-8"))
    if args.lang not in copy or args.lang.startswith("_"):
        ap.error(f"文案语言不存在：{args.lang}")
    strings = copy[args.lang]
    # Preflight the whole sequence so missing inputs cannot silently produce a partial set.
    for spec in PLAN:
        if spec["out"] not in strings:
            ap.error(f"缺少文案：{spec['out']}")
        names = spec["src"] if isinstance(spec["src"], list) else [spec["src"]]
        for name in names:
            if not (args.src / f"{name}.png").is_file():
                ap.error(f"缺少素屏：{args.src / (name + '.png')}")
    if args.src.resolve() == args.out.resolve():
        ap.error("输出目录不能与素屏目录相同")
    if args.preview and args.preview.resolve().is_relative_to(args.out.resolve()):
        ap.error("预览必须放在上传目录外，以免被当作商店截图")
    args.out.mkdir(parents=True, exist_ok=True)
    images = []
    dev_spec = DEVICES[args.device]
    pair = build_hero_pair(strings, args.src, dev_spec, args.lang.startswith("zh"), args.device)
    for idx, spec in enumerate(PLAN):
        image = pair[idx] if idx < 2 else build(spec, strings[spec["out"]], args.src, idx, dev_spec,
                      args.lang.startswith("zh"), args.device, strings.get("_badges"))
        assert image.size == dev_spec["size"] and image.mode == "RGB"
        image.save(args.out / f"{spec['out']}.png")
        images.append(image)
    if args.preview:
        contact_sheet(images, args.preview)
        spread_preview(images, args.preview.with_name(args.preview.stem + "-spread.png"))
    print(f"✓ {args.lang}/{args.device}: {len(images)} 张 → {args.out} "
          f"({dev_spec['size'][0]}x{dev_spec['size'][1]})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
