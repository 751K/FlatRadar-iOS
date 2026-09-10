#!/usr/bin/env python3
"""生成登录页那条运河天际线（`Assets.xcassets/SignInSkyline.imageset`）。

来源
----
    FlatRadar/AppIcon.icon/Assets/1-houses[-dark].svg
    FlatRadar/AppIcon.icon/Assets/2-windows[-dark].svg
    FlatRadar/AppIcon.icon/Assets/3-water[-dark].svg

也就是 App 图标**自己的那三层**，一个字节都不改：路径、圆角、配色全部原样搬过来，
只做取景。

产出的是**一"幅"**，不是一条
---------------------------
三栋房子 + 一段运河 + 反射，横向正好裹住 x∈[127.5, 786.5]。真正的天际线由
`LoginView.skyline` 在 SwiftUI 里横着摆 N 幅拼出来，N 由屏幕宽度算。

为什么不在这里就拼成一条：设计稿三种布局要的幅数**不一样**——
iPhone 3 幅（`FlatRadar iOS - Sign in.dc.html`）、iPad 竖屏 4 幅、iPad 横屏左栏
3 幅，而且每幅的显示尺寸也不同（房子在 iPad 上更大，不是"更多幅"）。烤死幅数就
得出三份素材；出一幅、由布局决定摆几遍，一份就够。

拼接处必须无缝，所以运河线要重画
------------------------------
`3-water.svg` 里的 `canal-line` 是按图标的构图切的（x 89.5 起、宽 733），比这一幅
窄，两幅并排会在接缝处留一道明显的断口。这里把它换成**跨满整个 viewBox** 的一条
（x 127.5、宽 659），颜色仍取自 `3-water[-dark].svg`，不另立色值。

而且**圆角要去掉**（`rx=15` → `rx=0`）。图标里那条是胶囊形，两端各有一个 15 单位
的圆头；一幅一幅排过去，每个接缝处两个圆头对在一起就是一个明显的缺口——实测渲染
出来是一串"断成节的"运河。改成方头之后段与段严丝合缝。

看不出区别：设计稿那条的圆头落在 viewBox 外面（x 从 100 起、宽 2800，而可视区
从 127 开始），本来就被裁掉了，屏幕上从来没有出现过圆头。

取景
----
viewBox `127.5 82 659 730`：横向严丝合缝裹住一幅，纵向取自设计稿 iPad 那版
（y 82→812，红房子烟囱顶上留 8、反射底下留 25.5）。iPhone 那版取景略紧一点点
（90→795），换算到 140pt 高只差 3pt，不值得为它单出一份素材。

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

#: 一幅的横向范围，取自三栋房子的最左 / 最右（`1-houses.svg` 的路径数据）。
TILE_X, TILE_W = 127.5, 659.0
#: 纵向取景，见模块文档。
TILE_Y, TILE_H = 82.0, 730.0

#: 贯通整幅的运河线。y / 高沿用 `3-water.svg` 里 canal-line 的值，圆角去掉——
#: 见模块文档「拼接处必须无缝」。
CANAL = f'x="{TILE_X}" y="659" width="{TILE_W}" height="30"'

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

    `id` 一并去掉：这幅图会被摆很多遍，留着就是满文档重名 id。SVG 规范要求 id
    全文档唯一，重名的行为未定义——CoreSVG（图集渲染 SVG 用的就是它）对这类畸形
    文档向来只是「看着像能用」，不值得赌。这些 id 本来也只是设计源里的图层名。
    """
    text = (ICON / name).read_text(encoding="utf-8")
    inner = text.split(">", 1)[1] if text.lstrip().startswith("<?xml") else text
    inner = inner.split("<svg", 1)[1].split(">", 1)[1]
    inner = inner.rsplit("</svg>", 1)[0]
    return re.sub(r'\s+id="[^"]*"', "", inner).strip()


def _canal_fill(name: str) -> str:
    """运河线的颜色。在去 id 之前按 y=659 认那条 rect。"""
    text = (ICON / name).read_text(encoding="utf-8")
    m = re.search(r'<rect[^>]*?y="659"[^>]*?fill="(#[0-9A-Fa-f]{6})"[^>]*/>', text)
    if not m:
        raise SystemExit(f"{name} 里找不到 canal-line —— 图标图层结构变了，先看一眼再改这里")
    return m.group(1)


def _reflections(name: str) -> str:
    """水层里除去运河线的部分（三组倒影）。"""
    body = _body(name)
    return re.sub(r'<rect[^>]*?y="659"[^>]*?/>', "", body, count=1).strip()


def build(suffix: str) -> str:
    houses = _body(f"1-houses{suffix}.svg")
    windows = _body(f"2-windows{suffix}.svg")
    water = f"3-water{suffix}.svg"

    # 叠放顺序照 `icon.json` 的 groups[0].layers 反过来（那份是从上往下列的）：
    # 水在最底、房子压在上面、窗户最后开在墙上。运河线最后画，压住接缝。
    stack = "\n".join("  " + line for line in
                      (_reflections(water) + "\n" + houses + "\n" + windows).splitlines())

    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<!-- 由 output/icon/make-signin-skyline.py 从 AppIcon.icon/Assets 生成，勿手改。 -->\n"
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{TILE_X} {TILE_Y} {TILE_W} {TILE_H}">\n'
        + stack
        + f'\n  <rect id="canal-line" {CANAL} fill="{_canal_fill(water)}"/>\n'
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
