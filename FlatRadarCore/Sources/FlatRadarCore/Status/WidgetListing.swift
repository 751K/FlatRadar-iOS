import Foundation

/// NEWEST 那三行里的一条。
///
/// 设计稿（`FlatRadar Widgets.dc.html` 4a/4b）中号和大号都有这一段：
/// 菱形 + 标题 + 城市/平台 + 价格 + 年龄。**这是小组件里唯一的房源内容**——
/// docs/NEXT.md 原来那一行写的是「不做房源列表」，设计稿把它推翻了，
/// 而推翻得有道理：三条不是列表，是"最近发生了什么"的证据。一个只有数字的
/// 小组件回答不了「那 31 条是些什么」，而那恰恰是看到 31 之后的下一个问题。
///
/// 只存**画得出来**的字段，不存整个 `Listing`：那玩意有 features / featureMap /
/// 坐标，几百字节一条，而这里一条只要五个短串。共享容器里那份 JSON 每次刷新
/// 都要整份重写，没必要把用不上的东西搬过去。
public nonisolated struct WidgetListing: Codable, Sendable, Equatable, Identifiable {

    public let id: String
    /// 房源名。设计稿里是 `Kastanjelaan 400 · Apt 305`，就是后端给的 `name`。
    public let name: String
    public let city: String
    /// 平台全名（`Holland2Stay`）。中号那一行放不下，只有大号显示。
    public let platform: String
    /// 价格**原样用后端给的串**（`€1,142`）。不自己格式化：各平台的写法不一样，
    /// 重新拼一遍就是又一处会漂的地方，而 `PriceText` 那套规则已经在包里了。
    public let price: String
    /// 首次出现的时间戳，原样存。年龄在渲染时按条目时刻算。
    public let firstSeen: String

    public init(id: String, name: String, city: String,
                platform: String, price: String, firstSeen: String) {
        self.id = id
        self.name = name
        self.city = city
        self.platform = platform
        self.price = price
        self.firstSeen = firstSeen
    }

    /// `2m` / `5h` / `2d`。和通知行尾那一小格是同一个函数
    /// （``ServerTime/compactAge(_:now:)``）。
    public func ageText(at now: Date) -> String {
        ServerTime.compactAge(firstSeen, now: now)
    }

    /// 中号那一行的副标题：只有城市。
    public var shortSubtitle: String { city }

    /// 大号那一行的副标题：`Eindhoven · Holland2Stay`。
    ///
    /// 缺一半时不留那个间隔符——`Eindhoven · ` 后面空着比没有间隔符更像出错。
    public var longSubtitle: String {
        [city, platform].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
