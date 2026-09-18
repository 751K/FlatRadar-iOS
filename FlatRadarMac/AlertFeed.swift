import Foundation
import FlatRadarCore

/// 通知屏的纯数据层：把 `/notifications` 那串条目拆成一行一行、按天分组、按
/// 2 小时分桶。不碰 SwiftUI，单独一个文件是为了能测。
///
/// 为什么要**解析 body**
/// -------------------
/// 设计稿每行右边有一对状态胶囊（`Reserved → ● Book`）和一个价格。后端并没有
/// 单独的字段给它们，但也不用猜——`notifier.py` 拼 body 的格式是固定的：
///
/// ```python
/// type="status_change"  body = f"{old_status} → {new_status} · {price}/mo"
/// type="new_listing"    body = f"{listing.status} · {price}/mo · → {move_in}"
/// ```
///
/// 两种 body 里都有 `→`，含义却不同（一个是状态迁移，一个是入住日的箭头），
/// 所以**按 `type` 分派**，绝不靠在 body 里找箭头来猜——那正是
/// ``NotificationItem/classifyKind(type:title:body:)`` 里那个 `blob.contains("→")`
/// 兜底分支容易踩的坑，用在这里会把新房源读成状态变化。

// MARK: - 一行

struct AlertRow: Identifiable, Hashable {

    let id: Int
    let date: Date?
    let isRead: Bool
    let kind: NotificationItem.Kind
    /// 平台 key。从标题的 `[H2S]` 前缀反查出来的，查不到就是 nil。
    let source: String?
    /// 去掉 `[H2S]` 前缀的房源名。
    let title: String
    /// 变化本身的一句话，如 `New listing` / `Reserved → Book`。
    let summary: String
    /// 旧状态 → 新状态。`from` 为 nil 表示这是新上架，不是迁移。
    let from: String?
    let to: String?
    let price: String?
    let listingID: String
    let url: String

    var time: String { date.map { AlertFeed.timeFormatter.string(from: $0) } ?? "" }
}

// MARK: - 一天

struct AlertDay: Identifiable, Hashable {
    let id: Date              // 当天 00:00（服务端时区）
    let label: String         // Today / Yesterday / Monday 8 September
    let rows: [AlertRow]
    var unread: Int { rows.filter { !$0.isRead }.count }
}

// MARK: - 组装

enum AlertFeed {

    /// 日期一律走 ``ServerTime/calendar``，不用 `Calendar.current`——
    /// 理由见 `CalendarMonth.swift` 顶部那段（build 295→307 的时区事故）。
    static let calendar = ServerTime.calendar

    // MARK: 拆一行

    static func row(_ n: NotificationItem, platforms: [String]) -> AlertRow {
        let (from, to, price) = parse(n)
        return AlertRow(
            id: n.id,
            date: n.createdDate,
            isRead: n.isRead,
            kind: n.kind,
            source: source(from: n.title, known: platforms),
            title: n.listingTitleHint,
            summary: summary(n, from: from, to: to),
            from: from,
            to: to,
            price: price,
            listingID: n.listingID,
            url: n.url)
    }

