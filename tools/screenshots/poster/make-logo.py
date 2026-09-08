#!/usr/bin/env python3
"""生成海报用的品牌标（logo-light.png / logo-dark.png）。

来源
----
    output/icon/AppIcon.png        浅色
    output/icon/AppIcon-Dark.png   深色

这两张由 `output/icon/make-icons.py` 从设计源 SVG 生成，**满幅、无 alpha、
不烤圆角**。海报里的 `_logo()` 自己套圆角掩膜，所以这里只需要缩放。

以前这个脚本在做什么（现在不用了）
----------------------------------
旧素材是 `Assets.xcassets/AppIcon.appiconset/AppIcon.png`，那张把圆角烤进去了、
圆角外面填纯白。烤的圆角约占边长 25.4%，而 iOS 遮罩是 22.4%——系统切不掉那圈
白底，于是主屏图标四角挂白牙、海报上 logo 周围一圈白边（浅底主题看不出，在
THEMES[4] 那种底色上很明显）。

所以旧版这里有一套「渐变外推」：取一个比烤进去的圆角更圆的保守内区，认定其中
都是真图案，外面每个像素取最近的内区像素的颜色，把白角填掉。

2.2 起图标重做，设计源本身就是满幅的，白底问题从源头没了——外推那段整个删掉，
连带 SciPy 依赖也不再需要。

    python3 tools/screenshots/poster/make-logo.py
"""
from __future__ import annotations

import pathlib

from PIL import Image

HERE = pathlib.Path(__file__).parent
ICONS = HERE.parent.parent.parent / "output" / "icon"
SIDE = 512                 # 海报最大用到 U*.044 = 91px，512 留足余量


def main() -> int:
    for src, dst in (("AppIcon.png", "logo-light.png"),
                     ("AppIcon-Dark.png", "logo-dark.png")):
        p = ICONS / src
        if not p.is_file():
            print(f"缺素材：{p}\n先跑 python3 output/icon/make-icons.py")
            return 1
        with Image.open(p) as image:
            out = image.convert("RGB").resize((SIDE, SIDE), Image.LANCZOS)
        corners = {out.getpixel(xy) for xy in
                   ((0, 0), (SIDE - 1, 0), (0, SIDE - 1), (SIDE - 1, SIDE - 1))}
        if len(corners) != 1:
            print(f"✗ {dst} 四角不一致 {corners}——素材不是满幅底色，海报上会露边")
            return 1
        out.save(HERE / dst)
        print(f"✓ {dst}  {out.size}  四角 {corners.pop()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
