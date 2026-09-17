import AppKit
import SwiftUI
import FlatRadarCore

/// App Store 的 Mac 截图模式。
///
/// 形状和 iOS 那套一样（launch arg 驱动、XCUITest 拍、Xcode Cloud 上跑），
/// 但有三件事在 Mac 上必须换掉：
///
/// 1. **没有模拟器，也就没有 `simctl status_bar`。** iOS 那条把时钟锁成 9:41 的
///    路（`ci_scripts/ci_pre_xcodebuild.sh`）在 Mac 上不存在，也不需要——截图只
///    拍**窗口**，菜单栏连同那个真实时钟一起不进画面。
/// 2. **尺寸是硬性的。** ASC 的 Mac 截图只收 1280×800 / 1440×900 / 2560×1600 /
///    2880×1800 这四种，16:10、不带 alpha。iOS 是设备决定分辨率，Mac 上「窗口
///    多大」是用户状态，不钉死就每跑一次是一个尺寸。
/// 3. **有三样东西会改窗口尺寸**：`.defaultSize`（只在没有恢复状态时生效）、系统
///    的窗口状态恢复、以及这个工程自己的 ``WindowSizer``（登录屏缩到 900×620）。
///    截图模式下三条全要让路，见 ``pin(_:)``。
///
/// 尺寸怎么选
/// ----------
/// 窗口按**点**定，截图出来的像素 = 点 × 屏幕的 `backingScaleFactor`。而那个系数
/// 在 Xcode Cloud 的构建机上是 1 还是 2，**我们说了不算**，也没有办法从仓库里查到。
///
/// 所以不去赌它，改成让两种系数都落在合法值上：
///
///     1440×900 ×1 → 1440×900       1440×900 ×2 → 2880×1800
///     1280×800 ×1 → 1280×800       1280×800 ×2 → 2560×1600
///
/// 四个合法尺寸**正好**被这两个点尺寸 × 两种系数覆盖满。挑大的那个，屏幕放不下
/// 就退到小的；两个都放不下就**全屏**——全屏窗口恰好等于屏幕尺寸，构建机那块
/// 1280×800@2x 的屏于是给出 2560×1600，同样是合法值。见 ``pin(_:)``。
///
/// `MacScreenshotTests` 会把这条断言真的执行一遍——拍完就查像素尺寸在不在
/// ``acceptedPixelSizes`` 里，不在就红。否则这段推理只是注释。
enum ScreenshotMode {

    /// 和 iOS 用同一个名字。UI Test 启动时传，真实用户启动不会带。
    static let flag = "UI_TEST_SCREENSHOT_MODE"

    static var isOn: Bool { UITestFlags.isScreenshotMode }

    /// ASC 收的四种 Mac 截图尺寸（像素）。
    /// https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/
    static let acceptedPixelSizes: [CGSize] = [
        CGSize(width: 2880, height: 1800),
        CGSize(width: 2560, height: 1600),
        CGSize(width: 1440, height: 900),
        CGSize(width: 1280, height: 800),
    ]

    /// 候选窗口尺寸，**按点**，从大到小。见类型注释里那张换算表。
    static let windowSizes: [NSSize] = [
        NSSize(width: 1440, height: 900),
        NSSize(width: 1280, height: 800),
    ]

    /// 这块屏放得下的最大那个合法尺寸；一个都放不下就返回 nil（改走全屏）。
    ///
    /// 用 `visibleFrame` 不用 `frame`：前者已经扣掉菜单栏和 Dock，那才是窗口真
    /// 能占的地方。放不下**不能**硬塞一个——`XCUIElement.screenshot()` 是从整屏
    /// 截图里按元素 frame 裁的，窗口被 Dock 压住的部分会把 Dock 一起裁进去。
    static func fittingWindowSize(on screen: NSScreen?) -> NSSize? {
        guard let visible = screen?.visibleFrame.size else { return windowSizes[0] }
        return windowSizes.first { $0.width <= visible.width && $0.height <= visible.height }
    }

