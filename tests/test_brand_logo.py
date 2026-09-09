"""登录页的品牌标必须跟 App 图标同源。

守的是什么
----------
2.2 换图标（`1839ba6`）时只换了 `FlatRadar/AppIcon.icon`，登录页的
`Assets.xcassets/BrandLogo.imageset` **漏了**。于是主屏是运河屋、点进去登录页
还是上一版的蓝色房子轮廓，两个图对不上，而且没有任何一处会喊：图集里有 6 张
PNG，尺寸对、格式对、构建绿。

漏掉是必然的。`BrandLogo` 是手工导出的 PNG，跟设计源之间没有任何自动关系，
`make-icons.py` 也不知道它存在。这条测试补上那个缺失的联系：**四角底色必须
等于 `icon.json` 里声明的图标背景**。图标底色一改，这里立刻红，直到重跑
`output/icon/make-brandlogo.py`。

顺带守住旧素材那个 bug：上一版把约 25.4% 的圆角烤进了 PNG、圆角外填纯白
(255,255,255)，而 iOS 遮罩只有 22.4%，切不掉那圈白。登录页因为自己裁
11/48 ≈ 22.9% 的圆角，白角大部分被盖住，所以这个 bug 在登录页上一直没被发现。
「四角必须彼此一致」这条断言同时挡住烤圆角和露白边。

为什么自己解 PNG
----------------
只为读 4 个像素就往 CI 装 Pillow 不划算（`requirements-dev.txt` 目前只有
pytest / PyJWT / PyYAML）。而用 `importorskip` 挡掉，等于这些断言在 CI 上
根本不跑——`test_ios_dark_icon.py` 里已经做过同样的取舍。BrandLogo 是 8 位
真彩、非隔行，标准库的 zlib 加一段反滤波就够。
"""
from __future__ import annotations

import json
import zlib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "FlatRadar" / "AppIcon.icon"
IMAGESET = ROOT / "FlatRadar" / "Assets.xcassets" / "BrandLogo.imageset"

#: `LoginView` 里 `Image("BrandLogo")` 的 frame 是 48×48pt。
SCALES = {"": 48, "@2x": 96, "@3x": 144}
VARIANTS = {"light": None, "dark": "dark"}     # 文件名前缀 → icon.json 的 appearance


def _read_png(path: Path) -> tuple[int, int, list[list[tuple[int, int, int]]]]:
    """→ (宽, 高, 像素[y][x] = (r,g,b))。只支持 8 位真彩、非隔行。"""
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} 不是 PNG"
    pos, idat, hdr = 8, bytearray(), None
    while pos < len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            hdr = (int.from_bytes(body[0:4], "big"), int.from_bytes(body[4:8], "big"),
                   body[8], body[9], body[12])
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length
    w, h, depth, color, interlace = hdr
    assert depth == 8 and color in (2, 6) and interlace == 0, \
        f"{path.name}: 位深 {depth} / 色型 {color} / 隔行 {interlace}，这个解码器不支持"
    ch = 3 if color == 2 else 4
    raw, stride = zlib.decompress(bytes(idat)), w * ch
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        filt, line = raw[p], bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            x = line[i]
            if filt == 1:
                x += a
            elif filt == 2:
                x += b
            elif filt == 3:
                x += (a + b) // 2
            elif filt == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                x += a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = x & 0xFF
        rows.append([tuple(line[i:i + 3]) for i in range(0, stride, ch)])
        prev = line
    return w, h, rows


def _icon_background(appearance: str | None) -> tuple[int, int, int]:
    """从 icon.json 读图标底色 → 0–255 三元组。"""
    fills = json.loads((ICON / "icon.json").read_text())["fill-specializations"]
    for entry in fills:
        if entry.get("appearance") == appearance:
            r, g, b, *_ = (float(v) for v in
                           entry["value"]["solid"].split(":", 1)[1].split(","))
            return round(r * 255), round(g * 255), round(b * 255)
    raise AssertionError(f"icon.json 里没有 appearance={appearance} 的 fill")


@pytest.mark.parametrize("variant", sorted(VARIANTS))
@pytest.mark.parametrize("suffix", sorted(SCALES))
def test_brand_logo_exists_at_every_scale(variant, suffix):
    p = IMAGESET / f"{variant}{suffix}.png"
    assert p.is_file(), f"{p} 不存在——跑 python3 output/icon/make-brandlogo.py"
    w, h, _ = _read_png(p)
    want = SCALES[suffix]
    assert (w, h) == (want, want), \
        f"{p.name} 是 {w}×{h}，登录页 48pt 的 {suffix or '1x'} 应该是 {want}×{want}"


@pytest.mark.parametrize("variant", sorted(VARIANTS))
@pytest.mark.parametrize("suffix", sorted(SCALES))
def test_corners_are_uniform(variant, suffix):
    """满幅底色，不许烤圆角。

    旧素材烤了 25.4% 的圆角、外面填白，iOS 22.4% 的遮罩切不掉。登录页自己裁
    11pt 圆角，所以白角当年没被看见——这条断言不依赖肉眼。
    """
    w, h, px = _read_png(IMAGESET / f"{variant}{suffix}.png")
    corners = {px[0][0], px[0][w - 1], px[h - 1][0], px[h - 1][w - 1]}
    assert len(corners) == 1, \
        f"{variant}{suffix}.png 四角不一致 {sorted(corners)}——底色没有满幅"


@pytest.mark.parametrize("variant, appearance", sorted(VARIANTS.items()))
def test_brand_logo_matches_the_app_icon_background(variant, appearance):
    """登录页的标和主屏图标必须是同一版设计。

    换图标只改 `.icon` 而忘了重出 BrandLogo，就挂在这里。
    """
    want = _icon_background(appearance)
    w, h, px = _read_png(IMAGESET / f"{variant}@3x.png")
    got = px[0][0]
    assert all(abs(a - b) <= 1 for a, b in zip(got, want)), (
        f"{variant}@3x.png 的底色是 {got}，而 icon.json 声明的是 {want}。"
        "图标换了但登录页的标没重出——跑 python3 output/icon/make-brandlogo.py")
