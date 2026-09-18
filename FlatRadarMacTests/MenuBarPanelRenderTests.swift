import XCTest
import SwiftUI
import AppKit
import FlatRadarCore
@testable import FlatRadarMac

/// 把菜单栏面板真的画出来。
///
/// 为什么值得为一个面板专门写渲染
/// ----------------------------
/// 小组件那一轮的经验：**看得见的问题读代码看不见**。那一轮抓到的八处——胶囊
/// 变成药丸、空状态留一个孤零零的标题、`Status changes` 在 155pt 下被截断、
/// 大号在真实高度上被裁掉——没有一处是 review 能发现的，全是渲染出来之后一眼
/// 就看到的。
///
/// 这里断言的是**尺寸**，不是像素比对。像素比对在系统换一版字体就整片红，
/// 而真正要防的是"这一屏悄悄长高了 300pt"或者"空数据时塌成一条线"这种事；
/// 那两件事尺寸就能钉住。图本身写进容器的 tmp，人要看的时候自己去翻。
///
/// 打开图：
/// ```
/// open ~/Library/Containers/com.j.kong.FlatRadar/Data/tmp/menubar/
/// ```
@MainActor
final class MenuBarPanelRenderTests: XCTestCase {

    // MARK: - 样例

    /// 一份看着像真的数据。
    ///
    /// 房源名字**故意取真实长度**（Holland2Stay 的真实房源名就是这种
    /// "街名 + 门牌 + 城市" 的结构）：360 宽下标题什么时候开始截断，是这一屏
    /// 唯一一个靠"想"想不出来的数。
    private static let sample = MenuBarPanel(
        newToday: 31,
        changeVsBaseline: 63,
        series: [12, 19, 8, 24, 16, 21, 11, 30, 14, 9, 22, 18, 26, 31],
        scannedAgo: "1m ago",
        offline: false,
        filterSummary: "≤ €1,200/mo · ≥ 25 m² · Eindhoven · 2+ rooms",
        unread: 7,
        rows: [
            row("Kastanjelaan 400", "Eindhoven · Holland2Stay", "€1,125", "2h", .book),
            row("Vestdijk 25-A", "Eindhoven · Holland2Stay", "€985", "5h", .lottery),
            row("Mathildelaan 1200", "Eindhoven · Xior", "€1,340", "9h", .reserved),
            row("Willemstraat 44-B", "Eindhoven · Plazza", "€1,050", "1d", .book),
            row("Hurksestraat 19", "Eindhoven · Holland2Stay", "€890", "1d", .lottery),
        ],
        nextMoveIn: (date: Date(timeIntervalSince1970: 1_790_000_000), days: 6))

    private static func row(_ title: String, _ subtitle: String,
                            _ price: String, _ age: String,
                            _ status: ListingStatus) -> MenuBarPanel.Row {
        MenuBarPanel.Row(id: title, title: title, subtitle: subtitle,
                         price: price, age: age, status: status)
    }

    // MARK: - 渲染

    func test_满数据的面板在两种外观下都画得出来() throws {
        let light = try render(Self.sample, dark: false, name: "01-full-light")
        let dark = try render(Self.sample, dark: true, name: "01-full-dark")

        XCTAssertEqual(light.width, Int(MenuBarPanelView.width * 2),
                       "面板宽度应当就是稿子那 360（2x 渲染）")
        XCTAssertEqual(light.height, dark.height,
                       "同一份数据在浅色和深色下高度必须一致——不一致意味着某一边"
                       + "多画或少画了一块，而那种差异肉眼很难在两张图之间发现。")
    }

    /// 这一屏最容易悄悄失控的就是高度：菜单栏面板贴着屏幕上沿往下开，
    /// 太高会一直怼到 Dock。上限按 1080p 屏减菜单栏和一点余量定。
    func test_面板高度落在可接受的范围内() throws {
        let image = try render(Self.sample, dark: false, name: "02-height")
        let points = image.height / 2

        XCTAssertGreaterThan(points, 380,
                             "比 380 还矮说明有整块没画出来（五行房源就占 200）")
        XCTAssertLessThan(points, 620,
                          "超过 620 在 13 吋屏上会顶到 Dock。真要加东西，"
                          + "先想清楚砍掉哪一块。")
    }

    /// 空数据：刚装上、还没拉到任何东西的那一刻。
    ///
    /// 要看的是**它不会塌成一条线，也不会留下一个孤零零的 NEWEST**。
    func test_什么都没有的时候不留空壳() throws {
        let empty = MenuBarPanel()
        let image = try render(empty, dark: false, name: "03-empty-light")
        _ = try render(empty, dark: true, name: "03-empty-dark")

        let points = image.height / 2
        XCTAssertGreaterThan(points, 150, "页眉 + 锚点 + 底部三项，怎么也不止这么点")
        XCTAssertLessThan(points, 260,
                          "空数据不该占到有数据时的一半以上——那说明有块空白没收走")
    }

