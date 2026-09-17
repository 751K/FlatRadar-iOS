//
//  MacScreenshotTests.swift
//  FlatRadarMacUITests
//
//  Mac App Store 截图自动化。和 iOS 的 `ScreenshotTests` 是同一个形状，但有
//  三处必须不一样，起因都在平台上：
//
//  1. **拍窗口，不拍整屏。** iOS 那边用 `simctl status_bar` 把时钟锁成 9:41；
//     Mac 没有模拟器，也就没有这个命令。整屏截图会把菜单栏和那个真实时钟一起
//     拍进去——每跑一次图都不一样，而且是个实时时间戳。只拍窗口，问题不存在。
//
//  2. **尺寸要断言。** ASC 的 Mac 截图只收四种尺寸（见
//     ``ScreenshotMode/acceptedPixelSizes``）。iOS 是设备决定分辨率，拍出来必然
//     合法；Mac 上窗口多大是运行时状态，拍完必须查。
//
//  3. **不用点任何东西。** iOS 那套在 tab 定位上翻来覆去改了四轮（identifier 在
//     iPhone 上是空的、iPad 没有 tabBars、序号会错位……）。Mac 这边侧栏那一屏
//     由 `UI_TEST_SECTION` 直接设进 `BrowseModel.section`，落位是同步的，
//     ``MainWindow`` 挂载时身份已经落地，没有那条竞态。所以这里不点、只验。
//

import AppKit
import XCTest

