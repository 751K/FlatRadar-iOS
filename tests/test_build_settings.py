"""并发相关的构建设置：语言模式必须是 6.0，而且每一处都得是。

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
2. **改了一半**。SWIFT_VERSION 在 pbxproj 里每个 target 的 Debug/Release
   各出现一次。只改 Release 的话，Debug 构建仍在 Swift 5 模式下编译，
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

# 5 个 target（FlatRadar / FlatRadarMac / FlatRadarMacTests / FlatRadarTests /
# FlatRadarUITests）× Debug/Release。
#
# 2026-09-09 从 6 改到 8 再到 10：先加 macOS target，再加它的测试目标
# （docs/MACOS.md Phase 1）。
# 注意 Core 的语言模式**不在这里**——它迁进本地 SwiftPM 包之后由
# `FlatRadarCore/Package.swift` 的 `.swiftLanguageMode(.v6)` 管，
# 见下面 test_core_package_pins_language_mode_and_isolation。
EXPECTED_CONFIG_COUNT = 10


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


def test_all_configurations_are_covered():
    """挡「改了一半」：漏掉的那几处会安静地留在旧模式里。"""
    versions = _SWIFT_VERSION.findall(_source())
    assert len(versions) == EXPECTED_CONFIG_COUNT, (
        f"SWIFT_VERSION 出现 {len(versions)} 次，预期 {EXPECTED_CONFIG_COUNT} 次"
        "（5 个 target × Debug/Release）。加减 target 时请一并更新这条测试，"
        "顺便确认新 target 也是 6.0。")


def test_core_package_pins_language_mode_and_isolation():
    """Core 迁成本地 SwiftPM 包后，隔离设置不再从 app target 继承。

    `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 是 **Xcode target** 的构建设置，
    对包无效；包必须在 `Package.swift` 里自己声明 `.defaultIsolation(MainActor.self)`。
    漏了的话 Core 会退回 nonisolated 默认——编译多半仍然通过，但 `@MainActor` /
    `nonisolated` 标注的含义整体漂移，而没有任何一处会喊。
    """
    manifest = (PBXPROJ.parent.parent / "FlatRadarCore" / "Package.swift").read_text(encoding="utf-8")
    assert ".defaultIsolation(MainActor.self)" in manifest, \
        "Package.swift 没声明默认 MainActor 隔离，Core 的隔离语义会跟 app 不一致"
    assert ".swiftLanguageMode(.v6)" in manifest, \
        "Package.swift 没钉 Swift 6 语言模式，并发错误会降级成警告"


def test_the_app_target_still_defaults_to_main_actor_isolation():
    """模型层那几个 nonisolated 标注是为了从这个默认里退出来。默认没了，它们就成了谜。"""
    values = {v.strip() for v in _DEFAULT_ISOLATION.findall(_source())}
    assert values == {"MainActor"}, (
        f"SWIFT_DEFAULT_ACTOR_ISOLATION = {sorted(values) or '（缺失）'}，预期 MainActor。"
        "这是 MapClustering / MapListing 上那些 `nonisolated` 存在的理由；"
        "去掉默认隔离之后它们会显得多余，而下一个人看不出为什么。")