    /// 从 body 里取出「旧状态 / 新状态 / 价格」。**按 `type` 分派**，见类型注释。
    static func parse(_ n: NotificationItem) -> (from: String?, to: String?, price: String?) {
        let body = n.body
        let price = self.price(in: body)

        switch n.type {
        case "status_change":
            // `"{old} → {new} · {price}/mo"`
            guard let arrow = body.range(of: "→") else { return (nil, nil, price) }
            let old = body[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            // 新状态到第一个 `·` 为止；没有 `·` 就吃到结尾。
            let rest = body[arrow.upperBound...]
            let new = rest.split(separator: "·", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return (old.isEmpty ? nil : old, new.isEmpty ? nil : new, price)

        case "new_listing", "booking":
            // `"{status} · {price}/mo · → {move_in}"`——这里的 `→` 是入住日，
            // **不是**状态迁移，所以只取第一段当当前状态，没有 from。
            let status = body.split(separator: "·", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return (nil, status.isEmpty ? nil : status, price)

        default:
            // heartbeat / error / announcement / channel_disabled：没有房源状态。
            return (nil, nil, price)
        }
    }

    /// `"… · €1.245/mo …"` → `"€1245"`。走 ``PriceText``，和列表、日历同一份口径。
    static func price(in body: String) -> String? {
        guard let mo = body.range(of: "/mo") else { return nil }
        // 往前找到这一段的起点（上一个 `·` 或开头）。
        let head = body[..<mo.lowerBound]
        let chunk = head.split(separator: "·").last.map(String.init) ?? String(head)
        return PriceText.compact(chunk)
    }

    /// 每行第二排那句话。
    static func summary(_ n: NotificationItem, from: String?, to: String?) -> String {
        if let from, let to {
            // 同状态重复通知时后端也会发（例如抽签提醒），说「still X」比
            // 「X → X」清楚。设计稿里就有 `still ● Lottery` 这一行。
            return from == to ? "Still \(to)" : "\(from) → \(to)"
        }
        if let to { return String(localized: "New listing · \(to)") }
        switch n.type {
        case "heartbeat":    return String(localized: "Scraper heartbeat")
        case "error":        return String(localized: "Scraper error")
        case "announcement": return String(localized: "Announcement")
        default:             return n.body
        }
    }

    /// 从 `"[H2S] Blaak 555"` 里反查平台 key。
    ///
    /// 比对的是 ``Platform/shortName(_:)``——缩写是包里那一份唯一映射生成的，
    /// 所以这里不用再维护第二张表。认不出就返回 nil，**不套一个默认平台**：
    /// 把未知来源显示成 Holland2Stay 会让人以为数据是那边来的。
    static func source(from title: String, known: [String]) -> String? {
        guard title.hasPrefix("["), let close = title.firstIndex(of: "]") else { return nil }
        let code = String(title[title.index(after: title.startIndex)..<close])
        return known.first { Platform.shortName($0).caseInsensitiveCompare(code) == .orderedSame }
    }

    // MARK: 按天分组

    static func days(_ rows: [AlertRow], now: Date = Date()) -> [AlertDay] {
        let grouped = Dictionary(grouping: rows.filter { $0.date != nil }) {
            calendar.startOfDay(for: $0.date!)
        }
        return grouped
            .map { day, rows in
                AlertDay(id: day,
                         label: label(for: day, now: now),
                         // 组内按时间倒序：最新的在最上面。
                         rows: rows.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
            }
            .sorted { $0.id > $1.id }
    }

    static func label(for day: Date, now: Date) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return String(localized: "Yesterday")
        }
        return dayFormatter.string(from: day)
    }

    // MARK: 24 小时柱状图

    /// 最近 24 小时按 **2 小时**一桶，共 12 桶，**旧 → 新**。
    ///
    /// 桶边界对齐到偶数小时而不是"从现在往前推 2 小时"：后者会让柱子随时间
    /// 平移，同一份数据每分钟看都不一样，读不出"哪个时段忙"。
    static func buckets(_ rows: [AlertRow], now: Date = Date()) -> [Int] {
        let hour = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        guard let currentHour = calendar.date(from: hour) else { return [] }
        let alignedHour = calendar.component(.hour, from: currentHour) / 2 * 2
        guard let end = calendar.date(bySettingHour: alignedHour, minute: 0, second: 0,
                                      of: currentHour, matchingPolicy: .nextTime),
              let start = calendar.date(byAdding: .hour, value: -22, to: end)
        else { return [] }

        var counts = [Int](repeating: 0, count: 12)
        for row in rows {
            guard let d = row.date, d >= start else { continue }
            let hours = Int(d.timeIntervalSince(start) / 3600)
            let index = min(11, max(0, hours / 2))
            counts[index] += 1
        }
        return counts
    }

    /// 「今天」和「最近 7 天」两个数。
    static func totals(_ rows: [AlertRow], now: Date = Date()) -> (today: Int, week: Int) {
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        return (rows.filter { ($0.date ?? .distantPast) >= today }.count,
                rows.filter { ($0.date ?? .distantPast) >= weekAgo }.count)
    }

    // MARK: 格式化

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()
}
