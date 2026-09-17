import Foundation

/// 「当前状态」那几句话，全 App 唯一一份。
///
/// 同一件事现在有两个出口：Mac 的菜单栏那一格（``MenuBarStatusView``）和桌面
/// 小组件（``StatusWidget``），docs/NEXT.md 里 iOS 的主屏小组件是第三个。
/// docs/MACOS.md 对它们只有一句要求：
///
/// > 最后一条和 iOS 那个"状态型小组件"是同一个东西，先做哪个都行，
/// > 但**文案和口径要一致**。
///
/// 一句写在文档里的要求，靠的是每个动这段代码的人记得；写成下面这三个函数，
/// 靠的是编译器。差别在「改一处忘了另一处」发生的时候：前者两端从此说两种话，
/// 而且不会有任何东西报错。
///
/// 这不是假想。写这份文件时 `MenuBarStatus.swift` 的注释里写着「没套就是
/// `Showing`」，而它正下方那行代码返回的是 `Listings`——注释和代码在同一个屏幕上
/// 已经对不上了。
public nonisolated enum StatusWording {

    /// 套了个人筛选叫 `Matching filters`，没套叫 `Listings`。
    ///
    /// 两处说法不一致的话，用户会以为那是两个数。
    public static func countLabel(isFiltered: Bool) -> String {
        isFiltered ? "Matching filters" : "Listings"
    }

    /// 拿不到就是 `—`，**不是 `0`**。
    ///
    /// 0 是「一套都没匹配上」，那是个事实；拿不到不是事实，是没拿到。
    public static func countText(_ count: Int?) -> String {
        count.map(String.init) ?? "—"
    }

    /// `scanned 4m ago`。参数是 ``ServerTime/relativeTime(_:now:)`` 的结果。
    public static func scanned(_ ago: String) -> String { "scanned \(ago)" }

    /// 连扫描时间都没拿到时说的话。
    ///
    /// **不写 "scanned unknown"**——那会被读成「扫过了，但不知道什么时候」，
    /// 而实际是「没拿到这条信息」。
    public static let scanTimeUnavailable = "Last scan time unavailable"
}
