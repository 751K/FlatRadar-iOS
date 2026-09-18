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
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class MacScreenshotTests: XCTestCase {

    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        // 每条用例都要**冷启动**。
        //
        // 不只是"别带着上一条的 section"——更要命的是进程**没死透**：macOS 的 app
        // 关掉最后一个窗口默认不退出，下一条的 `launch()` 于是拿到一个没有窗口的
        // 现存实例，干等 60 秒。build 367 的 02–05 就是这么挂的。
        //
        // 治本在 App 那边（`applicationShouldTerminateAfterLastWindowClosed`），
        // 这里等一下并把结果记进日志：真出问题时能一眼看出是不是它。
        app.terminate()
        let deadline = Date().addingTimeInterval(10)
        while app.state != .notRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if app.state != .notRunning {
            XCTContext.runActivity(named: "⚠️ terminate 之后进程仍未退出（state=\(app.state.rawValue)）") { _ in }
        }
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
        assertShowing(section)
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
        // `-ApplePersistenceIgnoreState YES`：**每次启动都当作没有窗口恢复状态。**
        //
        // 不加的话，app 干净退出时保存的窗口状态会被下次启动读回来。这在截图套件
        // 里是致命的：`XCUIApplication.terminate()` 是干净退出，而只要有一次保存
        // 下来的状态是"零窗口"，之后每次启动 SwiftUI 都不再创建默认窗口——
        // build 367/368/369 里 02–05 就是这么连着挂的，每条等满六十秒。
        var args = ["-ApplePersistenceIgnoreState", "YES",
                    "-UI_TEST_SCREENSHOT_MODE", "1"]
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
        // 语言**显式**传给 app，不指望 test plan 的 language 选项自己转发过去。
        //
        // 那个选项在 iOS 模拟器上管用，在 macOS 上会不会带到被测 app 身上，
        // 没有文档说清楚，而传不到的后果是五套英文图、全绿。自己传就不存在
        // 这个问题：值来自每个 configuration 自己的 UI_TEST_LANGUAGE，
        // 拍之前 `assertLanguage` 再核对 app 真的用上了它。
        //
        // `-AppleLanguages` 的值是 plist 数组的文本写法 `(zh-Hans)`。
        if let lang = Self.expectedLanguage {
            let languages = "(\(lang))"
            args += ["-AppleLanguages", languages]
            if let locale = env["UI_TEST_LOCALE"], !locale.isEmpty {
                args += ["-AppleLocale", locale]
            }
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

    /// 现在显示的确实是这一屏。
    ///
    /// 「测试通过」和「拍对了」是两回事：`UI_TEST_SECTION` 要是没落位，截图会
    /// 照拍不误，拍出一张名字对、尺寸对、内容是 Listings 的图，下游只查张数和
    /// 像素，查不出来。iOS 那边吃过这个亏（05-Notifications 拍成了 Dashboard）。
    ///
    /// 验的是**内容区**的 identifier，不是侧栏那一行的选中态。两个理由：
    /// 侧栏行的 AX label 在 macOS 上是空的（build 359 实测六行全是 ""），按文案
    /// 根本找不到；而且「哪一行高亮」只是间接证据，内容区才是拍进图里的那个东西。
    private func assertShowing(_ section: String) {
        let pane = app.descendants(matching: .any)
            .matching(identifier: "pane-\(section)").firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30),
                      "内容区不是「\(section)」——UI_TEST_SECTION 没落位，"
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

    /// 这一轮应该是什么语言。来自 test plan 里每个 configuration 的环境变量。
    ///
    /// 本地直接跑单条用例（不经过 MacScreenshots.xctestplan）时没有它，
    /// 那就不传语言、也不核对，按系统语言拍。
    private static var expectedLanguage: String? {
        let v = ProcessInfo.processInfo.environment["UI_TEST_LANGUAGE"] ?? ""
        return v.isEmpty ? nil : v
    }

    /// app 真的在用这一轮该用的语言。
    ///
    /// 五种语言各跑一轮，而「语言没到 app」的样子是**五套英文图、全绿**——
    /// iOS 那边真出过。App 在截图模式下把自己挑中的 localization 写进窗口的
    /// AX value（``ScreenshotMode/reportLanguage(on:)``），这里拿来比。
    ///
    /// 要轮询：那个值是 `WindowSizer` 的重试写进去的，窗口出现的那一刻未必
    /// 已经写了。
    private func assertLanguage(_ window: XCUIElement, _ step: String) {
        guard let expected = Self.expectedLanguage else { return }
        var actual = ""
        for _ in 0..<40 {                       // 最多 ~10s
            actual = window.value as? String ?? ""
            if !actual.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(actual.isEmpty,
                       "\(step)：app 没报告界面语言（窗口的 AX value 是空的）。"
                       + "这一轮本该是 \(expected)，但无法确认——截图可能是任何语言。")
        XCTAssertEqual(actual, expected,
                       "\(step)：这一轮是 \(expected)，app 用的却是 \(actual)。"
                       + "要么 -AppleLanguages 没传到，要么 app 包里没有 \(expected) 的 .lproj。")
    }

    /// 拍窗口，存成附件，并**当场验尺寸**。
    private func snap(_ window: XCUIElement, named step: String) {
        assertLanguage(window, step)
        waitForStableFrame(window)
        // **把指针移到窗口中央再拍。**
        //
        // 窗口铺满整屏时（构建机那块 1280×800 的屏只能这样），菜单栏是画在窗口
        // **上面**的，而 `XCUIElement.screenshot()` 是从整屏截图里按 frame 裁的
        // ——于是菜单栏连同那个真实时钟一起进画面。build 367 的 00-SignIn 顶上
        // 就写着 `Thu Sep 17 11:37 AM`。
        //
        // App 那边已经设了 `.autoHideMenuBar`，但**指针停在屏幕顶边会把它唤回来**，
        // 而录像里光标正躺在左上角 (0,0)。移开就不会。
        //
        // 用 hover 不用 click：这几屏里点下去会改选中态、开详情窗口。
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        Thread.sleep(forTimeInterval: 0.6)      // 等菜单栏收回去
        let shot = window.screenshot()
        let raw = rawPixelSize(shot)
        guard let canvas = Self.canvas(fitting: raw) else {
            XCTFail("\(step) 窗口拍出来 \(Int(raw.width))×\(Int(raw.height))，"
                    + "比最大的合法尺寸 2880×1800 还大，合不进任何画布。"
                    + screenReport())
            return
        }
        guard let png = compose(shot, onto: canvas) else {
            XCTFail("\(step) 合成画布失败")
            return
        }
        let size = pixelSize(png)
        XCTAssertTrue(Self.accepted.contains(size),
                      "\(step) 拍出来是 \(Int(size.width))×\(Int(size.height))，"
                      + "不是 ASC 收的四种之一 \(Self.accepted.map { "\(Int($0.width))×\(Int($0.height))" })。"
                      + "多半是构建机的屏幕放不下 1440×900 点，或者窗口没被钉住。"
                      + "\(screenReport())")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
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
    private func pixelSize(_ png: Data) -> CGSize {
        guard let rep = NSBitmapImageRep(data: png) else { return .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// 把窗口图居中合成到一张**合法尺寸**的不透明画布上。
    ///
    /// 为什么要合成而不是让窗口自己就是合法尺寸
    /// --------------------------------------
    /// ASC 只收四种像素尺寸，最小的 1280×800 在 2x 屏上等于 1280×800 **点**——
    /// 而构建机那块屏总共就 1280×800 点，可用区（扣掉菜单栏和 Dock）只有
    /// 1280×692。也就是说窗口想自己合法，就只能铺满整屏，于是必须去藏菜单栏和
    /// Dock（或切全屏）。那条路试过四轮：build 359 六条里只有一条拿到窗口、
    /// 364/367/368 都是第三次启动之后再也开不出窗口。动系统全局状态在一次性
    /// 构建机上连跑六条就是这个下场。
    ///
    /// 合成之后窗口只是个普通窗口，一行系统状态都不用改。屏幕大时窗口正好等于
    /// 画布（满幅、零偏移、不重采样），屏幕小时是一张带白边的窗口图——两者都是
    /// 合法尺寸。
    ///
    /// 顺带解决 alpha：
    ///
    /// `XCUIScreenshot.pngRepresentation` 出来的 Mac 截图是 RGBA——build 367 那张
    /// 实测 `color type = 6`、`hasAlpha: yes`——而 **ASC 不收带 alpha 的 Mac 截图**。
    ///
    /// 压在这里而不是下游加一道工序：这样"从产出的那一刻起"就是合规的，本地跑和
    /// 云端跑共用同一条路，也不用再引一个 ffmpeg 依赖（试过 `sips`，它的
    /// `--padToHeightWidth` / `--matchTo` 都不去 alpha，出来还是 color type 6）。
    ///
    /// `XCUIScreenshot.pngRepresentation` 出来的 Mac 截图是 RGBA（build 367 那张
    /// 实测 `color type = 6`），而 ASC 不收带 alpha 的 Mac 截图。画布本身是
    /// 不透明的，合完就没有 alpha 了。
    ///
    /// 底色填白：和 app 的浅色底一致，留白处看着像一张正常的产品图。
    ///
    /// 用 CoreGraphics + ImageIO 而不是 `NSGraphicsContext`：后者要一个活着的
    /// NSApplication，本地拿命令行工具验同一段逻辑时直接 trap（SIGTRAP，退出码
    /// 133）。CoreGraphics 这条两边都能跑，于是这段逻辑**在本地实测过**——
    /// 拿 build 367 那张真图喂进去，color type 6 → 2。
    private func compose(_ shot: XCUIScreenshot, onto canvas: CGSize) -> Data? {
        let data = shot.pngRepresentation
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let cw = Int(canvas.width), ch = Int(canvas.height)
        // `.noneSkipLast` 就是"不要 alpha"，写出来的 PNG 是 color type 2（RGB）。
        guard let ctx = CGContext(data: nil, width: cw, height: ch,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        // 居中。窗口正好等于画布时偏移是 0，也就是满幅，没有任何缩放或重采样。
        let x = (cw - cg.width) / 2
        let y = (ch - cg.height) / 2
        ctx.draw(cg, in: CGRect(x: x, y: y, width: cg.width, height: cg.height))
        guard let flattened = ctx.makeImage() else { return nil }
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flattened, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }

    /// 放得下这张窗口图的**最小**合法画布。
    static func canvas(fitting raw: CGSize) -> CGSize? {
        accepted.sorted { $0.width < $1.width }
            .first { $0.width >= raw.width && $0.height >= raw.height }
    }

    /// 窗口截图原始的像素尺寸（合成之前）。
    private func rawPixelSize(_ shot: XCUIScreenshot) -> CGSize {
        pixelSize(shot.pngRepresentation)
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
        var lines = ["windows=\(app.windows.count) app.state=\(app.state.rawValue)"
                     + "（1=notRunning 2=runningNotForeground 3=runningForeground 4=runningBackground）"]
        for w in app.windows.allElementsBoundByIndex.prefix(3) {
            lines.append("  [window] frame=\(w.frame) title=\(w.title.debugDescription)")
        }
        for id in ["listings", "map", "calendar", "alerts", "stats"] {
            let pane = app.descendants(matching: .any).matching(identifier: "pane-\(id)").firstMatch
            if pane.exists { lines.append("  [pane] 当前显示：\(id)") }
        }
        lines.append(screenReport())
        return lines.joined(separator: "\n")
    }
}
