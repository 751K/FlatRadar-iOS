"""iOS 深色 App 图标的守卫。

从 751K/holland2stay-monitor 的 tests/test_dark_icon.py 拆出来。那个文件同时守
网页资源（static/logo*.png）和这个 iOS 图标；iOS 客户端迁出后，网页那半留在
后端仓库，这两条跟着 Assets.xcassets 过来。

守的是什么
----------
旧的 AppIcon-Dark.png 是一张去饱和的灰白图——在深色模式下**比浅色版还刺眼**。
它当时通过了所有人工检查，因为「有一张深色图标」这件事看起来是成立的。所以
这里不看「有没有」，只看像素：够不够暗、四角会不会在系统切圆角后露出亮边、
有没有透明像素。

PNG 用 zlib + struct 手动解，不引入 Pillow：Pillow 不是这个项目的依赖，而用
importorskip 挡掉又等于这些断言在 CI 上根本不跑——那和没有这些测试是一回事。
"""
from __future__ import annotations

import json
import struct
import zlib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
APPICON = ROOT / "FlatRadar" / "Assets.xcassets" / "AppIcon.appiconset"


# ── 极简 PNG 解码（8bit，颜色类型 2 / 6）────────────────────────────
def _decode_png(path: Path) -> tuple[int, int, list[tuple[int, int, int, int]]]:
    """返回 (宽, 高, 像素列表)，像素为 (R, G, B, A)。"""
    raw = path.read_bytes()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} 不是 PNG"

    pos, idat, width, height, ctype = 8, bytearray(), 0, 0, 0
    while pos < len(raw):
        (length,) = struct.unpack(">I", raw[pos:pos + 4])
        kind = raw[pos + 4:pos + 8]
        body = raw[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert depth == 8, f"{path.name} 位深 {depth}，本解码器只支持 8"
            assert ctype in (2, 6), f"{path.name} 颜色类型 {ctype} 不支持"
            assert body[12] == 0, f"{path.name} 是隔行扫描，本解码器不支持"
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length

    channels = 4 if ctype == 6 else 3
    data = zlib.decompress(bytes(idat))
    stride = width * channels
    out: list[tuple[int, int, int, int]] = []
    prev = bytearray(stride)
    at = 0
    for _ in range(height):
        filt = data[at]
        line = bytearray(data[at + 1:at + 1 + stride])
        at += 1 + stride
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if filt == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filt == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        for i in range(0, stride, channels):
            out.append((line[i], line[i + 1], line[i + 2],
                        line[i + 3] if channels == 4 else 255))
        prev = line
    return width, height, out


def _luma(px: tuple[int, int, int, int]) -> float:
    """WCAG 相对亮度。"""
    def lin(c: float) -> float:
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(px[0]) + 0.7152 * lin(px[1]) + 0.0722 * lin(px[2])




@pytest.fixture(scope="module")
def dark_icon():
    p = APPICON / "AppIcon-Dark.png"
    assert p.exists(), f"{p} 不存在"
    return _decode_png(p)


def test_ios_dark_icon_registered():
    contents = json.loads((APPICON / "Contents.json").read_text())
    dark = [img for img in contents["images"]
            if any(a.get("value") == "dark" for a in img.get("appearances", []))]
    assert len(dark) == 1, "AppIcon 里应当正好有一条 dark 外观条目"
    assert (APPICON / dark[0]["filename"]).exists()
    assert dark[0]["size"] == "1024x1024"


def test_ios_dark_icon_is_opaque_and_dark(dark_icon):
    """1024、不透明、够暗。旧那张灰白 AppIcon-Dark.png 在这里挂。"""
    w, h, px = dark_icon
    assert (w, h) == (1024, 1024)
    assert all(p[3] == 255 for p in px[::997]), "iOS 图标不能带透明像素"
    mean = sum(_luma(p) for p in px[::13]) / len(px[::13])
    assert mean < 0.25, f"AppIcon-Dark.png 平均亮度 {mean:.3f}，不算深色图标"
    # 四角也要是深色：留白底的话系统切圆角后会露出一圈亮边
    for corner in (px[0], px[w - 1], px[-w], px[-1]):
        assert _luma(corner) < 0.25, f"角落 {corner} 太亮"
