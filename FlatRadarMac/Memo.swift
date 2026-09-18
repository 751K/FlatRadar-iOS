import Foundation

/// 按输入缓存一个派生值：输入没变，就直接还上一次算出来的结果。
///
/// 为什么需要它
/// -----------
/// Mac 这几屏的派生数据原先全是**计算属性**：地图的楼盘分组、日历的月网格、
/// 列表的 `rows`、通知的 `allRows`。一次界面更新里它们会被读好几遍（空状态判断、
/// 标记、计数、状态栏各读一次），而悬停、相机移动这类和数据毫无关系的状态变化
/// 也会触发更新——每读一次就把两千条重新分组 / 排序 / 解析一遍（代码审查实测：
/// 地图 34ms、日历 68ms + 77ms、列表 24–47ms、通知五个计数 46ms）。
///
/// 键用**数据本身**（房源数组、筛选条件……），不另设"版本号"：
/// - Swift 的 `Array ==` 先比存储地址，同一块存储直接判相等——数据没变时这一步
///   几乎是免费的；
/// - 数据换了一批，才逐条比一次，比重算便宜得多；
/// - 不依赖"每个改数据的地方都记得把版本号加一"，漏一处就是显示旧数据。
///
/// 读键的时候会顺带读到被观察的属性（`store.listings`、`query`…），所以 SwiftUI
/// 的依赖追踪照常成立：数据一变，读它的视图照样刷新，只是刷新时不再重算没变的部分。
///
/// 是 class、不参与观察：它只是一块记忆，写它不该触发任何界面更新。
@MainActor
final class Memo<Key: Equatable, Value> {

    private var cached: (key: Key, value: Value)?

    /// 真正算了几次。测试用它证明"读了很多遍，只算了一次"。
    private(set) var computeCount = 0

    init() {}

    func value(for key: Key, _ compute: () -> Value) -> Value {
        if let cached, cached.key == key { return cached.value }
        let value = compute()
        computeCount += 1
        cached = (key, value)
        return value
    }
}
