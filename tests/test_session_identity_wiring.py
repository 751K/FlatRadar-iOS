"""Mac 端"换了一个人"要按会话身份判断，不能按 `isAuthenticated`（代码审查 P2）。

游客和正式用户的 `isAuthenticated` 都是 true。游客在设置里注册之后：
- 以它为 id 的任务不重跑 → 实时通知流不连；
- 主窗口不重建 → 继续显示游客时期的数据。

运行时测这条要真去注册一个账号，所以接线按源码钉住；身份值本身的规则在
Core 的 `SessionIdentityTests` 里测。
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / "FlatRadarMac"
AUTH = ROOT / "FlatRadarCore/Sources/FlatRadarCore/Stores/AuthStore.swift"


def test_mac_没有任务再以_isAuthenticated_为标识():
    hits = [f"{p.name}:{i + 1}"
            for p in MAC.glob("*.swift")
            for i, line in enumerate(p.read_text(encoding="utf-8").splitlines())
            if re.search(r"\.task\(id:\s*auth\.isAuthenticated\)", line)]
    assert not hits, (f"这些任务以 isAuthenticated 为标识：{hits}。游客注册成正式用户时它不变，"
                      "任务不会重跑。用 auth.sessionIdentity。")


def test_主窗口按会话身份重建():
    src = (MAC / "FlatRadarMacApp.swift").read_text(encoding="utf-8")
    assert re.search(r"MainWindow\(\)\s*\.id\(auth\.sessionIdentity\)", src), (
        "主窗口没有按会话身份重建——换了人，窗口级状态会留着上一个身份的。")


def test_没有窗口时由_AppFeed_在应用级接住会话开始():
    src = (MAC / "AppFeed.swift").read_text(encoding="utf-8")
    assert "AuthStore.sessionBeganNotification" in src


def test_会话开始的两个入口都广播():
    """applyMe（登录 / 注册 / 恢复）和 enterAsGuest。"""
    src = AUTH.read_text(encoding="utf-8")
    for sig in ("private func applyMe(", "public func enterAsGuest()"):
        start = src.index(sig)
        body = src[start:src.index("\n    }\n", start)]
        assert "sessionBeganNotification" in body, f"{sig} 没有广播 sessionBeganNotification"


def test_房源窗口读认证状态():
    src = (MAC / "ListingWindow.swift").read_text(encoding="utf-8")
    assert "@Environment(AuthStore.self)" in src and "sessionIdentity" in src, (
        "ListingWindow 又不看认证状态了：退出后会照旧显示详情，换号不重载。")
