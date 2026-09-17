"""所有 test plan 都不能待在会被打进 app 的目录里。

守的是什么
----------
`ci_scripts/ci_post_clone.sh` 会往截图 plan 里写**明文凭据**（Xcode Cloud 禁止
用 `TEST_RUNNER_` 前缀命名环境变量，只能绕道改仓库里的 plan 文件）。而
`FlatRadar/`、`FlatRadarMac/` 这些是 `PBXFileSystemSynchronizedRootGroup`——
扔进去的文件**自动**成为 app target 的资源，跟着 .app 一起打包。

两件事撞在一起就是：凭据随 App Store 包一起发出去。

这不是假想。2.2.0（Xcode Cloud build 349）的 App Store 导出包里实测有：

    Payload/FlatRadar.app/FlatRadar.xctestplan
    Payload/FlatRadar.app/Screenshots.xctestplan

当时没真的泄漏，只因为「iOS Build」那条 workflow 恰好没配 UI_TEST_USERNAME /
UI_TEST_PASSWORD，脚本原样跳过了注入（build log 里是「未设置 ... 跳过注入」）。
也就是说，离泄漏只差在网页上勾一个环境变量——而勾变量的人不会知道这条连锁。
所以把它钉死在测试里，而不是靠记性。

为什么扫全仓库而不是只盯某一份
------------------------------
原来这条检查只盯 Mac 那份截图 plan。可出事的恰恰是没人盯的 iOS 那两份。
所以这里改成扫出仓库里**每一个** `.xctestplan` 都过一遍——以后新加的 plan
自动被覆盖，不需要有人记得回来补一行。

不引入第三方依赖：plan 是 JSON、pbxproj 是文本，正则 + 标准库就够，和
`test_ios_dark_icon.py` 的取舍一致。
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "FlatRadar.xcodeproj" / "project.pbxproj"

# 构建产物和别的 worktree 不算仓库内容。`.claude/worktrees/` 尤其要排掉——
# 它就在仓库里，里面每个 worktree 都有自己的一整套 plan，扫进来会误报。
SKIP_DIRS = {"build", "DerivedData", "output", "Pods", "Carthage"}


def _is_skipped(rel: Path) -> bool:
    return any(part.startswith(".") or part in SKIP_DIRS for part in rel.parts)


def all_test_plans() -> list[Path]:
    """仓库里所有 .xctestplan（排除构建产物、隐藏目录、其它 worktree）。"""
    return sorted(
        p for p in ROOT.rglob("*.xctestplan")
        if not _is_skipped(p.relative_to(ROOT))
    )


def synchronized_groups() -> set[str]:
    """pbxproj 里所有 PBXFileSystemSynchronizedRootGroup 的目录名。"""
    text = PBXPROJ.read_text(encoding="utf-8")
    return set(re.findall(
        r"isa = PBXFileSystemSynchronizedRootGroup;\s*\n\s*path = (\w+);", text))


def test_pbxproj_still_parses():
    """结构变了就直接说，别让下面那条测试静默变成空跑。"""
    assert PBXPROJ.is_file(), f"{PBXPROJ} 不存在"
    assert synchronized_groups(), (
        "pbxproj 里没解析出任何 PBXFileSystemSynchronizedRootGroup——"
        "文件结构变了，下面那条检查会静默失效，先把正则修好。")


def test_repo_has_test_plans():
    """一个都没扫到，多半是扫描逻辑坏了，而不是真的没有 plan。"""
    assert all_test_plans(), "仓库里一个 .xctestplan 都没扫到——扫描逻辑坏了？"


@pytest.mark.parametrize("plan", all_test_plans(), ids=lambda p: p.name)
def test_plan_is_not_inside_a_synchronized_app_folder(plan: Path):
    """plan 不能待在同步目录里，否则会被当资源拷进 .app 一起上架。"""
    rel = plan.relative_to(ROOT)
    top = rel.parts[0]
    synchronized = synchronized_groups()
    assert top not in synchronized, (
        f"{rel} 在同步目录 {top}/ 里，会被当资源拷进 .app 跟着上架。"
        f"而 ci_post_clone.sh 会往截图 plan 写明文凭据——两件事撞在一起就是"
        f"凭据随 App Store 包发出去。挪到仓库根的 TestPlans/，"
        f"再把 scheme 里的 container: 路径改掉。"
        f"（同步目录：{sorted(synchronized)}）")
