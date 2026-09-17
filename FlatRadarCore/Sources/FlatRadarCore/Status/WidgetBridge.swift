import Foundation
import WidgetKit
import os

/// app 和小组件之间那一个共享容器。
///
/// 只有一条数据流：**app 写，小组件读**，见 ``WidgetSnapshot`` 顶部。
///
/// 为什么是 App Group 里的一个文件，不是 `UserDefaults(suiteName:)`
/// --------------------------------------------------------------
/// 两者都能跨进程，但一个是**一份值**，另一个是一堆键。快照必须整份地换——
/// 匹配数换了而扫描时间还是上一次的，那一格就在说一句从来没成立过的话。
/// 写文件是一次原子替换，天然满足；拆成六个键去写则要自己保证顺序，
/// 而 `cfprefsd` 恰恰不保证另一个进程看到的是哪一刻的组合。
///
/// 顺带还便宜了两件事：登出时删一个文件就是删干净（不用记住清哪六个键），
/// 以及这些数字不会躺在一份 preferences plist 里。
///
/// macOS 上组名必须带 team 前缀
/// --------------------------
/// iOS 写 `group.xxx` 就行，**macOS 不行**——沙盒容器名要求以 team ID 开头，
/// 写成 iOS 那样的话 `containerURL(...)` 直接返回 nil，而且**不报错**：
/// 小组件只是永远显示空。两端各一份常量，由 `tests/test_widget_wiring.py`
/// 钉住它和两份 entitlements、和 pbxproj 里的 `DEVELOPMENT_TEAM` 一致。
public nonisolated enum WidgetBridge {

    #if os(macOS)
    public static let appGroup = "HGXZB3UC25.group.com.j.kong.FlatRadar"
    #else
    public static let appGroup = "group.com.j.kong.FlatRadar"
    #endif

    static let fileName = "WidgetSnapshot.json"

    private static let log = Logger(subsystem: "app.flatradar", category: "widget")

    /// 共享容器。拿不到就是 entitlement 没配对——这是**唯一**会发生的原因，
    /// 所以这里记一条日志而不是静默返回 nil：静默正是上面说的那个"永远显示空"。
    public static var containerURL: URL? {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            log.error("拿不到 App Group 容器 \(appGroup, privacy: .public)——entitlement 少了这一条？")
            return nil
        }
        return url
    }

    static var fileURL: URL? { containerURL?.appendingPathComponent(fileName) }

    // MARK: - 读

    /// 小组件那一侧唯一会调的东西。
    ///
    /// 文件不在、读不出、解不开，一律返回 nil 由调用方画"还没有数据"——
    /// 这三种情况对读者是同一件事（这台机器还没跑过 app，或者刚登出），
    /// 分开处理只会多两条画不出差别的分支。
    public static func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    // MARK: - 写

    /// 落盘，并且**只在有必要时**踢一次时间轴。
    ///
    /// 两种必要：
    /// 1. 数字变了——那一格显示的内容确实要换。
    /// 2. 上一份已经过期了——那一格此刻画的是 `checked 3h ago` 那个形态，
    ///    现在数据回新了，得让它换回 `scanned 4m ago`。只看数字变没变会漏掉
    ///    这一种：app 隔了三小时重新打开、数字碰巧一个没变，那一格就会一直
    ///    停在"过期"的样子上，而它手里的数据其实是刚取的。
    ///
    /// 其余情况只写文件不踢。刷新配额是每天有限的，而「⌘R 按了两下、数字没变」
    /// 是最常见的一种调用。
    public static func publish(_ snapshot: WidgetSnapshot) {
        let previous = read()
        write(snapshot)

        let numbersChanged = previous.map { !$0.sameNumbers(as: snapshot) } ?? true
        let wasStale = previous.map { !$0.isFresh(at: snapshot.capturedAt) } ?? true
        guard numbersChanged || wasStale else { return }
        reloadTimelines()
    }

    /// 登出。
    ///
    /// 匹配数和未读数是**账户数据**（docs/MACOS.md 风险 6：「统一断流、清空所有
    /// 窗口的账户数据」）。窗口里清了而桌面上那一格还挂着上一个账号的数字，
    /// 是同一条判据没做完——而且它比窗口更显眼，登出之后还留在屏幕上。
    public static func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        reloadTimelines()
    }

    private static func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            // `.atomic`：小组件可能正在读。不原子写的话它会读到半个 JSON，
            // 解码失败 → 那一格画成"还没有数据"，一闪一闪的。
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("写小组件快照失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 没装任何小组件时这个调用是空转（系统自己会忽略），不必先查一遍
    /// `getCurrentConfigurations`——那是一次异步 IPC，为了省一次空转不值得。
    private static func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
