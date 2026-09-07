import Foundation

/// 后端 feature 值的显示形态 —— **全 App 唯一一份**。
///
/// 后端把 feature 的值原样透出来，大小写全看各平台怎么写的：筛选页的 Tenant
/// 一屏上并排着 `student only` / `custom` / `employed only`，而同一个值在别处
/// 又写作 `Students only`。看着像没做完。
///
/// 这份逻辑原本长在 ``ListingDetailView.displayValue`` 里，是那个视图的私有方法。
/// 筛选页要用同样的规则，抄一份就会变成两份各自演化的实现——本项目已经在平台
/// 显示名上吃过一次亏（七个文件七份映射，没有一份是全的）。
nonisolated enum FeatureText {

    /// 统一首字母大写，但避开两类会被改坏的值。
    ///
    /// - 已登记的平台走 ``Platform.displayName``：机械地首字母大写会得到
    ///   "Ourcampus"，那既不是原样也不是正确写法，比不改还糟。
    /// - 首字母**不是小写**的一律原样返回："21.5 m²"、"1-Bedroom"、"A+"、
    ///   "XC 1112" 这类写法整串 title case 会被改坏，而它们都是数字或大写开头，
    ///   这条判据正好放过。
    ///
    ///   注意判据只看**第一个字符**，不是"含有单位/缩写就放过"。单独一个 "m²"
    ///   仍会被大写成 "M²"——它是小写开头。实际取值里不存在这种形态（面积长成
    ///   "21.5 m²"），所以无害；但别把这条注释当成"单位不会被动"来读，
    ///   FeatureTextTests 里为此专门钉了一条。
    static func display(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        if Platform.knownKeys.contains(trimmed.lowercased()) {
            return Platform.displayName(trimmed)
        }
        guard first.isLowercase else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// 房型（type）专用的显示形态：在 ``display(_:)`` 之上再剥掉尾部的括号注释。
    ///
    /// 后端 `/filter/options` 的 types 实测取值：
    ///
    ///     "1" "2" "3" "4" "2-room apartment" "3-room apartment"
    ///     "Apartment" "House" "Loft (open bedroom area)" "Studio"
    ///
    /// 只有 Loft 那个带括号，而括号里是平台对户型的补充描述，跟"这是什么房型"
    /// 无关——列表和详情页上只要 "Loft"。
    ///
    /// **为什么不做进 `display(_:)` 让所有维度都剥**：occupancy 的取值里括号是
    /// 有意义的——
    ///
    ///     "One" "Two" "Two (only couples)" "Family (parents with children)"
    ///
    /// 剥掉之后 `Two (only couples)` 变成 `Two`，跟已经存在的 `Two` 撞成同一个
    /// 显示值，两个不同的筛选项看起来一模一样。所以这个剥离只能**按维度**做。
    ///
    /// 剥的是**显示**，不是值：勾选、比对、回传给后端的仍然是原字符串，
    /// 跟 `display(_:)` 注释里那条「后端白名单匹配不上」是同一个理由。
    ///
    /// 如果哪天后端又加一个 `Loft (closed bedroom)`，两者会显示成同一个 "Loft"。
    /// 到那时该做的是按维度加一张显式映射表，而不是把括号还回来。
    /// 入住人数（occupancy）专用的显示形态：一张**显式映射表**。
    ///
    /// 线上取值：`"One"` `"Two"` `"Two (only couples)"`
    /// `"Family (parents with children)"`。
    ///
    /// 这里不能像房型那样机械地剥括号——`"Two (only couples)"` 剥完是 `"Two"`，
    /// 跟已经存在的 `"Two"` 撞成同一个显示值。而括号里那句话恰恰是它和 `"Two"`
    /// 的**全部区别**：都是两个人，一个限定情侣，一个不限。
    ///
    /// 所以换个词，而不是删信息：
    ///
    ///     "Two (only couples)"            → "Couple"
    ///     "Family (parents with children)" → "Family"
    ///
    /// 剥的是显示，不是值：勾选和回传给后端的仍然是原字符串。
    static func displayOccupancy(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "two (only couples)":             return "Couple"
        case "family (parents with children)": return "Family"
        default:                               return display(value)
        }
    }

    /// 按后端 feature key 选显示函数。
    ///
    /// 有了两个按维度定制的显示规则之后，调用点不该各自记住"房型走这个、入住人数
    /// 走那个"——那正是这个文件开头说的"抄一份就会变成两份各自演化的实现"。
    /// key 用**包含**匹配：后端的 key 写法不统一（`type` / `property type` /
    /// `apartment type`），和 `ListingDetailView.secondaryDetails` 里挑主要字段
    /// 用的是同一套判断。
    static func display(_ value: String, forKey key: String) -> String {
        let k = key
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        if k.contains("type")      { return displayType(value) }
        if k.contains("occupancy") { return displayOccupancy(value) }
        return display(value)
    }

    static func displayType(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.firstIndex(of: "(") else {
            return display(trimmed)
        }
        let head = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        // 整个值就是一对括号（理论上不该有）时别剥成空串。
        return display(head.isEmpty ? trimmed : head)
    }
}
