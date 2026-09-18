"""会话结束时，Mac 端必须清掉上一个账号的数据，而且会话失效必须真的结束会话。

这两条**运行时测不了**：`AuthStore.logout()` 会删钥匙串里的会话，而 Mac 的
测试宿主就是签过名的那个 app——在单测里触发一次 401 自动登出，会把本机真正
在用的登录态一起登出。所以运行时只测「收到广播就清」（`AppFeedTests`），
「谁来发广播」「谁装了 401 监听」在这里按源码钉住。

两条都是真出过的事（代码审查 P1）：
- 设置页 Sign Out / Delete Account 没清通知，退出进游客还能看到上一个账号的通知；
- Mac 启动时没装 401 监听，token 被撤销之后界面一直显示登录着，后续操作全失败。
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AUTH = ROOT / "FlatRadarCore/Sources/FlatRadarCore/Stores/AuthStore.swift"
MAC = ROOT / "FlatRadarMac"


def _body(source: str, signature: str) -> str:
    """取一个函数的函数体（按花括号配平）。"""
    start = source.index(signature)
    i = source.index("{", start)
    depth = 0
    for j in range(i, len(source)):
        if source[j] == "{":
            depth += 1
        elif source[j] == "}":
            depth -= 1
            if depth == 0:
                return source[i:j + 1]
    raise AssertionError(f"{signature} 的花括号没配平")


def test_会话结束的两个出口都广播():
    """`logout()` 和 `deleteAccount()` 是会话结束仅有的两个出口，都得发那一声。

    401 自动登出走的也是 `logout()`，所以不用单独查。漏了一个，对应那条路径
    登出之后上一个账号的通知就留在界面上——那正是这次修掉的问题。
    """
    src = AUTH.read_text(encoding="utf-8")
    for fn in ("public func logout()", "public func deleteAccount()"):
        assert "sessionEndedNotification" in _body(src, fn), (
            f"AuthStore 的 {fn} 没有广播 sessionEndedNotification。宿主靠这一声清账户数据，"
            "漏了的话从这条路登出会残留上一个账号的通知。")


def test_mac_端听着会话结束的广播():
    src = (MAC / "AppFeed.swift").read_text(encoding="utf-8")
    assert "AuthStore.sessionEndedNotification" in src, (
        "AppFeed 不再监听会话结束——清账户数据又回到了靠各个调用点自己记得。")


def test_mac_启动时装了_401_自动登出():
    """iOS 在 `FlatRadarApp` 里装，Mac 漏过一次。"""
    hits = [p.name for p in MAC.glob("*.swift")
            if re.search(r"\bobserveAuthFailures\(\)", p.read_text(encoding="utf-8"))]
    assert hits, (
        "FlatRadarMac 里没有任何地方调用 observeAuthFailures()。token 被撤销 / 到期之后"
        "界面会一直显示登录着，之后每个请求都 401。")


def test_401_监听是幂等的():
    """Mac 上它挂在窗口的 `.task` 里；装两个的话一次 401 会登出两遍。"""
    body = _body(AUTH.read_text(encoding="utf-8"), "public func observeAuthFailures()")
    assert re.search(r"guard\s+authFailureObserver\s*==\s*nil", body), (
        "observeAuthFailures() 没有「已经装过就返回」的那道门。")