    /// 访客：没有筛选行，没有未读胶囊。
    func test_访客那两块是收起来的而不是显示成零() throws {
        var guest = Self.sample
        guest.filterSummary = nil
        guest.unread = 0

        let image = try render(guest, dark: false, name: "04-guest")
        let full = try render(Self.sample, dark: false, name: "04-full")

        XCTAssertLessThan(image.height, full.height,
                          "筛选行收起来之后整屏必须变矮。一样高就说明那一行只是"
                          + "透明了、位置还占着——那是这一屏最早的写法，改过。")
    }

    /// 后端挂了：那颗点变橙，扫描时间那句换成说不知道。
    func test_拿不到扫描时间时不编一个() throws {
        var offline = Self.sample
        offline.offline = true
        offline.scannedAgo = nil
        offline.newToday = nil
        offline.changeVsBaseline = nil

        _ = try render(offline, dark: false, name: "05-offline-light")
        _ = try render(offline, dark: true, name: "05-offline-dark")
    }

    /// 长到离谱的筛选串。设置页十三个维度全勾上就是这个样子。
    func test_很长的筛选串只截断自己不撑破面板() throws {
        var long = Self.sample
        long.filterSummary = "≤ €2,000/mo · ≥ 40 m² · Floor ≥ 2 · Eindhoven, Amsterdam, "
            + "Rotterdam, Utrecht · H2S, OC, XR, MG · Energy ≥ A · Furnished · Long stay"

        let image = try render(long, dark: false, name: "06-long-filter")
        XCTAssertEqual(image.width, Int(MenuBarPanelView.width * 2),
                       "筛选串再长也不能把面板撑宽——那一行是 lineLimit(1) + 尾部截断")
    }

    // MARK: - 登录页：连不上服务器时的提示

    /// 登录表单最宽 380pt。提示那段话在这个宽度下要能**完整折行**，不能被截断成
    /// 一行省略号——那句「你仍是登录状态」恰恰是整条提示唯一有用的信息。
    func test_连不上服务器的提示在登录表单宽度里完整显示() throws {
        for (name, dark, retrying) in [("08-restore-light", false, false),
                                       ("08-restore-dark", true, false),
                                       ("08-restore-retrying", false, true)] {
            let size = try render(RestorePendingNotice(isRetrying: retrying) {}
                                    .frame(width: 380),
                                  dark: dark, name: name)
            XCTAssertEqual(size.width, 760)
            XCTAssertGreaterThan(size.height / 2, 90,
                                 "标题 + 两行说明 + 按钮，矮于 90pt 说明说明文字被截成了一行")
        }
    }

    // MARK: - 菜单栏上那一格

    /// 房子、数字、未读菱形三样东西在竖直方向上**居中对齐**。
    ///
    /// 上一版在真菜单栏上量的（2x 像素）：房子 17–43、数字 19–37——中心差 2px，
    /// 而且上面只多出 2px、下面多出 6px，看起来就是房子往下掉了一截。那是
    /// `MenuBarExtra` 把 `HStack` 拆给 `NSStatusBarButton` 各排各的结果（见
    /// ``MenuBarGlyph``）。现在整格画成一张图，对齐是我们自己的事，所以要钉住。
    ///
    /// 比的是**中心**，不是底边
    /// ----------------------
    /// 第一版这条测试比的是"房子底边落在数字基线上"，跑出来差 5px、红了。但那是
    /// 标准写错了：SF Symbol 插进 `Text` 之后是按**中线**和文字配对的——符号比
    /// 大写字母高，所以上下各出头一点（这里是 4px / 5px）。菜单栏里图标配文字的
    /// 惯例也是这样（电池图标配 `100%`）。上一版的毛病不是"出头"，是**不对称**。
    ///
    /// 量法和在真菜单栏上量的一样：按列切出墨迹段，比每段的上下沿。
    func test_菜单栏字形里房子数字和菱形在同一条中线上() throws {
        let runs = try glyphRuns(newToday: 36, hasUnread: true, name: "07-glyph-unread")
        _ = try glyphRuns(newToday: 36, hasUnread: false, name: "07-glyph-plain")

        // 房子 + "3" + "6" + 菱形 = 4 段
        XCTAssertEqual(runs.count, 4, "应当是房子、两个数字、菱形四段墨迹，实际 \(runs)")
        guard runs.count == 4 else { return }
        let house = runs[0], digit = runs[1], mark = runs[3]
        print("› [glyph] house \(house)  digit \(digit)  mark \(mark)")

        XCTAssertLessThanOrEqual(abs(house.center - digit.center), 1,
                                 "房子和数字的中线要重合（±1px @2x）。上一版在菜单栏上差 2px、"
                                 + "而且上下出头 2px / 6px，看着像房子掉下去了。")
        XCTAssertLessThanOrEqual(abs((digit.top - house.top) - (house.bottom - digit.bottom)), 2,
                                 "房子比数字高出来的部分要上下对称——不对称正是上一版的样子")
        XCTAssertLessThanOrEqual(abs(mark.center - digit.center), 1,
                                 "未读菱形要在数字的视觉中线上，不能坐在基线上")
    }

