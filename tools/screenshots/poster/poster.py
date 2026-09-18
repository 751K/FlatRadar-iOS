#!/usr/bin/env python3
"""Compose six localized App Store posters from raw screenshots.

Requires Python 3.10+, Pillow, NumPy, SciPy and macOS system fonts. See README.md.
All layout dimensions derive from the target canvas; screenshots remain unedited.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont
from scipy.ndimage import distance_transform_edt

HERE = pathlib.Path(__file__).parent
DEVICES = {
    "iphone67": {"size": (1320, 2868), "display_type": "APP_IPHONE_67", "island": True, "bezel": .0205},
    "iphone61": {"size": (1206, 2622), "display_type": "APP_IPHONE_61", "island": True, "bezel": .0224},
    "ipad13": {"size": (2064, 2752), "display_type": "APP_IPAD_PRO_3GEN_129", "island": False, "bezel": .0436},
    "ipad13l": {"size": (2752, 2064), "display_type": "APP_IPAD_PRO_3GEN_129", "island": False, "bezel": .0327},
    # macOS screenshots are already complete desktop-window captures.  There is
    # no simulated device frame; the poster only adds editorial space around
    # the real window.  2560x1600 is the largest ASC Mac canvas and matches the
    # output of run-mac.sh on the local/Xcode Cloud Retina host.
    "mac": {"size": (2560, 1600), "display_type": "APP_DESKTOP", "island": False,
            "kind": "mac"},
}
PLAN = [
    {"out": "00-Alerts", "src": "05-Notifications"},
    {"out": "01-Inbox", "src": "02-Listings"},
    {"out": "02-Map", "src": "03-Map"},
    {"out": "03-Notify", "src": "05-Notifications"},
    {"out": "04-Views", "src": ["01-Dashboard", "02-Listings", "03-Map", "04-Calendar"]},
    {"out": "05-Calendar", "src": "04-Calendar"},
]

# Mac UI tests use their own names and order.  Keep this separate from the
# iOS plan so a Mac directory cannot accidentally be treated as iPhone input.
MAC_PLAN = [
    {"out": "00-Overview", "src": "01-Listings"},
    # The right-hand page is a continuation of the same hero window.  The
    # sign-in capture is intentionally left out of the store sequence; the
    # five product surfaces make a stronger first impression.
    {"out": "01-Listings", "src": "01-Listings"},
    {"out": "02-Map", "src": "02-Map"},
    {"out": "03-Calendar", "src": "03-Calendar"},
    {"out": "04-Alerts", "src": "04-Alerts"},
    {"out": "05-Stats", "src": "05-Stats"},
]
# Ink, paper and mint form one visual identity across the sequence.
#
# 六张全是浅色，没有深色页。深色页在商店的搜索结果列表里会缩成一块黑砖，
# 旁边一水儿浅色卡片，第一眼读到的是"暗"而不是内容。
# 节奏改由**饱和度**给：第 5 张那块偏实的薄荷绿是全组里最浓的一处，
# 替掉了原先靠深色制造的那个断点。
THEMES = [
    ((250, 248, 243), (18, 45, 57), (29, 78, 150), (234, 233, 227)),
    ((239, 244, 239), (18, 45, 57), (37, 112, 91), (218, 231, 222)),
    ((224, 239, 232), (18, 45, 57), (37, 112, 91), (198, 221, 210)),
    ((236, 241, 248), (18, 45, 57), (41, 95, 155), (211, 223, 240)),
    ((211, 230, 228), (18, 45, 57), (21, 88, 84), (190, 215, 212)),
    ((246, 242, 233), (18, 45, 57), (123, 91, 47), (232, 224, 206)),
]


def _unit(W, H):
    return min(W, H)


# 横屏的分栏只有这一个来源。
#
# 早先文字列写 0.33W、设备列写 0.40W，是两个各自独立的魔数；把设备列拓宽后
# 文字列没跟着退，标题和胶囊的右端就顶到衬底板上了。两者从同一个分界算出来，
# 就不会再各走各的。
LAND_SPLIT = .42          # 设备列起点占画布宽的比例
LAND_PANEL_PAD = .045     # 衬底板比设备各向外扩的量（占短边）
LAND_GUTTER = .030        # 文字列与衬底板之间留的空当（占短边）
LAND_BLEED = 1.10         # 横屏单机时设备列右缘占画布宽的比例；>1 = 从右边出血


def _land_columns(W, H):
    """→ (文字列左缘, 文字列可用宽, 设备列左缘, 设备列右缘)"""
    U = min(W, H)
    margin = U * .085
    dev_left = W * LAND_SPLIT
    text_right = dev_left - U * LAND_PANEL_PAD - U * LAND_GUTTER
    return margin, max(text_right - margin, U * .20), dev_left, W * .955


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


# `bezel` 只是兜底默认；实际取值在 DEVICES 里按设备给，来源是 Xcode 自带的
# 设备外框素材，不是"看着像"。
#
#   /Library/Developer/CoreSimulator/Profiles/DeviceTypes/<机型>.simdevicetype
#       profile.plist → chromeIdentifier / framebufferMask
#   /Library/Developer/DeviceKit/Chrome/<chrome>.devicechrome/Contents/Resources
#       chrome.json  → paths.simpleOutsideBorder.cornerRadius = 机身圆角
#
# 边框 = 机身圆角 − 屏幕圆角，屏幕圆角量 masks/（就是 framebufferMask 抠的）：
#
#             chrome    机身圆角   屏幕圆角   边框
#   iPhone    phone12     80pt     70.7pt    9.3 → 9pt
#   iPad      tablet5     75pt     30.0pt    45pt
#
# iPhone 这条有三重印证：chrome.json 的 sizing 18 − devicePadding 9 = 9pt；
# PhoneComposite.pdf 474×990 减两侧 sizing 得 438×954 ≈ 屏幕 440×956；
# 9pt × 0.1625mm/pt ≈ 1.46mm，与"真机边框约 1.5mm"吻合。
# iPad 用同一把尺：45pt × 0.192mm/pt ≈ 8.6mm，而 13" iPad 机身 215.5mm、
# 屏宽约 198mm，两边各 8.75mm——对得上。
#
# **系数是相对各自截图宽算的，所以四个值都不一样**（同样 9pt，1320px 宽的
# 截图上是 .0205，1206px 上就是 .0224）：
#
#             截图px    =pt    边框pt   边框px   bezel
#   iphone67    1320    440       9      27    .0205
#   iphone61    1206    402       9      27    .0224
#   ipad13      2064   1032      45      90    .0436
#   ipad13l     2752   1376      45      90    .0327
#
# 这段推导在引入 masks/ 那次被整块删掉过，.015 就成了没出处的魔数（它其实
# 是 6.6pt，比自己写的 1.5mm 目标还薄三成），之后只能靠眼睛调。别再删。
GEOM = {"bezel": 0.015, "island_w": 0.284, "island_h": 0.0841,
        "island_top": 0.0319, "button_out": 0.006}


def _screen_mask(device_key: str, size) -> Image.Image:
    p = HERE / "masks" / f"{device_key}.png"
    if p.exists():
        m = Image.open(p).convert("L")
        return m if m.size == size else m.resize(size, Image.LANCZOS)
    return _rounded_mask(size, round(size[0] * 0.16))


_BODY_CACHE: dict = {}


def _body_mask(device_key: str, size, grow: int) -> Image.Image:
    """屏幕掩膜**向外等距扩张** grow 像素，得到机身轮廓。

    原来是 `mask.resize((W+2b, H+2b))`——整体缩放。缩放把圆角按同一比例放大，
    而等距外扩是给圆角**加上**边框宽度，两者只在边框极细时才近似相等：

                屏幕圆角   缩放法机身圆角   等距外扩   chrome.json 实测
        iPhone   70.7pt      73.6pt        79.7pt      80pt
        iPad     30.0pt      32.0pt        75.0pt      75pt

    边框从 6.6pt 加到 9/45pt 之后，iPad 那栏差了 43pt（86px）——机身该有的圆
    角只画出不到一半，看着就是方的。等距外扩两个设备都对上 chrome.json，
    这也反过来印证了边框取值没错。

    用距离变换做，保留 Apple 掩膜本身的连续曲率（squircle）；换成画一个圆弧
    圆角矩形会让边框宽度在转角处忽宽忽窄。
    """
    key = (device_key, size, grow)
    if key not in _BODY_CACHE:
        W, H = size
        base = Image.new("L", (W + 2 * grow, H + 2 * grow), 0)
        base.paste(_screen_mask(device_key, size), (grow, grow))
        dist = distance_transform_edt(np.asarray(base) <= 127)
        alpha = np.clip(grow + .5 - dist, 0, 1) * 255      # 边缘留 1px 抗锯齿
        _BODY_CACHE[key] = Image.fromarray(alpha.astype(np.uint8), "L")
    return _BODY_CACHE[key]


def _device(shot: Image.Image, device_key: str, island: bool) -> Image.Image:
    W, H = shot.size
    g = GEOM
    bezel = round(W * DEVICES.get(device_key, {}).get("bezel", g["bezel"]))
    out = round(W * g["button_out"])
    mask = _screen_mask(device_key, (W, H))

    screen = shot.convert("RGBA")
    if island:
        iw, ih = round(W * g["island_w"]), round(W * g["island_h"])
        pill = Image.new("RGBA", (iw, ih), (0, 0, 0, 255))
        pill.putalpha(_rounded_mask((iw, ih), ih // 2))
        screen.alpha_composite(pill, ((W - iw) // 2, round(W * g["island_top"])))
    screen.putalpha(mask)

    fw, fh = W + 2 * bezel, H + 2 * bezel
    pad = out if island else 0
    body = Image.new("RGBA", (fw + 2 * pad, fh), (0, 0, 0, 0))

    shell = Image.new("RGBA", (fw, fh), (118, 118, 126, 255))
    shell.putalpha(_body_mask(device_key, (W, H), bezel))
    inset = max(round(bezel * 0.28), 2)
    dark = Image.new("RGBA", (fw - 2 * inset, fh - 2 * inset), (18, 18, 20, 255))
    dark.putalpha(_body_mask(device_key, (W, H), bezel - inset))
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
    矩形阴影就对不上机身轮廓。

    两个尺度都跟着**设备**走，不跟画布走：

    - 原来模糊半径写 `U*.024`（U = 画布短边），于是四视图里 800px 宽的小机器
      和整版 1900px 的大机器共用 50px 模糊。小机器被一圈和自己不成比例的影子
      裹住；而网格间距 62px 还不到模糊半径的两倍，四台的影子直接糊成一片。
    - 原来下移 `U*.008` = 17px，只有模糊半径的三分之一，影子就在设备**上方**
      也铺开 33px。实测 iPad 顶边上方漏出 110px、贴边处把底色压暗 22%——那是
      光晕不是投影。下移取模糊的 .85 倍，影子上沿基本压在机身上沿。
    """
    blur = max(round(dev.width * .020), 5)
    sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    blot = Image.new("RGBA", dev.size, (0, 0, 0, 255))
    blot.putalpha(dev.getchannel("A").point(lambda v: round(v * 0.38)))
    sh.alpha_composite(blot, (x, y + round(blur * .85)))
    canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(blur)))
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


