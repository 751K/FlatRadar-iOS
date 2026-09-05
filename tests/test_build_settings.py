"""并发相关的构建设置：语言模式必须是 6.0，而且六处都得是。

为什么值得一条测试
------------------
2026-09-05 之前，项目里是这样的组合：

    工具链（编译器）  Apple Swift 6.4
    SWIFT_VERSION     5.0          ← 语言模式还停在 Swift 5

两者是**两回事**：工具链决定能用哪些语法，语言模式决定并发检查是警告还是错误。
Swift 5 模式下，跨 actor 调用只发一条警告：

    warning: main actor-isolated static method 'cluster(...)' cannot be called
             from outside of the actor; this is an error in the Swift 6 language mode

「this is an error in the Swift 6 language mode」这半句只可能出现在**还不是**
Swift 6 模式的时候。编译照样过、包照样上架，而 MapView 里那句「聚类跑在后台」
的注释其实没有编译器背书——它名义上是主 actor 的函数，只是被放行了。

这条测试挡什么
--------------
1. **回退**。Xcode 的 "Update to recommended settings" 和手工改设置都可能把
   SWIFT_VERSION 写回去。写回去之后，所有并发错误重新降级成警告，构建依然是
   绿的——没有任何一处会喊。
2. **改了一半**。SWIFT_VERSION 在 pbxproj 里出现 6 次（3 个 target ×
   Debug/Release）。只改 Release 的话，Debug 构建仍在 Swift 5 模式下编译，
   于是「本地编得过、CI 编不过」或者反过来。
3. **默认隔离被摘掉**。SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor 是这套代码
   的前提：模型层那几个 `nonisolated` 标注（MapClustering / MapListing /
   NavigationCoordinator.isValidListingID / MapStore.price）都是为了从这个
   默认里显式退出来。摘掉它，那些标注会从「必需」变成「多余」，而下一个人
   看不出它们为什么在那儿。
"""
from __future__ import annotations

import re
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parent.parent / "FlatRadar.xcodeproj" / "project.pbxproj"

_SWIFT_VERSION = re.compile(r"SWIFT_VERSION = ([^;]+);")
_DEFAULT_ISOLATION = re.compile(r"SWIFT_DEFAULT_ACTOR_ISOLATION = ([^;]+);")

# 3 个 target（FlatRadar / FlatRadarTests / FlatRadarUITests）× Debug/Release。
EXPECTED_CONFIG_COUNT = 6


def _source() -> str:
    return PBXPROJ.read_text(encoding="utf-8")


def test_every_configuration_is_in_the_swift_6_language_mode():
    versions = _SWIFT_VERSION.findall(_source())
    assert versions, "pbxproj 里一处 SWIFT_VERSION 都没有——正则或文件结构变了"
    stale = [v.strip() for v in versions if v.strip() != "6.0"]
    assert not stale, (
        f"有 {len(stale)}/{len(versions)} 处 SWIFT_VERSION 不是 6.0：{sorted(set(stale))}。"
        "语言模式退回 5 之后，所有跨 actor 的并发错误会重新降级成警告，"
        "构建照样是绿的，没有任何一处会喊。")


def test_all_six_configurations_are_covered():
    """挡「改了一半」：漏掉的那几处会安静地留在旧模式里。"""
    versions = _SWIFT_VERSION.findall(_source())
    assert len(versions) == EXPECTED_CONFIG_COUNT, (
        f"SWIFT_VERSION 出现 {len(versions)} 次，预期 {EXPECTED_CONFIG_COUNT} 次"
        "（3 个 target × Debug/Release）。加减 target 时请一并更新这条测试，"
        "顺便确认新 target 也是 6.0。")


def test_the_app_target_still_defaults_to_main_actor_isolation():
    """模型层那几个 nonisolated 标注是为了从这个默认里退出来。默认没了，它们就成了谜。"""
    values = {v.strip() for v in _DEFAULT_ISOLATION.findall(_source())}
    assert values == {"MainActor"}, (
        f"SWIFT_DEFAULT_ACTOR_ISOLATION = {sorted(values) or '（缺失）'}，预期 MainActor。"
        "这是 MapClustering / MapListing 上那些 `nonisolated` 存在的理由；"
        "去掉默认隔离之后它们会显得多余，而下一个人看不出为什么。")
