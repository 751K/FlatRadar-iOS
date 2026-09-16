import Foundation

/// 「从这套房出发，N 分钟能到多远」的半径。
///
/// 这段算法原先只在 iOS 的 `MapView` 里（`reachRadius` + `detourFactor`）。
/// Mac 的地图也要画同样的圈，而两处各写一份必然漂移——改了系数忘了另一边，
/// 两端的同一个圈就会画出不同的大小。所以提到包里，两端共用。
///
/// **共用的是算法和系数，分钟数由各端自己定。** 两端目前都画「步行 10 分钟 /
/// 骑车 10 分钟」，所以同一套房在 iPhone 和 Mac 上的圈一样大；但那是各自选的结果，
/// 不是这里强制的。真正会悄悄漂移的是 `detourFactor` 这种隐含假设——改了一边
/// 忘另一边，两端的同一个圈就画出不同的大小，而且没人会发现。
public nonisolated enum Reachability {

    /// 绕路系数：直线距离 × 系数 ≈ 实际路程。
    ///
    /// 圆是**直线**距离，而人得沿街走／沿路骑——阿姆斯特丹还隔着运河，直线 800m
    /// 常常是一公里多的路。不校正的话圈会系统性地过于乐观，用户照着圈选了房、
    /// 实际走起来不是那么回事。
    ///
    /// 1.3 是城市路网的常见经验值（运河城市偏高端）。宁可画保守——圈内一定到得了，
    /// 比圈内可能到不了要好。
    public static let detourFactor: Double = 1.3

    /// 步行速度，km/h。
    public static let walkingKmh: Double = 5

    /// 骑车速度，km/h。
    ///
    /// 荷兰的日常出行默认就是自行车，「骑十分钟能到哪儿」跟「走十分钟能到哪儿」
    /// 是两个量级（1.9km vs 0.64km），而后者根本圈不到大多数人真正在意的东西。
    public static let cyclingKmh: Double = 15

    /// 半径，米。
    ///
    ///     步行  5 km/h  = 83 m/min   → 有效 64 m/min
    ///     骑车  15 km/h = 250 m/min  → 有效 192 m/min
    ///
    /// 这仍然是**估算，不是等时线**。真等时线要对每个方向发路径请求，代价完全不同；
    /// 这里要的只是"大概多远"的量感。
    public static func radius(kmh: Double, minutes: Int) -> Double {
        kmh * 1000 / 60 / detourFactor * Double(minutes)
    }

    /// 把坐标沿正北移动若干米，用来把分钟标签摆在圈的顶端。
    ///
    /// 只动纬度，所以不需要按纬度修正经度——1 度纬度在任何地方都约 111.32km。
    public static func offsetNorth(latitude: Double, meters: Double) -> Double {
        latitude + meters / 111_320
    }
}