@MainActor
final class MacScreenshotTests: XCTestCase {

    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        // 每条用例都要**冷启动**。不关的话 `app.launch()` 拿到的可能是上一条
        // 留下的窗口，连同上一条设的 section——名字对、尺寸对、内容是上一屏。
        app.terminate()
    }

    // MARK: - Captures

    func testCapture00_SignIn() throws {
        launch(flags: ["UI_TEST_SHOW_LOGIN": "1"])
        let window = waitForWindow()
        // 登录屏上不该有侧栏。用「主界面不存在」判，不找登录页上的具体控件：
        // 和 iOS 那条同一个理由——真正会打破这张图的是「带凭据登录了」，
        // 而侧栏在登录页上一定不存在。
        XCTAssertFalse(app.outlines.firstMatch.exists,
                       "登录屏上出现了侧栏——说明它自动登录了。\n" + inventory())
        snap(window, named: "00-SignIn")
    }

    func testCapture01_Listings() throws { try capture("listings", "01-Listings") }
    func testCapture02_Map()      throws { try capture("map",      "02-Map")      }
    func testCapture03_Calendar() throws { try capture("calendar", "03-Calendar") }
    func testCapture04_Alerts()   throws { try capture("alerts",   "04-Alerts")   }
    func testCapture05_Stats()    throws { try capture("stats",    "05-Stats")    }

    /// 一屏的完整流程：启动 → 等窗口 → 验选中 → 等内容 → 拍。
    private func capture(_ section: String, _ name: String) throws {
        launch(flags: ["UI_TEST_SECTION": section])
        let window = waitForWindow()
        assertSelected(section)
        settle(section)
        snap(window, named: name)
    }

    // MARK: - Helpers

    /// 启动参数**必须带 `-` 前缀、成对给值**，不能用 iOS 那种裸 token。
    ///
    /// AppKit 把不带 `-` 的裸参数当成「要打开的文档」。
    /// `UI_TEST_SCREENSHOT_MODE` 不是路径，打开失败，于是 app 走「为打开文档而
    /// 启动」那条路——`WindowGroup` 的默认窗口根本不创建。build 358 六条用例全挂
    /// 在 `waitForWindow` 上，60 秒 `windows=0`，而进程活着、菜单栏齐全、辅助功能
    /// 正常响应，错误信息里没有任何一处指向启动参数。
    ///
    /// 本地对照过，换成完全无关的 `HELLO` 也一样没窗口，加 `-` 前缀立刻就有——
    /// 所以这跟截图逻辑无关。完整实测见 ``UITestFlags``。
    ///
    /// `-KEY value` 会进 `NSArgumentDomain`，App 那边用 `UserDefaults` 读，
    /// 且不写盘、不污染用户偏好。
    private func launch(flags: [String: String]) {
        // 名字和 `UITestFlags.screenshotMode` 必须一致，由
        // tests/test_mac_screenshot_plan.py 的 test_screenshot_flag_name_matches_core 钉住
        // （UI 测试 target 不链 FlatRadarCore，为一个常量加依赖不值得）。
        var args = ["-UI_TEST_SCREENSHOT_MODE", "1"]
        for (k, v) in flags.sorted(by: { $0.key < $1.key }) { args += ["-\(k)", v] }
        // 凭据从环境变量取，**不写在代码里**——这个仓库是公开的。
        // 云端由 ci_scripts/ci_post_clone.sh 写进 test plan 的
        // environmentVariableEntries（Xcode Cloud 禁止 TEST_RUNNER_ 前缀，
        // 而 xcodebuild 只转发这个前缀，那个脚本里写了完整缘由）。
        // 本地不设就退回访客模式。
        let env = ProcessInfo.processInfo.environment
        if let u = env["UI_TEST_USERNAME"], let p = env["UI_TEST_PASSWORD"],
           !u.isEmpty, !p.isEmpty {
            args += ["-UI_TEST_USER", u, "-UI_TEST_PASS", p]
        }
        app.launchArguments = args
        app.launch()
    }

    /// 等主窗口出现。
    ///
    /// 用 `app.windows.firstMatch` 而不是按标题找：标题栏上写的是房源数
    /// （`MainWindow` 的 `.navigationTitle`），随数据变。
    private func waitForWindow() -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 60),
                      "主窗口未在 60s 内出现。\n" + inventory())
        return window
    }

    /// 侧栏里选中的确实是这一屏。
    ///
    /// 「测试通过」和「拍对了」是两回事：`UI_TEST_SECTION` 要是没落位，
    /// 截图会照拍不误，拍出一张名字对、尺寸对、内容是 Listings 的图，
    /// 下游只查张数和像素，查不出来。iOS 那边吃过这个亏（05-Notifications
    /// 拍成了 Dashboard），这里不再留这个口子。
    ///
    /// 侧栏文案是**英文硬写**的（`SidebarSection.label` 是个 `String` 变量，
    /// `Text(_:)` 那个重载不做本地化，而且 FlatRadarMac 这个 target 根本没有
    /// 字符串目录）。所以按标题找是安全的——这一点和 iOS 正好相反，那边的
    /// tab 标题是翻译过的，按标题找在非英文语言下全线失败。
    /// 哪天 Mac 端做了本地化，这里要跟着改成 accessibilityIdentifier。
    private func assertSelected(_ section: String) {
        let label = section.prefix(1).uppercased() + section.dropFirst()
        let row = app.outlines.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "侧栏里找不到「\(label)」这一行。\n" + inventory())
        XCTAssertTrue(row.isSelected,
                      "选中的不是「\(label)」——UI_TEST_SECTION 没落位，"
                      + "而截图会照拍不误。\n" + inventory())
    }

    /// 等这一屏的内容真的渲染出来。
    ///
    /// 不用固定 sleep：地图和统计慢、列表快，一刀切要么等太久要么拍到半张。
    /// 各屏等自己那个"有数据了"的标志，等不到再退回一个短的兜底 sleep——
    /// 空状态也是要拍的（比如访客模式下的 Alerts），不能因为没数据就判失败。
    private func settle(_ section: String) {
        let window = app.windows.firstMatch
        switch section {
        case "listings":
            _ = window.tables.firstMatch.waitForExistence(timeout: 30)
        case "map":
            // 地图瓦片是异步下载的，没有可等的无障碍元素。给足时间。
            Thread.sleep(forTimeInterval: 6)
        case "calendar", "stats", "alerts":
            Thread.sleep(forTimeInterval: 3)
        default:
            Thread.sleep(forTimeInterval: 2)
        }
        // 统一再给一拍，让滚动条淡出、悬停态复位。
        Thread.sleep(forTimeInterval: 1)
    }

    /// 等窗口尺寸稳定下来。
    ///
    /// 走全屏兜底那条路时有一段过渡动画（构建机那块 1280×800 的屏就会走到它），
    /// 拍早了尺寸是过渡中的中间值。而尺寸断言只会说「不是合法值」，看不出是
    /// **没等够**还是**钉错了**——这两种失败的改法完全不同。
    private func waitForStableFrame(_ window: XCUIElement) {
        var last = CGRect.zero
        for _ in 0..<40 {                       // 最多 ~10s
            let f = window.frame
            if f == last, f != .zero { return }
            last = f
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// 拍窗口，存成附件，并**当场验尺寸**。
    private func snap(_ window: XCUIElement, named step: String) {
        waitForStableFrame(window)
        let shot = window.screenshot()
        let size = pixelSize(shot)
        XCTAssertTrue(Self.accepted.contains(size),
                      "\(step) 拍出来是 \(Int(size.width))×\(Int(size.height))，"
                      + "不是 ASC 收的四种之一 \(Self.accepted.map { "\(Int($0.width))×\(Int($0.height))" })。"
                      + "多半是构建机的屏幕放不下 1440×900 点，或者窗口没被钉住。"
                      + "\(screenReport())")
        let attachment = XCTAttachment(screenshot: shot)
        // 名字里不带语言：语言由 test plan 的 configuration 决定，附件的
        // configurationName 已经带着它，提取脚本按那个分桶。
        attachment.name = step
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let accepted: [CGSize] = [
        CGSize(width: 2880, height: 1800),
        CGSize(width: 2560, height: 1600),
        CGSize(width: 1440, height: 900),
        CGSize(width: 1280, height: 800),
    ]

    /// 截图的**像素**尺寸。
    ///
    /// `XCUIScreenshot.image.size` 给的是**点**，不是像素——`NSImage` 的 size 是
    /// 逻辑尺寸，Retina 下和像素差一个 `backingScaleFactor`。要查 ASC 的尺寸就
    /// 必须问底层位图，否则在 2x 屏上量出来永远是 1440×900，而实际上传的是
    /// 2880×1800，这条断言就成了摆设。
    private func pixelSize(_ shot: XCUIScreenshot) -> CGSize {
        guard let rep = NSBitmapImageRep(data: shot.pngRepresentation) else { return .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// 失败时附上这台机器的屏幕参数——尺寸不对时第一个要问的就是它。
    private func screenReport() -> String {
        NSScreen.screens.enumerated().map { i, s in
            "\n  屏 \(i)：frame=\(s.frame) visible=\(s.visibleFrame) scale=\(s.backingScaleFactor)"
        }.joined()
    }

    /// 失败时打印的诊断。**要短，要点在最前面。**
    ///
    /// iOS 那边试过打 `app.debugDescription.prefix(3000)`，三千字符全是嵌套容器，
    /// 要找的东西一个字都没印到；而 ASC 的 issues 接口本来就把失败信息截在三千
    /// 字符左右，"多打一点"这条路是堵死的。所以只印侧栏那几行 + 窗口尺寸。
    private func inventory() -> String {
        var lines = ["windows=\(app.windows.count)"]
        for w in app.windows.allElementsBoundByIndex.prefix(3) {
            lines.append("  [window] frame=\(w.frame) title=\(w.title.debugDescription)")
        }
        let outline = app.outlines.firstMatch
        if outline.exists {
            for row in outline.descendants(matching: .staticText).allElementsBoundByIndex.prefix(12) {
                lines.append("  [sidebar] \(row.label.debugDescription) sel=\(row.isSelected)")
            }
        } else {
            lines.append("  (没有 outline——侧栏未挂载)")
        }
        lines.append(screenReport())
        return lines.joined(separator: "\n")
    }
}
