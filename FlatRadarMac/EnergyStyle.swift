import SwiftUI
import FlatRadarCore

/// 能效等级的显示色。
///
/// 只给 **A 档**上色（A+++ / A++ / A+ / A），B 及以下用正文色。
///
/// 为什么不给 B/C/D 也配色
/// ----------------------
/// 包里的语义 token 只有三个，全在 A 档（`energyTop` / `energyAPlus` / `energyA`）。
/// iOS 的 Dashboard 给 B/C/D 用了 `.yellow` / `.orange` / `.red` 系统色——那在
/// 一张条形图里说得过去（图表本来就要把所有档次区分开），但在**表格的一列**里
/// 是另一回事：一列里出现黄橙红三种颜色，会读成「这些房源有问题」，而能效 C
/// 只是普通，不是告警。
///
/// 所以这里的规则是：**上色表示「好」，不上色表示「普通」**。要给 B 以下配色
/// 的话，先往包里加 token，别在 Mac 这边硬编码一套。
enum EnergyStyle {

    private static let letters = Array("ABCDEFG")

    /// A+++ = 0, A++ = 1, A+ = 2, A = 3, B = 4, C = 5 …… 认不出返回 nil。
    ///
    /// 判据抄自 iOS `DashboardView.energyRank`，但**不复用**——那是个 private
    /// 函数，跨 target 拿不到。真要共享应该往 `FlatRadarCore` 里放一份，
    /// 那是单独一件事，不混在铺界面里做。
    ///
    /// ⚠️ 只有 A 档细分加号（A+++ / A++ / A+ / A 各占一格）。B 以下的加号被忽略，
    /// `D+` 和 `D` 同秩——因为下面 ``color(_:)`` 对它们的处理本来就一样。
    /// 要拿这个秩去**排序**的话得先补上，别直接拿去用。
    static func rank(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard let first = s.first, let letter = letters.firstIndex(of: first) else {
            return nil
        }
        guard letter == 0 else { return letter + 3 }
        // A 档：加号越多越好，所以在档内倒着数。
        let pluses = s.dropFirst().prefix { $0 == "+" }.count
        return 3 - min(pluses, 3)
    }

    /// 表格 / 详情里那个字母的颜色。B 及以下返回 nil，由调用方落到正文色。
    static func color(_ raw: String?) -> Color? {
        switch rank(raw) {
        case 0, 1: return .energyTop      // A+++ / A++
        case 2:    return .energyAPlus    // A+
        case 3:    return .energyA        // A
        default:   return nil             // B 及以下、以及认不出的
        }
    }
}


/// 房型文本。
///
/// 后端 `feature_map` 里的房型有两种写法：`Studio` / `Loft` 这样的词，
/// 和 `1` / `2` 这样的**光秃秃的数字**（意思是几居）。原样显示的话，
/// Type 那一列里会出现 `Studio`、`Loft`、`2` 混排，而 inspector 的比价
/// 那句话会变成「Price vs. 2 in Amsterdam」——读起来完全不知所云。
///
/// 只补数字那一种，别的原样透传：不认识的写法乱改比不改更糟。
enum RoomType {

    static func display(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        guard s.allSatisfy(\.isNumber), let n = Int(s) else { return s }
        return n == 1 ? String(localized: "1-room") : String(localized: "\(n)-room")
    }
}