    // MARK: - Launch arguments

    /// 开关的值。两端传法不同，判据统一在 ``UITestFlags`` 里——**macOS 必须传
    /// `-KEY value`**，裸 token 会被 AppKit 当成要打开的文档，结果是 app 起来了
    /// 却一个窗口都没有（build 358 就是这么挂的，详见 ``UITestFlags``）。
    static func value(_ key: String) -> String? { UITestFlags.value(key) }

    static func has(_ key: String) -> Bool { UITestFlags.isOn(key) }

    /// `UI_TEST_SECTION=<listings|map|calendar|alerts|stats>` → 侧栏那一屏。
    ///
    /// **不认识的值不能静默放过。** iOS 那边踩过：测试端发 `list`、App 认
    /// `listings`，对不上就落进 default、tab 原地不动，然后截图照拍——拍出一张
    /// 名字对、尺寸对、内容却是另一屏的图，下游只查张数和像素，查不出来。
    /// 这里用 `SidebarSection(rawValue:)` 直接解析，词表只有一份，没有对不上的
    /// 机会；解析不出来就 `assertionFailure`。
    static func section() -> SidebarSection? {
        guard let raw = value("UI_TEST_SECTION") else { return nil }
        guard let section = SidebarSection(rawValue: raw.lowercased()) else {
            assertionFailure("UI_TEST_SECTION 的值无法识别：\(raw)")
            return nil
        }
        return section
    }

    // MARK: - 进程级开关

    /// 在 `App.init` 里跑。跳过条款 / onboarding，关动画。
    ///
    /// 和 iOS 的 `FlatRadarApp.init` 是同一份清单，键名也一样——两端共用
    /// `FlatRadarCore` 里那些 `UserDefaults` 键，各写各的会漏。
    static func applyProcessDefaults() {
        guard isOn else { return }
        let d = UserDefaults.standard
        d.set(true, forKey: "terms_accepted")
        d.set(true, forKey: "onboarding_completed")
        d.set(true, forKey: "crash_prompt_suppressed")
        // 菜单栏常驻默认本来就是关的（`MenuBarResidency.defaultOn`），这里再写
        // 一次是为了盖掉**上一次跑留下的偏好**——本地反复跑时 UserDefaults 是
        // 同一份。开着的后果不是图上多个图标（窗口截图看不见菜单栏），而是
        // App 在最后一个窗口关掉后不退出，下一条用例的 `app.launch()` 拿到的
        // 是上一条留下来的窗口，连同上一条设的 section。
        d.set(false, forKey: MenuBarResidency.storageKey)
        // 外观固定跟随系统（也就是 Xcode Cloud 上的浅色），不让上一次跑剩下的
        // 偏好把某一张拍成深色。
        d.set(AppearancePreference.system.rawValue, forKey: AppearancePreference.storageKey)
    }

    /// 身份。返回 true 表示「停在登录屏」，调用方据此不再往下走。
    ///
    /// 顺序和 iOS 一样：`UI_TEST_SHOW_LOGIN` 优先于凭据。CI 上凭据永远存在
    /// （来自 secrets），凭据判断放前面的话登录屏那条用例也会登录，拍出来是
    /// 主界面——iOS 那边就出过「商店里两张 Dashboard、没有登录页」。
    @MainActor
    static func applyIdentity(_ auth: AuthStore) {
        guard isOn else { return }
        if has("UI_TEST_SHOW_LOGIN") { return }
        if let user = value("UI_TEST_USER"), let pass = value("UI_TEST_PASS"),
           !user.isEmpty, !pass.isEmpty {
            Task { await auth.loginAsUser(name: user, password: pass) }
            return
        }
        if !auth.isAuthenticated { auth.enterAsGuest() }
    }

    // MARK: - 窗口

