#!/usr/bin/env python3
"""生成登录页用的品牌标（`Assets.xcassets/BrandLogo.imageset`）。

来源
----
    output/icon/AppIcon.png        浅色
    output/icon/AppIcon-Dark.png   深色

这两张由 `output/icon/make-icons.py` 从设计源 SVG 生成，**满幅、无 alpha、
不烤圆角**。`LoginView` 自己用 `RoundedRectangle(cornerRadius: 11)` 裁，所以
这里只负责缩放，一个圆角都不能烤进去。

为什么需要这个脚本
------------------
2.2 换图标（`1839ba6`）时只换了 `AppIcon.icon`，登录页的 `BrandLogo` 漏了——
它是 2026-09-04 从**上一版**图标出的：蓝色房子轮廓、四角纯白 (255,255,255)。
也就是说换完图标之后，主屏是运河屋、点进去登录页还是旧房子，两个图对不上。

漏掉是必然的：`BrandLogo` 是 6 张手工导出的 PNG，跟设计源之间没有任何自动
关系，`make-icons.py` 也不知道它的存在。所以这里补上这条链，并配一条测试
（`tests/test_brand_logo.py`）把「登录页的标 = App 图标」钉成断言。

四角必须一致
------------
和 `make-logo.py` 同一个检查。旧素材把约 25.4% 的圆角烤进 PNG、圆角外填纯白，
而 iOS 遮罩只有 22.4%，切不掉那圈白——主屏图标四角挂白牙。登录页因为自己
裁 11/48 ≈ 22.9% 的圆角，白角大部分被盖住，所以这个 bug 在登录页上不明显，
一直没人发现。满幅底色是唯一能同时喂饱两边的形态。

    python3 output/icon/make-brandlogo.py
"""
from __future__ import annotations

import pathlib

from PIL import Image

HERE = pathlib.Path(__file__).parent
IMAGESET = HERE.parent.parent / "FlatRadar" / "Assets.xcassets" / "BrandLogo.imageset"

#: `LoginView` 里的 frame 是 48×48pt，所以 1x/2x/3x = 48/96/144。
#: 保留 1x：universal imageset 缺 1x 时 Xcode 会报 unassigned-children 警告。
SCALES = {"": 48, "@2x": 96, "@3x": 144}

SOURCES = {"light": "AppIcon.png", "dark": "AppIcon-Dark.png"}


def main() -> int:
    for variant, src in SOURCES.items():
        p = HERE / src
        if not p.is_file():
            print(f"缺素材：{p}\n先跑 python3 output/icon/make-icons.py")
            return 1
        with Image.open(p) as image:
            full = image.convert("RGB")
        for suffix, side in SCALES.items():
            out = full.resize((side, side), Image.LANCZOS)
            corners = {out.getpixel(xy) for xy in
                       ((0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1))}
            if len(corners) != 1:
                print(f"✗ {variant}{suffix} 四角不一致 {corners}"
                      "——素材不是满幅底色，登录页上会露边")
                return 1
            dst = IMAGESET / f"{variant}{suffix}.png"
            out.save(dst)
            print(f"✓ {dst.name:14} {out.size}  四角 {corners.pop()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
