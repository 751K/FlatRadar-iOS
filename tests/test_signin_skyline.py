"""登录页那条天际线必须和 App 图标同源。

守的是什么
----------
和 `tests/test_brand_logo.py` 同一个 bug 的第二次：2.2 换图标（`1839ba6`）时
只换了 `FlatRadar/AppIcon.icon`，登录页那张手工导出的图漏了，于是主屏是运河屋、
点进去登录页还是上一版的蓝房子——图集里文件齐、尺寸对、构建全绿，没有任何一处
会喊。

天际线比 BrandLogo 更容易漏：它看着像「插画」不像「图标」，换图标的人更不会
想到它。所以它从一开始就不是手工素材——`output/icon/make-signin-skyline.py`
从 `AppIcon.icon/Assets` 的三层现拼，这条测试只做一件事：**把脚本再跑一遍，
和仓库里那两个文件逐字节比。** 图标改了而没重跑脚本，这里立刻红。

为什么比 BrandLogo 那条便宜得多
------------------------------
那边守的是 PNG，只为读 4 个像素就自己写了个 zlib 解码器（往 CI 装 Pillow 不
划算）。这边是 SVG——纯文本，脚本本身也不依赖任何第三方库，直接 import 进来
调 `build()` 就行。
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "output" / "icon" / "make-signin-skyline.py"
IMAGESET = ROOT / "FlatRadar" / "Assets.xcassets" / "SignInSkyline.imageset"

#: `LoginView.skylineSection` 按这个宽高比铺满宽度，改了 viewBox 就得改那边。
EXPECTED_VIEWBOX = "127 90 1980 705"


def _generator():
    spec = importlib.util.spec_from_file_location("make_signin_skyline", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def gen():
    assert SCRIPT.is_file(), f"缺生成脚本：{SCRIPT}"
    return _generator()


@pytest.mark.parametrize("filename,suffix", [("skyline.svg", ""), ("skyline-dark.svg", "-dark")])
def test_图集内容等于现拼的结果(gen, filename, suffix):
    """改了 `AppIcon.icon/Assets` 而没重跑脚本，就挂在这里。

    修法只有一条：

        python3 output/icon/make-signin-skyline.py
    """
    path = IMAGESET / filename
    assert path.is_file(), f"缺 {path}"
    assert path.read_text(encoding="utf-8") == gen.build(suffix), (
        f"{filename} 和 AppIcon.icon/Assets 脱钩了——"
        "重跑 python3 output/icon/make-signin-skyline.py"
    )


def test_两版颜色不一样(gen):
    """浅深两版必须真的是两套色。

    图标的 dark 素材（`*-dark.svg`）一旦漏掉，脚本会照样拼出一张图、测试照样
    绿——只是深色模式下那张插画是浅色的，压在 `#111C29` 上刺眼。
    """
    assert gen.build("") != gen.build("-dark")


def test_viewbox_没变(gen):
    """`LoginView` 那边按 1980:705 算插画高度，这里改了那边要跟着改。"""
    assert f'viewBox="{EXPECTED_VIEWBOX}"' in gen.build("")


def test_没有重名的_id(gen):
    """一个单元要摆三遍，源素材里的图层 `id` 必须被剥掉。

    SVG 规范要求 id 全文档唯一，重名的行为未定义。CoreSVG（图集渲染 SVG 用的
    就是它）对畸形文档向来只是「看着像能用」，不值得赌。
    """
    import re
    for suffix in ("", "-dark"):
        ids = re.findall(r'\bid="([^"]*)"', gen.build(suffix))
        assert ids == ["canal-line"], f"{suffix or 'light'} 版多出了 id：{ids}"
