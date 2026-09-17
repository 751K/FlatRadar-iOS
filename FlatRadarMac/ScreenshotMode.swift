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
/// ASC 只收 1280×800 / 1440×900 / 2560×1600 / 2880×1800 这四种像素尺寸。
///
/// **不要求窗口自己就是其中之一。** 曾经是这么设计的，代价是屏幕放不下时必须去
/// 动系统状态（全屏、或 `presentationOptions` 藏菜单栏和 Dock），而那在一次性
/// 构建机上连着跑六条用例时会塌——build 359/364/367/368 全栽在这上面。
///
/// 现在窗口只管做一个**16:10 的普通窗口**，挑屏幕放得下的最大那个；拍完由
/// `MacScreenshotTests.snap` 把它居中合成到最小的那张放得下的合法画布上。
/// 屏幕大就是满幅（1440×900 点 ×2 = 2880×1800，画布正好等于图），屏幕小就带留白。
/// 两种情况下上传的都是合法尺寸，而且这里一行系统状态都不用改。
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

    /// 候选窗口尺寸，**按点**，从大到小，全部 16:10。
    ///
    /// 注意它们**不需要**自己就是合法的上传尺寸——合法尺寸由 `MacScreenshotTests`
    /// 那边合成画布时保证。这一点是后来改的，起因见 ``pin(_:)``。
    static let windowSizes: [NSSize] = [
        NSSize(width: 1440, height: 900),
        NSSize(width: 1280, height: 800),
        NSSize(width: 1152, height: 720),
        NSSize(width: 1024, height: 640),
        NSSize(width: 896,  height: 560),
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
        // **不要**在这里设 `isRestorable = false`。
        //
        // 原先设了，理由是"别让系统恢复的尺寸盖掉我们钉的那个"。但它带来的后果
        // 严重得多：窗口被标成不可恢复 → app 干净退出时保存下来的状态是**零窗口**
        // → 下次启动 AppKit 按"零窗口"恢复，SwiftUI 的 `WindowGroup` 就不再创建
        // 默认窗口了。
        //
        // build 367/368/369 的形态完全一致：00 和 01 过，02 往后每条都卡在
        // `waitForWindow` 六十秒，`windows=0` 而进程活着。要攒够一次**干净退出**
        // 才开始坏，所以恰好是前两条能过。
        //
        // 本地八次连跑之所以从没复现：那边用 `pkill`（SIGKILL）收尾，app 根本没
        // 机会保存状态；而 `XCUIApplication.terminate()` 是干净退出，会保存。
        //
        // 尺寸不用靠它守——`WindowSizer` 那边有重试 + `minSize == maxSize` 的硬锁，
        // 而且启动参数里加了 `-ApplePersistenceIgnoreState YES`，压根不会去恢复。
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
        // 只在 `visibleFrame` 里居中。**不碰菜单栏、Dock、全屏、Space 任何一样。**
        //
        // 原先这里想让窗口自己就是合法上传尺寸，于是屏幕小的时候要么切全屏
        // （build 359：六条里只有一条拿到窗口，还有一条 Lost connection），要么
        // 用 `NSApp.presentationOptions` 藏掉菜单栏和 Dock（build 364/367/368：
        // 第三次启动之后就再也开不出窗口）。两条路都动了系统的全局状态，而这台
        // 构建机是一次性的、六条用例连着跑，稍有残留就整轮塌。
        //
        // 换掉那个前提之后简单多了：窗口就是个普通窗口，**合法尺寸由拍完之后合成
        // 画布来保证**（见 `MacScreenshotTests.snap`）。屏幕大就拿到 1440×900 的
        // 满幅窗口，屏幕小就是一张带留白的窗口图——两者都是合法尺寸，而且这段代码
        // 不再有任何"改了系统状态得记得改回去"的东西。
        guard let size = fittingWindowSize(on: screen) else { return }
        let container = screen?.visibleFrame ?? .zero
        window.setFrameAutosaveName("")
        window.styleMask.remove(.resizable)
        window.minSize = size
        window.maxSize = size
        let origin = NSPoint(x: container.midX - size.width / 2,
                             y: container.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
