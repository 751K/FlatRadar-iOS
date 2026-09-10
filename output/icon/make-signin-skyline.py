#!/usr/bin/env python3
"""生成登录页那条运河天际线（`Assets.xcassets/SignInSkyline.imageset`）。

来源
----
    FlatRadar/AppIcon.icon/Assets/1-houses[-dark].svg
    FlatRadar/AppIcon.icon/Assets/2-windows[-dark].svg
    FlatRadar/AppIcon.icon/Assets/3-water[-dark].svg

也就是 App 图标**自己的那三层**，一个字节都不改：路径、圆角、配色全部原样搬过
来，只做排布。设计稿 `FlatRadar iOS - Sign in.dc.html` 里那段内联 SVG 就是这么
拼的——把图标里的三栋房子当成一个「单元」，横着摆三遍（中间那遍水平镜像，避免
一眼看出是复制），底下压一条贯通的运河线。

为什么要一个脚本，而不是把 SVG 手抄进图集
----------------------------------------
`BrandLogo` 那次的教训（见 `make-brandlogo.py` 和 `tests/test_brand_logo.py`）：
2.2 换图标时只换了 `AppIcon.icon`，登录页那张手工导出的图漏了，于是主屏是运河屋、
登录页还是上一版的蓝房子，构建全绿、没有任何一处会喊。

天际线比 BrandLogo 更容易漏——它看着像「插画」，不像「图标」，换图标的人更不会
想到它。所以这里从一开始就把链接上：素材只有一份（`AppIcon.icon/Assets`），
这个脚本负责排布，`tests/test_signin_skyline.py` 负责在两者脱钩时立刻变红。

排布参数
--------
一个单元在图标坐标系里横跨 x∈[127.5, 786.5]（宽 659），三份并排：

    #1  原样
    #2  translate(1574.5,0) scale(-1,1)   → 镜像后落在 [788, 1447]
    #3  translate(1320,0)                 → [1447.5, 2106.5]

viewBox 取 `127 90 1980 705`，正好裹住这三份 + 反射，宽高比 2.81:1。
393pt 宽的 iPhone 铺满宽度时高度正是 140pt，与设计稿一致。

运河线只画一条
--------------
`3-water.svg` 里的 `canal-line` 是按**单个**图标的宽度切的（x 89.5 起、宽 733），
三份并排会留下两道明显的断口。所以把它从单元里摘出来，改成一条贯通全幅的
（x 100、宽 2100），颜色仍取自 `3-water[-dark].svg`，不另立色值。

    python3 output/icon/make-signin-skyline.py
"""
from __future__ import annotations

import pathlib
import re
import sys

HERE = pathlib.Path(__file__).parent
ROOT = HERE.parent.parent
ICON = ROOT / "FlatRadar" / "AppIcon.icon" / "Assets"
IMAGESET = ROOT / "FlatRadar" / "Assets.xcassets" / "SignInSkyline.imageset"

#: 三份单元各自的 transform。None = 原样。
TILES = (None, "translate(1574.5,0) scale(-1,1)", "translate(1320,0)")

#: 贯通全幅的运河线。y/高/圆角沿用 `3-water.svg` 里 canal-line 的值。
CANAL = 'x="100" y="659" width="2100" height="30" rx="15"'

VIEWBOX = "127 90 1980 705"

VARIANTS = {"skyline.svg": "", "skyline-dark.svg": "-dark"}

CONTENTS = """{
  "images" : [
    { "filename" : "skyline.svg", "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "skyline-dark.svg", "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "preserves-vector-representation" : true }
}
"""


def _body(name: str) -> str:
    """取出一个图标图层 `<svg>` 里的内容，去掉 XML 声明、外壳和 `id`。

    `id` 必须去掉：一个单元要摆三遍，留着就是三份重名 id。SVG 规范里 id 全文档
    唯一，重名的行为未定义——CoreSVG（图集渲染 SVG 用的就是它）对这类畸形文档
    向来只是「看着像能用」，不值得赌。这里的 id 本来也只是设计源里的图层名。
    """
    text = (ICON / name).read_text(encoding="utf-8")
    inner = text.split(">", 1)[1] if text.lstrip().startswith("<?xml") else text
    inner = inner.split("<svg", 1)[1].split(">", 1)[1]
    inner = inner.rsplit("</svg>", 1)[0]
    return re.sub(r'\s+id="[^"]*"', "", inner).strip()


def _split_water(body: str) -> tuple[str, str]:
    """→ (运河线的 fill, 去掉运河线之后的反射)。"""
    m = re.search(r"<rect[^>]*?y=\"659\"[^>]*?fill=\"(#[0-9A-Fa-f]{6})\"[^>]*/>", body)
    if not m:
        raise SystemExit("3-water.svg 里找不到 canal-line —— 图标图层结构变了，先看一眼再改这里")
    return m.group(1), (body[:m.start()] + body[m.end():]).strip()


def build(suffix: str) -> str:
    houses = _body(f"1-houses{suffix}.svg")
    windows = _body(f"2-windows{suffix}.svg")
    canal_fill, reflections = _split_water(_body(f"3-water{suffix}.svg"))

    # 单元内部的叠放顺序照 `icon.json` 的 groups[0].layers 反过来（那份是从上往下
    # 列的）：水在最底、房子压在上面、窗户最后开在墙上。
    unit = "\n".join(("    " + line for line in
                      (reflections + "\n" + houses + "\n" + windows).splitlines()))

    tiles = []
    for transform in TILES:
        open_tag = "  <g>" if transform is None else f'  <g transform="{transform}">'
        tiles.append(f"{open_tag}\n{unit}\n  </g>")

    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<!-- 由 output/icon/make-signin-skyline.py 从 AppIcon.icon/Assets 生成，勿手改。 -->\n"
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{VIEWBOX}">\n'
        + "\n".join(tiles)
        + f'\n  <rect id="canal-line" {CANAL} fill="{canal_fill}"/>\n'
        "</svg>\n"
    )


def main() -> int:
    if not ICON.is_dir():
        print(f"缺素材：{ICON}")
        return 1
    IMAGESET.mkdir(parents=True, exist_ok=True)
    for filename, suffix in VARIANTS.items():
        (IMAGESET / filename).write_text(build(suffix), encoding="utf-8")
        print(f"写出 {IMAGESET.relative_to(ROOT) / filename}")
    (IMAGESET / "Contents.json").write_text(CONTENTS, encoding="utf-8")
    print(f"写出 {IMAGESET.relative_to(ROOT) / 'Contents.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