def _logo(idx, side):
    """按主题明暗取品牌标。

    BrandLogo 的 light/dark 两版都是**带底色**的方块（不是透明前景），所以
    浅底海报必须用 light、深底必须用 dark；用错的那一版会在页眉上糊出一块
    和底色打架的方形。按主题底色的明度自动选，不用手维护一张对照表。
    """
    bg = THEMES[idx][0]
    name = "logo-dark.png" if sum(bg) / 3 < 128 else "logo-light.png"
    path = HERE / name
    if not path.exists():
        return None
    with Image.open(path) as image:
        icon = image.convert("RGBA").resize((side, side), Image.Resampling.LANCZOS)
    icon.putalpha(_rounded_mask(icon.size, round(side * .23)))
    return icon


def _brand(canvas, idx, margin, U, color, accent):
    side = round(U * .044)
    x, y = margin, round(U * .072)
    icon = _logo(idx, side)
    if icon:
        canvas.alpha_composite(icon, (x, y))
    _label(canvas, "FlatRadar", x + side + U * .016, y + U * .009,
           U * .029, U * .35, False, True, color)
    _label(canvas, f"0{idx + 1} / 06", canvas.width - margin - U * .13,
           y + U * .012, U * .020, U * .13, False, False, accent)


def _background(size, idx, rect=None):
    """`rect` 由调用方按设备的实际落点给出。

    横屏上这块板不能写死：横机身宽高比 1.33，而写死的 0.44W..0.95W ×
    0.17H..0.95H 是一块**竖着**的板（1403×1610），装横着的机器必然对不上——
    机身下方空出五百多像素的空板，看着像图没加载完。
    """
    W, H = size
    bg, ink, accent, surface = THEMES[idx]
    canvas = Image.new("RGBA", size, bg + (255,))
    # A single architectural panel anchors the device; rings suggest the radar.
    d = ImageDraw.Draw(canvas)
    U = min(W, H)
    if rect is None:
        rect = ((round(W * .44), round(H * .17), round(W * .95), round(H * .95))
                if W > H else
                (round(W * .045), round(H * .32), round(W * .955), round(H * 1.08)))
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
    width = _land_columns(W, H)[1] if land else W - margin * 2
    lead_size = U * (.056 if cjk else .062)
    head_size = U * (.106 if cjk else .105)

    # 横屏时标题**纵向对齐设备带中线**。原来钉死在 H*.29，标题只占左栏顶部
    # 四分之一，下面留一条 826×1200 的纯空白——横屏最扎眼的空就是这块。
    # 高度先在废弃画布上量一遍再定位：`_label` 会按列宽缩字号，不实际排一次
    # 拿不到真高度（同一句英文和中文能差出两行）。
    if land:
        probe = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        h = _label(probe, copy["lead"], margin, 0, lead_size, width, cjk, False, ink)
        h += U * .024
        h += _label(probe, copy["head"], margin, h, head_size, width, cjk, True, accent)
        y = round(H * .16 + (H * .94 - H * .16 - h) / 2)
    else:
        y = round(H * .112)
    x = margin
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
    width = round(_land_columns(W, H)[1] if land else W * .83)
    height = round(U * .064)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((x, y, x + width, y + height), radius=height // 2, fill=surface)
    # 拼接跳过空段：中文那条把数字写进了句子里（「同时监测七个平台」），
    # 没有独立的数字段，按 f"{value}  {label}" 硬拼会留下两个前导空格。
    _label(canvas, "  ".join(p for p in (value, label) if p),
           x + U * .024, y + U * .017,
           U * .030, width - U * .048, cjk, True, accent)
    return y + height


def _resize_fit(dev, max_w, max_h):
    scale = min(max_w / dev.width, max_h / dev.height)
    return dev.resize((round(dev.width * scale), round(dev.height * scale)),
                      Image.Resampling.LANCZOS)


def _mac_crop(shot):
    """Trim the white canvas around a Mac window capture.

    ``run-mac.sh`` deliberately writes an ASC-sized white canvas around the
    window.  Keeping that canvas and shrinking it again makes the actual UI
    unreadably small in a poster.  The crop is derived from the pixels rather
    than from a hard-coded window frame, so it also works for the 1280/1440
    hosts accepted by App Store Connect.
    """
    image = shot.convert("RGBA")
    # Some xcparse versions preserve the screenshot's transparent outer
    # pixels.  Flatten those onto the same white canvas used by
    # `MacScreenshotTests.compose`; otherwise transparent pixels convert to
    # black and the crop would incorrectly include the whole canvas.
    if image.getchannel("A").getextrema()[0] < 255:
        flattened = Image.new("RGBA", image.size, (255, 255, 255, 255))
        flattened.alpha_composite(image)
        image = flattened
    rgb = image.convert("RGB")
    white = Image.new("RGB", rgb.size, (255, 255, 255))
    bbox = ImageChops.difference(rgb, white).getbbox()
    if not bbox:
        return image
    w, h = image.size
    pad = max(round(min(w, h) * .012), 8)
    x0 = max(0, bbox[0] - pad)
    y0 = max(0, bbox[1] - pad)
    x1 = min(w, bbox[2] + pad)
    y1 = min(h, bbox[3] + pad)
    return image.crop((x0, y0, x1, y1))


def _mac_window(shot, max_w, max_h, radius=28):
    """Return the real Mac window with no synthetic bezel or card border.

    The capture already contains the native title bar and its rounded window
    corners.  Adding a second white frame made the desktop screenshots look
    like a device mockup, so the poster only applies a clipping mask; the
    shared ``_place`` helper supplies the restrained shadow.
    """
    crop = _mac_crop(shot)
    window = _resize_fit(crop, max_w, max_h)
    rr = min(round(radius), round(min(window.size) * .07))
    window.putalpha(_rounded_mask(window.size, max(10, rr)))
    return window


def _mac_background(size, idx, hero=False):
    """Quiet desktop canvas: one large panel and a low-contrast radar arc."""
    W, H = size
    _, _, accent, surface = THEMES[idx % len(THEMES)]
    # Mac pages need a wider, calmer field than the phone pages.  Keep the
    # existing palette but lift the paper so the native window remains legible.
    paper = (247, 248, 246) if idx != 2 else (239, 246, 243)
    canvas = Image.new("RGBA", size, paper + (255,))
    d = ImageDraw.Draw(canvas)
    U = min(W, H)
    if hero:
        panel = (round(W * .42), round(H * .10), round(W * .985), round(H * .98))
    else:
        panel = (round(W * .36), round(H * .14), round(W * .97), round(H * .94))
    d.rounded_rectangle(panel, radius=round(U * .055), fill=surface + (235,))
    cx, cy = W * (.79 if not hero else .73), H * .58
    ring = tuple(round(surface[i] * .72 + accent[i] * .28) for i in range(3))
    for factor in (.30, .47, .64):
        r = U * factor
        d.ellipse((round(cx - r), round(cy - r), round(cx + r), round(cy + r)),
                  outline=ring + (95,), width=max(2, round(U * .0012)))
    return canvas


def build_mac_hero_pair(strings, src, dev_spec, cjk):
    """Create a two-page Mac cover from one continuous desktop window."""
    W, H = dev_spec["size"]
    U = min(W, H)
    ink, accent = (18, 45, 57), (38, 82, 200)
    muted = (100, 108, 122)
    canvas = _mac_background((2 * W, H), 0, hero=True)
    with Image.open(src / "01-Listings.png") as shot:
        card = _mac_window(shot.convert("RGB"), round(W * 1.52), round(H * .82),
                           radius=38)
    # The window crosses the seam by about one quarter of its width.  It is
    # large enough to read, while the first page still has a clean text column.
    x = round(W * .75)
    y = round(H * .13)
    _place(canvas, card, x, y, W, H)

    left = round(W * .095)
    width = round(W * .57)
    hero = strings.get("_mac", {})
    title = hero.get("hero_title", ["Your next home.", "Starts here."])
    body = hero.get("hero_body", [])
    side = round(U * .068)
    brand_y = round(H * .065)
    icon = _logo(0, side)
    if icon:
        canvas.alpha_composite(icon, (left, brand_y))
    _label(canvas, "FlatRadar for Mac", left + side + U * .020, brand_y + U * .014,
           U * .040, width - side, False, True, ink)

    title_size = min(_fit(line, round(U * .135), width, cjk, True).size for line in title)
    yy = H * .245
    for i, line in enumerate(title):
        height = _label(canvas, line, left, yy, title_size, width, cjk, True,
                        ink if i == 0 else accent)
        yy += height + U * .028
    yy += U * .028
    for line in body:
        height = _label(canvas, line, left, yy, U * .032, width, cjk, False, muted)
        yy += height + U * .014

    line_y = H * .68
    ImageDraw.Draw(canvas).line((left, round(line_y - U * .045), left + round(width * .83),
                                 round(line_y - U * .045)), fill=(207, 212, 221), width=2)
    number = hero.get("number", "7")
    _label(canvas, number, left, line_y, U * .17, U * .20, False, True, accent)
    proof = hero.get("proof", ["platforms", "one view"])
    for i, line in enumerate(proof[:2]):
        _label(canvas, line, left + U * .15, line_y + U * (.04 + i * .048),
               U * .035, width - U * .15, cjk, i == 1, ink)
    _label(canvas, hero.get("tagline", "Made for a wider view."), left, H * .88,
           U * .025, width, cjk, False, muted)
    _label(canvas, "FLATRADAR  /  DESKTOP", left, H * .925, U * .017,
           width, False, True, muted)
    return [canvas.crop((0, 0, W, H)).convert("RGB"),
            canvas.crop((W, 0, 2 * W, H)).convert("RGB")]


def build_mac_page(spec, copy, src, idx, dev_spec, cjk):
    """Compose one Mac poster with a readable desktop window on the right."""
    W, H = dev_spec["size"]
    U = min(W, H)
    canvas = _mac_background((W, H), idx)
    hero = copy.get("_mac", {})
    item = hero.get(spec["out"], {})
    margin = round(U * .085)
    _, ink, accent, _ = THEMES[idx % len(THEMES)]
    _brand(canvas, idx, margin, U, ink, accent)
    title = item.get("title", [spec["out"], ""])
    width = round(W * .27)
    yy = H * .22
    for i, line in enumerate(title[:2]):
        if not line:
            continue
        height = _label(canvas, line, margin, yy, U * (.080 if i == 0 else .105),
                        width, cjk, i == 1, ink if i == 0 else accent)
        yy += height + U * .022
    for line in item.get("body", []):
        height = _label(canvas, line, margin, yy + U * .018, U * .027,
                        width, cjk, False, (100, 108, 122))
        yy += height + U * .010
    source = spec["src"]
    with Image.open(src / f"{source}.png") as shot:
        card = _mac_window(shot.convert("RGB"), round(W * .62), round(H * .69),
                           radius=34)
    x = round(W * .34)
    y = round(H * .19)
    _place(canvas, card, x, y, W, H)
    footer = item.get("footer", "")
    if footer:
        _label(canvas, footer, margin, H * .86, U * .024, width, cjk, False,
               (100, 108, 122))
    return canvas.convert("RGB")


def build(spec, copy, src, idx, dev_spec, cjk, device_key, badges=None):
    W, H = dev_spec["size"]
    U, land = min(W, H), W > H

    def load(name):
        with Image.open(src / f"{name}.png") as image:
            return _device(image.convert("RGB"), device_key, dev_spec["island"])

    # 文本列 / 设备列。横屏给设备 0.555W——原来只给 0.455W，横机身在那个宽度下
    # 被**宽度**卡住（只长到 943 高，可用 1507），高度白白空掉三分之一。
    left, right = _land_columns(W, H)[2:] if land else (W * .09, W * .91)
    start = H * .16 if land else H * .315
    bottom = H * .94

    # 先摆好设备、拿到它们的包围盒，再据此画衬底板——板的形状必须跟着机身走。
    placed = []
    if isinstance(spec["src"], list):
        gap = U * .030
        cell_w = (right - left - gap) / 2
        cell_h = (bottom - start - gap) / 2
        devs = [_resize_fit(load(n), cell_w, cell_h) for n in spec["src"]]
        # 格子按可用区等分，机身按比例缩进去，两者形状对不上——横机身塞进
        # 竖格子只长到格高的 70%，四个格子各自在**下方**空一条。改成用机身
        # 实际尺寸重新组网格，再把整块居中：空白挪到外圈当留白，不再是四个洞。
        rw = max(d.width for d in devs)
        rh = max(d.height for d in devs)
        gx = left + (right - left - (2 * rw + gap)) / 2
        gy = start + (bottom - start - (2 * rh + gap)) / 2
        for i, d in enumerate(devs):
            placed.append((d, gx + (i % 2) * (rw + gap) + (rw - d.width) / 2,
                              gy + (i // 2) * (rh + gap) + (rh - d.height) / 2))
    else:
        dev = load(spec["src"])
        # 竖屏手机刻意从底部出血；平板整台留全。
        max_h = H * 1.045 - start if dev_spec["island"] and not land else bottom - start
        if land:
            # 横机身宽高比 1.31，和文字列并排时被**宽度**卡死：设备带高 1610，
            # 机身只长到 1127，上下白空 483px（占带高 30%）。要让它改由高度
            # 卡住，设备列得有 2104px 宽，文字列就只剩 194px——标题没法看。
            # 折中：设备列右缘推到画布外 LAND_BLEED，机身按高度吃满，右边裁掉
            # 一条。裁的是 iPad 右侧那片留白居多的区域，比上下空着划算。
            dev = _resize_fit(dev, W * LAND_BLEED - left, max_h)
            x = left
        else:
            dev = _resize_fit(dev, right - left, max_h)
            x = (left + right - dev.width) / 2
        y = start + (bottom - start - dev.height) / 2 if land else start
        placed.append((dev, x, y))

    box = (min(x for _, x, _ in placed), min(y for _, _, y in placed),
           max(x + d.width for d, x, _ in placed), max(y + d.height for d, _, y in placed))
    if land:
        px, py = U * LAND_PANEL_PAD, U * .055
        # 机身出血时衬底板得跟着顶到画布边，否则右侧会露出一条底色。
        rx = W if box[2] > W * .985 else min(box[2] + px, W * .985)
        rect = (round(box[0] - px), round(box[1] - py), round(rx), round(box[3] + py))
    else:
        rect = None

    canvas = _background((W, H), idx, rect)
    top = _headline(canvas, copy, idx, cjk)
    if idx == 0 and badges:
        top = _feature(canvas, badges, top, idx, cjk)
    for dev, x, y in placed:
        _place(canvas, dev, round(x), round(y), W, H)
    return canvas.convert("RGB")


def build_hero_pair(strings, src, dev_spec, cjk, device_key):
    """An editorial cover: one promise, one proof point, one spanning device."""
    W, H = dev_spec["size"]
    # 跨页专用的**纵向尺度**，不能直接用 U = min(W,H)。
    #
    # U/H 在两种朝向下差 2.2 倍（竖屏 0.46、横屏 1.00），于是同一个 `U * k`
    # 纵向偏移在横屏上占页高的比例翻了一倍多：标题、正文一路把数字块顶到
    # 1706，而页脚钉死在 H*.89 = 1837，数字块底部 1997 直接压上去。
    # S 让两种朝向下"占页高的比例"一致——竖屏时 S≈U，横屏时按页高折算。
    U = min(W, H)
    S = min(U, H * .55)
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
    # 锚点是**接缝**，右页留白降级成兜底。
    #
    # 原先只有 `x = 2W - S*.105 - dev.width` 一条：它保证的是右页边距，设备能
    # 不能够回接缝，全看它自己有多宽。竖屏设备占跨页宽 57%，自然压过接缝；
    # 横屏跨页宽 5504，而设备被短边 H*.88 卡在 1584（只占 29%），x 落到 3801
    # ——接缝在 2752，设备整个待在页 2，页 1 变成没有设备的纯文字页。
    #
    #            2W     设备宽   x 旧 → 新    页1 设备宽 旧 → 新
    #   iphone67 2640   1494    1007 → 1006      313 → 314
    #   ipad13l  5504   1584    3801 → 2420        0 → 332
    #
    # 取两者较小值：先按「露在页 1 上的比例」定位，右页留白仍不许被越过。
    SEAM_OVERHANG = .21
    x = min(round(W - dev.width * SEAM_OVERHANG),
            round(2 * W - S * .105 - dev.width))
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
    width = min(round(W * .76), left_edge - left - round(S * .035))
    hero = strings.get("_hero", {})
    title = hero.get("title", [strings["00-Alerts"]["lead"], strings["00-Alerts"]["head"]])
    body = hero.get("body", [])

    # Compact horizontal brand lockup; the headline carries the visual weight.
    side = round(S * .070)
    brand_y = round(H * .065)
    icon = _logo(0, side)
    if icon:
        canvas.alpha_composite(icon, (left, brand_y))
    _label(canvas, "FlatRadar", left + side + S * .022, brand_y + S * .015,
           S * .041, width - side - S * .022, False, True, ink)

    # Fit both headline lines to one size, preserving the typographic hierarchy.
    size = min(_fit(line, round(U * (.143 if cjk else .127)), width, cjk, True).size
               for line in title)
    yy = H * .235
    for i, line in enumerate(title):
        height = _label(canvas, line, left, yy, size, width, cjk, True, ink if i == 0 else accent)
        yy += height + S * .033
    yy += S * .040
    for line in body:
        height = _label(canvas, line, left, yy, S * .033, width, cjk, False, muted)
        yy += height + S * .017

    # A single evidence block replaces three evenly spaced feature labels.
    proof_y = max(H * .66, yy + S * .10)
    d.line((left, round(proof_y - S * .055), left + round(width * .91),
            round(proof_y - S * .055)), fill=(207, 212, 221), width=max(2, round(S * .001)))
    # 数字从 `_hero` 自己取，不再伸手去够 `_badges[0][0]`。
    # 那个字段是给单页版的胶囊用的，改胶囊文案（把数字写进句子里）时它被
    # 清成空串，封面这个大数字就跟着没了——两处共用一个字段却各有各的
    # 用法，改一处必然打断另一处。
    value = strings.get("_hero", {}).get("number", "7")
    _label(canvas, value, left, proof_y, S * .19, S * .20, False, True, accent)
    for i, line in enumerate(hero.get("proof", ["platforms", "One place."])):
        _label(canvas, line, left + S * .17, proof_y + U * (.045 + i * .049),
               S * .036, width - S * .17, cjk, i == 1, ink)

    # Small footer belongs to the left page; it never rides over the device.
    footer_y = H * .89
    _label(canvas, hero.get("tagline", ""), left, footer_y, S * .026, width, cjk, False, muted)
    _label(canvas, "FLATRADAR  /  NETHERLANDS", left, footer_y + S * .051,
           S * .017, width, False, True, muted)
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
    dev_spec = DEVICES[args.device]
    is_mac = dev_spec.get("kind") == "mac"
    plan = MAC_PLAN if is_mac else PLAN
    # Preflight the whole sequence so missing inputs cannot silently produce a partial set.
    for spec in plan:
        # The Mac hero is a continuous two-page spread, so its first two
        # filenames intentionally have no per-page copy.  The remaining pages
        # use the locale's `_mac` block.
        if is_mac:
            if spec["out"] not in ("00-Overview", "01-Listings") \
                    and spec["out"] not in strings.get("_mac", {}):
                ap.error(f"缺少 Mac 文案：{spec['out']}")
        elif spec["out"] not in strings:
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
    pair = (build_mac_hero_pair(strings, args.src, dev_spec, args.lang.startswith("zh"))
            if is_mac else
            build_hero_pair(strings, args.src, dev_spec, args.lang.startswith("zh"), args.device))
    for idx, spec in enumerate(plan):
        if idx < 2:
            image = pair[idx]
        elif is_mac:
            image = build_mac_page(spec, strings, args.src, idx, dev_spec,
                                   args.lang.startswith("zh"))
        else:
            image = build(spec, strings[spec["out"]], args.src, idx, dev_spec,
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
