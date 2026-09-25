import SwiftUI

/// 登录屏的三套尺寸，逐条抄自设计稿。
///
/// 为什么把数字抽出来
/// ----------------
/// 三种布局（iPhone / iPad 竖屏 / iPad 横屏）**结构上只有一处真的不同**——横屏是
/// 左右分栏，另外两种都是「头部 → 插画 → 白卡」竖着排。剩下的差异全是数值：
/// 标题 27 / 38 / 40，卡片圆角 16 / 22 / 22，图标底 44 / 56 / 56……
///
/// 把它们写成三个 `if isPad` 散在视图里，等于把「这一屏长什么样」拆碎成几十个
/// 条件表达式，改一个字号要在三处找。集中成一张表之后，视图代码只有一份，
/// 对着设计稿核对也只用看这个文件。
///
/// 出处
/// ----
/// - iPhone：`FlatRadar iOS - Sign in.dc.html` A / B 两屏
/// - iPad：`FlatRadar iPad - Sign in.dc.html` A（竖 834×1194）/ B（横 1194×834）/ C（横深色）
///
/// CSS px 和 SwiftUI pt 在这些稿子里是 1:1（稿子按点阵尺寸画的），所以数值直接搬。
///
/// 这些字号怎么跟随系统字号
/// ----------------------
/// 表里的字号是**稿子上的绝对值**（27 / 38 / 40、10.5、14……），一个都不落在
/// iOS 的标准字阶上，硬套 `.caption2` / `.title` 那套等于把设计稿改了。所以视图
/// 里不写 `.font(.system(size:))`——那个完全不理会「辅助功能 → 字体大小」——而是
/// 走 ``ScaledFont``（`.scaledFont(_:relativeTo:)`）：保住稿子上的数值，同时让它
/// 按 `relativeTo:` 那一档的比例缩放。这一屏是新用户看到的**第一屏**，把字号调大
/// 的人从这里就开始读。
nonisolated struct LoginMetrics {

    // MARK: - 结构

    /// 横屏 iPad：左右分栏。另两种都是竖着排。
    var splitsColumns = false
    /// 分栏时左栏的固定宽度（设计稿 B：560）。
    var leftColumn: CGFloat = 0
    /// 内容列上限。iPhone 是满宽（nil），iPad 竖屏是 700 居中。
    var columnWidth: CGFloat?
    /// 两张角色卡并排（只有 iPad 竖屏这么排——那一屏宽而不高，竖着排会把白卡撑出屏幕）。
    var cardsSideBySide = false
    /// 那排平台缩写。设计稿只在 iPad 上有——iPhone 那一屏塞不下，
    /// 而且标题下面那句已经写了「across 7 rental platforms」。
    var showsPlatformCodes = false
    /// 页脚是否居中。横屏那一栏是左对齐的，Terms 在左、域名被推到右端。
    var centersFooter = true

    // MARK: - 头部

    var heroTopPadding: CGFloat = 6
    var heroSidePadding: CGFloat = 24
    var wordmark: CGFloat = 22
    var caption: CGFloat = 10.5
    var captionTracking: CGFloat = 1.4
    var headline: CGFloat = 27
    var headlineTracking: CGFloat = -0.8
    /// 标题的折行宽度。iPad 竖屏给 580（设计稿 `max-width:580px`）——
    /// 700 的列宽会把这句话排成两行很长的字，读起来比三行短句累。
    var headlineMaxWidth: CGFloat?
    var subtitle: CGFloat = 15

    // MARK: - 统计胶囊

    var chipHeight: CGFloat = 34
    var chipRadius: CGFloat = 11
    var chipSidePadding: CGFloat = 13
    var chipFont: CGFloat = 14
    var chipGap: CGFloat = 8
    /// 绿点 / 空心圈 / 小菱形的直径。
    var chipDot: CGFloat = 8

    // MARK: - 插画

    var skylineHeight: CGFloat = 140

    // MARK: - 白卡

    var sheetRadius: CGFloat = 26
    var sheetTopPadding: CGFloat = 18
    var sheetSidePadding: CGFloat = 20
    var sectionLabel: CGFloat = 11.5
    var sectionLabelTracking: CGFloat = 1.6

    var cardRadius: CGFloat = 16
    var cardSidePadding: CGFloat = 14
    var cardTopPadding: CGFloat = 13
    var cardBottomPadding: CGFloat = 13
    var cardGap: CGFloat = 10
    var iconTile: CGFloat = 44
    var iconTileRadius: CGFloat = 12
    var iconGlyph: CGFloat = 20
    var cardTitle: CGFloat = 17
    var cardDescription: CGFloat = 13.5
    var chevron: CGFloat = 17

    var faceHeight: CGFloat = 56
    var faceFont: CGFloat = 16
    var faceGlyph: CGFloat = 22

    var legal: CGFloat = 11.5
    var link: CGFloat = 13
    var domain: CGFloat = 11.5

    // MARK: - 挑一套

    /// 按可用尺寸挑布局。
    ///
    /// 判据是**几何**不是 `horizontalSizeClass`：
    /// - iPad 竖屏和横屏的 hSize 都是 `.regular`，分不开这两套；
    /// - 而 iPad 分屏 / Slide Over 会给出很窄的一栏，那时候该用 iPhone 那套。
    ///
    /// `width > height` 这条判据和 App 其它 iPad 布局（Dashboard 分栏、日历分栏、
    /// 大数字卡排成一行）一致，见 `ScreenshotTests` 里那段注释。
    static func forSize(_ size: CGSize) -> LoginMetrics {
        // 判据是**短边**，不是宽度。
        //
        // 只看宽度会把 iPhone 横屏也判成 iPad：iPhone 16 Pro 横过来是 874×402，
        // 宽度 874 过线、而且 width > height，于是走 iPad 横屏那套——左栏 560、
        // 插画 230、顶部留白 74，全塞进 402pt 高里。这个工程 iPhone 是**允许横屏**
        // 的（`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` 里有
        // LandscapeLeft/Right），所以这不是理论问题。
        //
        // 600 这条线：iPad 分屏最窄的一栏 320–375pt，1/2 分屏 507（11 吋）到
        // 570（13 吋）——都还是 iPhone 那套更合适；真正宽到能摆 700 的列最少是
        // 744（iPad mini 竖屏）。iPhone 横屏短边最多 430（16 Pro Max），也在线下。
        guard min(size.width, size.height) >= 600 else { return .phone }
        guard size.width > size.height else { return .padPortrait }
        guard size.width >= 720 else { return .phone }
        return padLandscape(for: size)
    }

    /// iPhone，以及 iPad 上窄到只剩一栏的分屏。
    static let phone = LoginMetrics()

    /// iPad 竖屏（设计稿 A，834×1194）：单列 700 居中，房子占满宽度。
    static let padPortrait: LoginMetrics = {
        var m = LoginMetrics()
        m.columnWidth = 700
        m.cardsSideBySide = true
        m.showsPlatformCodes = true

        m.heroTopPadding = 34
        m.heroSidePadding = 32
        m.wordmark = 26
        m.caption = 11
        m.captionTracking = 1.6
        m.headline = 38
        m.headlineTracking = -1.2
        m.headlineMaxWidth = 580
        m.subtitle = 17

        m.chipHeight = 40
        m.chipRadius = 13
        m.chipSidePadding = 16
        m.chipFont = 15
        m.chipGap = 10
        m.chipDot = 9

        m.skylineHeight = 230

        m.sheetRadius = 32
        m.sheetTopPadding = 56
        m.sheetSidePadding = 32
        m.sectionLabel = 12
        m.sectionLabelTracking = 1.8

        m.cardRadius = 22
        m.cardSidePadding = 22
        m.cardTopPadding = 26
        m.cardBottomPadding = 28
        m.cardGap = 12
        m.iconTile = 56
        m.iconTileRadius = 16
        m.iconGlyph = 26
        m.cardTitle = 18
        m.cardDescription = 14
        m.chevron = 19

        m.faceHeight = 76
        m.faceFont = 17
        m.faceGlyph = 26

        m.legal = 12.5
        m.link = 14
        m.domain = 12
        return m
    }()

    /// iPad 横屏（设计稿 B / C，1194×834）：左右分栏，房子留在左栏。
    static let padLandscape: LoginMetrics = {
        var m = padPortrait
        m.splitsColumns = true
        m.leftColumn = 560
        m.columnWidth = nil
        m.cardsSideBySide = false
        m.centersFooter = false

        m.heroTopPadding = 74
        m.heroSidePadding = 44
        m.wordmark = 24
        m.headline = 40
        m.headlineTracking = -1.3
        m.headlineMaxWidth = nil

        // 右栏是一整块白，不是"下半屏的卡"，所以没有上边距那一说；
        // 左右 87 是设计稿给的。
        m.sheetTopPadding = 0
        m.sheetSidePadding = 87

        m.cardGap = 18
        m.cardBottomPadding = 26
        m.cardTitle = 19
        m.cardDescription = 14.5
        m.chevron = 20

        m.faceHeight = 78
        return m
    }()

    /// 横屏双栏按实际宽度缩放。1194pt 的 iPad 保留设计稿尺寸；更窄的横屏设备
    /// 收窄左栏并减小内边距，给右侧登录卡留出至少约 320pt 的阅读宽度。
    private static func padLandscape(for size: CGSize) -> LoginMetrics {
        var m = padLandscape
        m.leftColumn = min(m.leftColumn, size.width * 0.47)

        let rightWidth = max(0, size.width - m.leftColumn)
        let targetContentWidth = min(460, max(320, rightWidth * 0.72))
        m.sheetSidePadding = min(87, max(24, (rightWidth - targetContentWidth) / 2))

        let leftScale = m.leftColumn / padLandscape.leftColumn
        m.heroSidePadding = max(24, 44 * leftScale)
        m.headline = max(30, 40 * leftScale)
        m.heroTopPadding = max(40, min(74, size.height * 74 / 834))
        m.skylineHeight = max(150, min(230, size.height * 230 / 834))
        return m
    }
}
