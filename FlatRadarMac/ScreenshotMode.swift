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

    /// 首选窗口尺寸，**按点**，从大到小。屏幕放得下就用它们，拍出来是满幅。
    ///
    /// 它们是 16:10 的，正好等于合法画布除以 2x 缩放——于是大屏上窗口图和画布
    /// 一样大，零留白、零重采样。
    static let preferredSizes: [NSSize] = [
        NSSize(width: 1440, height: 900),
        NSSize(width: 1280, height: 800),
    ]

    /// 合法画布里最大的那张（像素）。窗口再大就合不进去了。
    static let largestCanvas = CGSize(width: 2880, height: 1800)

    /// 这个 app 三栏布局的下限，取自 ``FlatRadarMacApp`` 里 `.defaultSize` 的注释：
    /// 侧栏 196 + 表格九列约 620 + inspector 300 ≈ 1120 点。
    ///
    /// 低于它 inspector 会被窗口右边缘切掉——build 370 的 01-Listings 就是这样，
    /// 那次窗口只有 1024 点宽。图是合法的、测试也全绿，只有内容是残的。
    static let minimumUsableWidth: CGFloat = 1120

    /// 在这块屏上用多大的窗口。
    ///
    /// 两条路：
    ///
    /// 1. **首选尺寸放得下** → 用它，拍出来正好等于画布，满幅无留白（本地那块
    ///    2560 点宽的屏走这条，1440×900）。
    /// 2. **放不下** → 用整个可用区，只要它的像素尺寸塞得进最大的画布。
    ///
    /// 第 2 条**不要求 16:10**。既然拍完要合成到画布上，窗口的比例就无所谓了，
    /// 只要塞得下。这一点是 build 370 之后改的：在那之前第 2 条也从 16:10 的
    /// 候选里挑，于是构建机上挑中 1024×640，比这个 app 三栏布局的下限还窄，
    /// inspector 被切掉半截。现在同一块屏给出 1280×692——宽度拿满，够用。
    static func windowSize(on screen: NSScreen?) -> NSSize? {
        guard let screen else { return nil }
        // 藏了菜单栏就按**整块屏**算，不按 `visibleFrame`。
        //
        // `presentationOptions` 生效之后 `visibleFrame` 不保证立刻更新，读到旧值
        // 就又把那 30 点让出去了——白边正是这么来的。按 `frame` 算是确定的。
        let visible = NSApp.presentationOptions.contains(.autoHideMenuBar)
            ? screen.frame.size
            : screen.visibleFrame.size
        if let preferred = preferredSizes.first(where: {
            $0.width <= visible.width && $0.height <= visible.height
        }) { return preferred }

        let scale = max(screen.backingScaleFactor, 1)
        let size = NSSize(width: floor(min(visible.width, largestCanvas.width / scale)),
                          height: floor(min(visible.height, largestCanvas.height / scale)))
        // 窄到连三栏都摆不下就别拍了——拍出来是一张内容残缺、尺寸却合法的图，
        // 下游查不出来。让测试报出来。
        guard size.width >= minimumUsableWidth, size.height > 0 else { return nil }
        return size
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


    /// 藏掉菜单栏，**整个进程只设一次**。
    ///
    /// 为什么值得重新加回来
    /// ------------------
    /// 不藏的话可用区是 1280×770 点（Dock 已由 ci_pre_xcodebuild 的 defaults 藏掉，
    /// 剩菜单栏 30 点），窗口拿不满 1280×800，合成时上下各补 30 像素白边——
    /// 那种图不能直接上架。
    ///
    /// 这个 API 我曾经加过又删掉（build 364–369），当时判定它是"六条只过两条"的
    /// 元凶。**那个判定是错的**：369 已经把它删干净了，结果还是 2/6；真凶是窗口
    /// 恢复状态（`isRestorable = false` 让干净退出存下"零窗口"），370 修掉之后
    /// 直接跳到 5/6。所以它一直是被冤枉的。
    ///
    /// 这次加回来有两处不同：
    ///
    /// - **只设一次**。当初它跟着 `pin` 被重试八次，而在显示周期里反复改窗口/应用
    ///   状态正是 370 那个 `_postWindowNeedsUpdateConstraints` 崩溃的成因。
    /// - **要求 app 已经激活**。`presentationOptions` 在非活动状态下设会抛异常。
    ///   没激活就跳过，交给下一次重试——重试本来就有八次。
    ///
    /// `.autoHideMenuBar` 必须和一个 Dock 选项一起给，单独给会被忽略。
    private static var didHideMenuBar = false

    /// 把 app **实际用上的**界面语言写进窗口的 AX value，给截图测试核对。
    ///
    /// 五种语言各跑一轮，而「语言没传到 app」是一种**全绿的失败**：iOS 那边真的
    /// 跑出过五套一模一样的英文截图，张数和尺寸全合格（见 iOS `ScreenshotTests`
    /// 里 `launch` 的注释）。Mac 这边还多一种可能：app 包里压根没有那种语言的
    /// `.lproj`，系统就退回英文——一样不报错。
    ///
    /// 报的是 `Bundle.main.preferredLocalizations.first`，也就是**系统在 app 包
    /// 里挑中的那一份**，不是传进来的参数。两种失败都会让它和期望值对不上。
    ///
    /// 窗口的 AX value 平时没人用，写它不影响任何界面；只在截图模式下写。
    /// 先比较再写：`pin` 会被重试八次。
    static func reportLanguage(on window: NSWindow) {
        let lang = Bundle.main.preferredLocalizations.first ?? ""
        if (window.accessibilityValue() as? String) != lang {
            window.setAccessibilityValue(lang)
        }
    }

    static func hideMenuBarOnce() {
        guard !didHideMenuBar, NSApp.isActive else { return }
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        didHideMenuBar = true
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
        reportLanguage(on: window)
        hideMenuBarOnce()
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
        guard let size = windowSize(on: screen) else { return }
        // 摆放的参照系要和 `windowSize` 用的那个一致，否则窗口会被推出屏幕。
        let container = NSApp.presentationOptions.contains(.autoHideMenuBar)
            ? (screen?.frame ?? .zero)
            : (screen?.visibleFrame ?? .zero)
        // **每一步都先判断再改。**
        //
        // `pin` 会被重试八次（见 `WindowSizer`），而在 AppKit 的显示周期里反复改
        // 窗口属性会抛未捕获异常：build 370 的 03-Calendar 就是这么崩的——
        // SIGABRT，栈顶是
        //
        //     -[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]
        //     -[NSView _informContainerThatSubviewsNeedUpdateConstraints] × N
        //
        // 日历那屏布局最重，重试落在布局中途的概率最高，所以是它先中；换一轮
        // 可能是别的屏。改成幂等之后，第一次之后的七次都是空操作。
        //
        // 顺带**去掉了 `styleMask.remove(.resizable)`**。改 styleMask 会让窗口重建
        // frame view，是这里最容易在布局中途炸的一项，而它本来就是多余的——
        // `minSize == maxSize` 已经把尺寸锁死了。
        let origin = NSPoint(x: container.midX - size.width / 2,
                             y: container.midY - size.height / 2)
        let target = NSRect(origin: origin, size: size)
        if window.frameAutosaveName != "" { window.setFrameAutosaveName("") }
        if window.minSize != size { window.minSize = size }
        if window.maxSize != size { window.maxSize = size }
        if window.frame != target { window.setFrame(target, display: true) }
    }
}