    /// 藏掉 Dock 和菜单栏，再问一次放不放得下。
    ///
    /// 构建机那块屏 `visibleFrame` 只有 1280×692（Dock 78 + 菜单栏 30），而最小的
    /// 合法尺寸要 800 点高——窗口化怎么摆都放不下。
    ///
    /// **为什么不用全屏。** 试过，build 359：全屏那条路确实给出了
    /// `frame=(0,0,1280,800)`（正是合法的 2560×1600），但全屏会把窗口挪进一个
    /// 独立 Space，而每条用例都要 terminate + 重启。那一轮六条里只有一条拿到窗口，
    /// 其余是 `windows=0`，还有一条直接 `Lost connection to the application`。
    /// 在一次性构建机上进出 Space 太脆。
    ///
    /// `presentationOptions` 达到同样的效果却不碰 Space：两条一起藏之后整块屏都
    /// 能用，窗口摆在 (0,0) 正好 1280×800。
    ///
    /// 按**屏幕 frame** 判而不是改完再读 `visibleFrame`——后者不保证同步更新，
    /// 读到旧值就又退回"放不下"了。
    private static func sizeAfterHidingDockAndMenuBar(on screen: NSScreen?) -> NSSize? {
        guard let frame = screen?.frame.size else { return nil }
        guard windowSizes.contains(where: { $0.width <= frame.width && $0.height <= frame.height })
        else { return nil }
        // `.autoHideMenuBar` 必须和一个 Dock 选项一起给，单独给会被忽略。
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        return windowSizes.first { $0.width <= frame.width && $0.height <= frame.height }
    }

    /// 把窗口钉成截图尺寸。
    ///
    /// 三件事都要做，少一件都会漏尺寸：
    ///
    /// - `isRestorable = false`：系统的窗口状态恢复会用**上一次**的尺寸覆盖
    ///   `.defaultSize`。本地反复跑时这一条最容易咬人——第一次跑对了，第二次
    ///   拿到的是第一次结束时的尺寸。
    /// - `setFrame`：定的是**frame 不是 contentSize**。`XCUIElement.screenshot()`
    ///   裁的是元素的 frame，窗口的 frame 含标题栏；按 contentSize 定的话拍出来
    ///   会比目标高一条标题栏，正好不是合法尺寸。
    /// - `styleMask.remove(.resizable)`：拍的过程中谁都别再动它。
    ///
    /// 居中放。`visibleFrame` 已扣掉菜单栏和 Dock，所以窗口不会被它们压住。
    static func pin(_ window: NSWindow) {
        guard isOn else { return }
        window.isRestorable = false
        let screen = window.screen ?? NSScreen.main

        // 容器 = 窗口真正能占的那块地方。
        //
        // 放得下就用 `visibleFrame`（已扣掉菜单栏和 Dock），居中摆，看着像一张
        // 正常的 Mac 截图。放不下就藏掉 Dock 和菜单栏，容器随之变成**整块屏**。
        //
        // 这两步必须配套：藏完还按 `visibleFrame` 居中的话，`visibleFrame` 不保证
        // 已经更新，拿到旧值（构建机上是 1280×692）算出来的 origin.y=24，而窗口有
        // 800 点高——顶上 24 点直接跑到屏幕外面去，截出来既不是完整窗口也不是
        // 合法尺寸。
        let container: NSRect
        let size: NSSize
        if let fit = fittingWindowSize(on: screen) {
            container = screen?.visibleFrame ?? .zero
            size = fit
        } else if let full = sizeAfterHidingDockAndMenuBar(on: screen) {
            container = screen?.frame ?? .zero
            size = full
        } else {
            // Dock 和菜单栏都藏了还是放不下——这块屏本来就比最小的合法尺寸还小。
            // 不硬塞：`XCUIElement.screenshot()` 是从整屏截图按 frame 裁的，塞出去
            // 的部分裁回来是桌面，尺寸也不对。让测试报出来。
            return
        }

        window.styleMask.remove(.resizable)
        let origin = NSPoint(x: container.midX - size.width / 2,
                             y: container.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
