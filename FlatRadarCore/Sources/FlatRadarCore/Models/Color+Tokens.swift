import SwiftUI

/// 全 App 共享的**语义色 token**。每个 token 都在 Assets.xcassets 中配了
/// 亮/暗双值，UIKit / SwiftUI 自动按 traitCollection 切换。
///
/// 设计原则
/// --------
/// - **按语义命名，不按颜色值**：`statusBook` 而非 `green`。这样未来 Holland2Stay
///   重新定义"book"语义颜色时，改 Asset Catalog 一处即可，所有调用方自动跟随。
/// - **跨文件复用才进 token**：屏幕专属的 chrome（如 LoginView hero gradient）
///   保留在原文件里，避免 token 体系膨胀。
/// - **优先复用系统语义色**：能直接用 `Color.accentColor` / `Color(.systemGray)`
///   的就别再造 token。这里只定义 SwiftUI 体系里**没有现成对应**的业务色：
///     - status 是 Holland2Stay 三态业务语义（book/lottery/reserved）
///     - energy 是房源能效等级颜色光谱（A+++ 深绿 → D+ 红，跨多色 hue）
/// `nonisolated`：这些是**纯常量**，没有任何可变状态。
///
/// 工程开着 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（Xcode 26 为视图代码
/// 省事的默认值），没标注的类型一律隐式 @MainActor——色板跟着被钉在主 actor 上，
/// 于是任何 nonisolated 的地方（模型层、后台解码、同步的单元测试）引用它都要报
/// "cannot be referenced from a nonisolated context"。
///
/// 模型层和常量是这个默认值的例外：它们本来就该跟 actor 无关。
public nonisolated extension Color {
    // MARK: - Status (Holland2Stay 三态业务语义)

    /// "Available to book"——绿色，先到先得状态。
    /// 复用为：listing 状态徽章、notification kind=book 卡片、NEW 标签。
    static let statusBook = Color("Status/Book", bundle: .module)

    /// "Available in lottery"——橙色，抽签状态。
    static let statusLottery = Color("Status/Lottery", bundle: .module)

    /// "Reserved" / "In Process"——蓝色，**暂时**订不了但可能回来。
    ///
    /// 2026-09-02 由灰改蓝：此前 Reserved 和 Occupied 共用同一个灰，于是「有人
    /// 占着，退订就放出来」和「已经租出去了」在界面上完全一样。原来那套灰保留
    /// 在 ``statusOccupied``，语义没变的调用点应当改指它。
    static let statusReserved = Color("Status/Reserved", bundle: .module)

    /// "Occupied" / "Rented" / "Not available"——灰色，**终态**。
    static let statusOccupied = Color("Status/Occupied", bundle: .module)

    /// 认不出的状态——紫色。不并进灰色，否则新平台的新状态会跟着终态一起被
    /// 地图筛选默认隐藏，从图上静默消失。见 ``ListingStatus``。
    static let statusUnknown = Color("Status/Unknown", bundle: .module)

    // MARK: - Energy label 能效等级光谱

    /// A+++ / A++ —— 最高能效等级，深绿。
    static let energyTop = Color("Energy/Top", bundle: .module)

    /// A+ —— Apple system green，同 `statusBook` 但语义不同（这里是能效不是租态）。
    static let energyAPlus = Color("Energy/APlus", bundle: .module)

    /// A —— 浅绿/lime，比 A+ 更淡一档。
    static let energyA = Color("Energy/A", bundle: .module)

    // MARK: - 徽标上的字色

    /// 把一个"底色"换算成**写在它 13–16% 淡底上的字色**：浅色模式压暗、
    /// 深色模式提亮。
    ///
    /// 要解决什么
    /// ----------
    /// 全 App 的徽标（平台缩写、状态胶囊）此前都是「同一个色当字、又当 16%
    /// 的底」。那样字和底的色相一样、明度只差一点点，对比度最高 3.3:1、最低
    /// 1.8:1——iPad 上实测 `H2S` 徽标 **3.19:1**、Map 图例的 `Lottery` /
    /// `Reserved` / `Direct book` 全部不过。而徽标是 11–12pt，不算大字号，
    /// 门槛就是 4.5:1。设计系统里那句写得更直接：`gray` 3.2:1「symbols and
    /// rules, never text」——而这里是**文字**。
    ///
    /// 为什么不是「填满色底 + 白字」
    /// --------------------------
    /// 那条路被规范堵死了：`on-accent` 在 `blue` 上只有 3.5:1，只在 **semibold
    /// 17pt 及以上**才够。徽标怎么都到不了那个字号。
    ///
    /// 比例是算出来的
    /// -------------
    /// 八个平台色 + 五个状态色各自和自己的淡底算一遍：浅色下最差的是 teal
    /// （原 1.80:1）和 orange（2.02:1），要 0.45 才分别到 5.27 / 5.72；深色下
    /// 底本来就暗，0.25 就让最差的 purple 到 5.15。两个数取的是「让最差的那个
    /// 也过 4.5」，不是调出来好看的。
    ///
    /// `in: .device` 不是默认的 `.perceptual`：上面那些数是按 sRGB 混合算的，
    /// 换个色彩空间混出来就是另一个颜色，结论也就不成立了。
    func onTint(in scheme: ColorScheme) -> Color {
        scheme == .dark
            ? mix(with: .white, by: 0.25, in: .device)
            : mix(with: .black, by: 0.45, in: .device)
    }

    /// 同样的事，但用在**普通背景**上——没有那层同色淡底的小字。
    ///
    /// 分两个方法而不是一个，是因为要补的量不一样：淡底本身就带着色相，所以
    /// 字要压得更狠（0.45）；白底上 0.35 就够（最差的 teal 4.59、green 4.92，
    /// 都过 4.5），再压就只是白白丢掉色相。
    ///
    /// 深色下一档都不用动：十个色在 `#1C1C1E` 上原样就是 4.69–9.30:1，最差的
    /// purple 也过线。混一下反而让「深色模式里颜色更亮」这个预期落空。
    func onSurface(in scheme: ColorScheme) -> Color {
        scheme == .dark ? self : mix(with: .black, by: 0.35, in: .device)
    }
}