    /// 交给系统的那张图，墨迹**上下贴边**。
    ///
    /// `NSStatusBarButton` 按图的中心摆。图里上下的空白不一样多，这一格就会
    /// 整体偏上或偏下——没裁之前是上空 4px、下空 2px，在菜单栏里比系统图标低
    /// 1.5px。这条测的是真正交出去的那张 `MenuBarGlyph.image(...)`，不是视图。
    func test_交给菜单栏的那张图上下没有空白() throws {
        for unread in [false, true] {
            let image = MenuBarGlyph.image(newToday: 36, hasUnread: unread)
            XCTAssertTrue(image.isTemplate, "要是 template，菜单栏深浅和点开高亮才对")
            var rect = NSRect(origin: .zero, size: image.size)
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cg)
            let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
            func rowHasInk(_ y: Int) -> Bool {
                (0..<w).contains { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0 }
            }
            XCTAssertTrue(rowHasInk(0), "第一行就该有墨迹（unread=\(unread)）")
            XCTAssertTrue(rowHasInk(h - 1), "最后一行就该有墨迹（unread=\(unread)）")
        }
    }

    private struct InkRun: CustomStringConvertible {
        let left: Int, right: Int, top: Int, bottom: Int
        var center: Double { Double(top + bottom) / 2 }
        var description: String { "x\(left)–\(right) y\(top)–\(bottom)" }
    }

    /// 画一张菜单栏字形，按列切出墨迹段，返回每段的包围盒（2x 像素）。
    private func glyphRuns(newToday: Int?, hasUnread: Bool, name: String) throws -> [InkRun] {
        var rendered: NSImage?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: MenuBarGlyph(newToday: newToday,
                                                               hasUnread: hasUnread))
            renderer.scale = 2
            rendered = renderer.nsImage
        }
        let image = try XCTUnwrap(rendered)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        if let png = bitmap.representation(using: .png, properties: [:]) {
            dump(png, name: name, path: "(glyph)")
        }

        let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
        func ink(_ x: Int, _ y: Int) -> Bool { (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }

        var runs: [InkRun] = []
        var start: Int?
        for x in 0...w {
            let hasInk = x < w && (0..<h).contains { ink(x, $0) }
            if hasInk, start == nil { start = x }
            if !hasInk, let s = start {
                let rows = (0..<h).filter { y in (s..<x).contains { ink($0, y) } }
                runs.append(InkRun(left: s, right: x - 1, top: rows.first!, bottom: rows.last!))
                start = nil
            }
        }
        return runs
    }

    // MARK: - 工具

    private struct RenderedSize { let width: Int; let height: Int }

    /// 画一张，写进容器的 tmp，返回像素尺寸。
    ///
    /// `performAsCurrentDrawingAppearance` 不能省：``Theme`` 里那几个颜色是
    /// `NSColor(name:dynamicProvider:)`，它们看的是**当前绘制外观**，不是
    /// SwiftUI 的 `\.colorScheme`。只设后者的话，深色那张会是"深色的系统色 +
    /// 浅色的自定义色"，混出来的图比全错还难发现。
    private func render(_ panel: MenuBarPanel, dark: Bool, name: String) throws -> RenderedSize {
        try render(MenuBarPanelView(panel: panel), dark: dark, name: name)
    }

    private func render(_ content: some View, dark: Bool, name: String) throws -> RenderedSize {
        let view = content
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(white: 0.11) : Color(white: 0.97))

        var image: NSImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            // 2x：面板上最小的字是 10pt，1x 下渲染出来的图人眼读不准是不是截断了。
            renderer.scale = 2
            image = renderer.nsImage
        }

        let rendered = try XCTUnwrap(image, "ImageRenderer 没画出东西")
        let bitmap = try XCTUnwrap(
            rendered.representations.first as? NSBitmapImageRep
            ?? NSBitmapImageRep(data: rendered.tiffRepresentation ?? Data()),
            "拿不到位图")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]),
                                "编不出 PNG")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("menubar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).png")
        try png.write(to: file)
        dump(png, name: name, path: file.path)

        return RenderedSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }

    /// 把图**打进日志**，而不只是写文件。
    ///
    /// 这不是图省事：`FlatRadarMac` 是沙盒 app，测试跑在它的进程里，写得出去的
    /// 地方只有自己的容器（`~/Library/Containers/…/Data/tmp`）。而那个目录受
    /// TCC 保护，容器外的进程——包括开着终端的我自己——`ls` 上去就是
    /// `Operation not permitted`。图写成功了却谁也看不到，等于没渲染。
    ///
    /// 所以额外走一趟 base64。取出来：
    ///
    /// ```
    /// xcodebuild test … | sed -n 's/^› \[png\] 01-full-light //p' | base64 -d > a.png
    /// ```
    ///
    /// CI 上不打。那边没人看图，而十张 2x 的 PNG 是一兆多的日志。
    private func dump(_ png: Data, name: String, path: String) {
        print("› [render] \(name) → \(path)")
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }
        print("› [png] \(name) \(png.base64EncodedString())")
    }
}
