import MapKit
import SwiftUI

/// 地图上保留哪几类 POI，以及放大到多少才显示。
///
/// 这段原先只在 iOS 的 `MapView` 里（`poiCategories` + `poiMaxSpan`）。Mac 的地图
/// 补 POI 时面临同一个选择，而**"哪几类 POI 和租不租得下去有关"是一个产品判断，
/// 不是两端各自的界面口味**——一端加了 `.hospital`、另一端没加，就成了同一张图在
/// 两个设备上说不同的话。所以提到包里。
///
/// 为什么需要 MapKit
/// ----------------
/// 这是包里唯一 `import MapKit` 的文件。`MKPointOfInterestCategory` 是个系统类型，
/// 想共享这份名单就绕不开它——把它降级成字符串再在两端转回去，只是把同一个依赖
/// 藏起来，还多了一层会写错的映射。
public nonisolated enum MapPOI {

    /// 留下来的三类。
    ///
    /// 判据是**"地图能直接回答、而房源数据里没有"**：
    ///
    /// - `.foodMarket` —— 楼下有没有超市
    /// - `.publicTransport` —— 离车站多远
    /// - `.school` —— 附近有没有学校
    ///
    /// 刻意不含 `.restaurant` / `.cafe` / `.nightlife` / `.store`：它们密度高，
    /// 且跟"住不住得下去"没关系；`.store` 尤其宽，一放开就把整条商业街铺满，
    /// 房源图钉反而淹了。
    public static let categories: [MKPointOfInterestCategory] = [
        .foodMarket,
        .publicTransport,
        .school,
    ]

    /// 放大到什么程度才显示 POI（纬度跨度，单位度）。
    ///
    /// 0.05° ≈ 5.5km，大约一个城区。概览视角下满屏都是聚类气泡，这时候叠 POI
    /// 等于把"地图太吵"这个问题原样请回来；到这个尺度用户已经在看"具体这一带
    /// 怎么样"，POI 才开始有意义，而房源也散成了单个标记。
    public static let maxSpan: Double = 0.05

    /// 这个跨度下该不该显示 POI。
    ///
    /// 判断单独抽成 `Bool` 是为了**能测**：下面那个返回的
    /// `PointOfInterestCategories` 是 SwiftUI 的类型，**它不 `Equatable`**，
    /// 测试里断不了"返回的是不是这一组"。而真正值得钉住的本来就是这个判断。
    public static func isVisible(atSpan span: Double) -> Bool {
        span <= maxSpan
    }

    /// 当前跨度下该显示哪些。
    ///
    /// 两端共用这一个判断，而不是各写一个 `span <= 0.05 ? ... : ...`——
    /// 阈值和"跨过阈值之后做什么"是同一件事，拆开就是留了个漂移的口子。
    public static func categories(atSpan span: Double) -> PointOfInterestCategories {
        isVisible(atSpan: span) ? .including(categories) : .excludingAll
    }
}
