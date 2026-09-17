import Foundation

/// 截图 / UI 测试的启动开关，两端共用的**唯一**判据。
///
/// 为什么不能只看 `CommandLine.arguments`
/// ------------------------------------
/// iOS 一直是这么传的（`app.launchArguments = ["UI_TEST_SCREENSHOT_MODE", …]`），
/// 一直好用。**但同一份写法在 macOS 上会让 app 开不出窗口。**
///
/// AppKit 把命令行里**不带 `-` 前缀**的裸参数当成「要打开的文档」。
/// `UI_TEST_SCREENSHOT_MODE` 不是路径，打开失败，于是 app 走的是「为打开文档而
/// 启动」那条路——`WindowGroup` 的默认窗口就不创建了。进程活着、菜单栏齐全、
/// 辅助功能正常响应，**就是一个窗口都没有**。
///
/// 实测（build 358 的表现，以及本地用 `open --args` 复现的对照）：
///
///     open -n -a FlatRadarMac.app --args HELLO                      → 无窗口
///     open -n -a FlatRadarMac.app --args UI_TEST_SCREENSHOT_MODE    → 无窗口
///     open -n -a FlatRadarMac.app --args -UITestFoo 1               → 有窗口
///     open -n -a FlatRadarMac.app                                   → 有窗口
///
/// 注意第一行：参数换成完全无关的 `HELLO` 也一样没窗口。所以这跟截图模式的逻辑
/// 无关，是「带不带 `-`」的问题。iOS 不受影响——UIKit 没有这套开文档的语义。
///
/// 所以 macOS 改传 `-KEY value` 形式。这种参数会进 `NSArgumentDomain`，
/// `UserDefaults.standard` 直接读得到，而且**不写盘**，进程退出就没了，不会污染
/// 用户真实的偏好。
///
/// 两种形式都认，因为两端的传法不一样，而 `PushStore` / `ReviewPromptStore`
/// 是两端共用的：
///
///     iOS    launchArguments = ["UI_TEST_SCREENSHOT_MODE"]        → 裸 token
///     macOS  launchArguments = ["-UI_TEST_SCREENSHOT_MODE", "1"]  → NSArgumentDomain
public enum UITestFlags {

    /// 截图自动化总开关。
    public static let screenshotMode = "UI_TEST_SCREENSHOT_MODE"

    /// 这个开关开着没有。
    ///
    /// 先问 `UserDefaults`（macOS 的 `-KEY value`），再回退到裸 token（iOS）。
    public static func isOn(_ name: String) -> Bool {
        if UserDefaults.standard.bool(forKey: name) { return true }
        return CommandLine.arguments.contains(name)
    }

    /// 带值的开关，例如 `UI_TEST_SECTION`。
    ///
    /// 两种写法都认：`-KEY value`（macOS）和 `KEY=value`（iOS 既有约定）。
    public static func value(_ name: String) -> String? {
        if let v = UserDefaults.standard.string(forKey: name), !v.isEmpty { return v }
        return CommandLine.arguments
            .first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    /// 截图模式下**一律不弹**系统弹窗。见 ``PushStore`` 和 ``ReviewPromptStore``
    /// 里各自那条 guard 的注释：带系统弹窗的截图不能上架。
    public static var isScreenshotMode: Bool { isOn(screenshotMode) }
}
