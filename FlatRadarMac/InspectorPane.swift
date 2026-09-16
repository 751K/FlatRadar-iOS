import SwiftUI
import AppKit
import FlatRadarCore

/// 右栏：当前焦点那条房源的详情。
///
/// **三屏共用同一个 inspector** ——列表选中一行、地图点一个 pin、日历点一条，
/// 右边出来的都是这个面板。这是 Mac 版最大的一次结构性收益：iOS 上每个模式各自
/// push 一个详情页，因为手机屏放不下第三栏，不是因为那样更好。
///
/// 比较卡去哪了
/// -----------
/// 设计稿 t3 把它移走了，原话：
///
/// > 把 Compare 卡片从右栏移走（钉住的房源已经常驻左侧栏），右栏只做选中项详情
/// > —— 全屏卡片簇从三处减到一处。
///
/// 钉住的两条现在只在**侧栏**的 Pinned 分区，外加表格行首那个墨色菱形。
///
/// 「并排比较」的落点是 **Phase 4 的多窗口**（``ListingWindow``）：把一套房源
/// 双击 / 拖出去，开一个独立窗口，两个窗口真并排。这比塞回右栏的比较卡强在
/// 两边可以各自滚动、各自留在屏上、各自被 Mission Control 管。
/// `BrowseModel.pinned` 仍然是"我在这个窗口里盯着这两套"的标记，两者不冲突。
struct InspectorPane: View {

    let model: BrowseModel

    /// 小地图的取数 + 快照缓存，按 listing id 存。放在 inspector 这一层而不是
    /// `BrowseModel` 里：它是**纯展示缓存**，换排序、换筛选都不该让它失效。
    @State private var thumbnails = MapThumbnailStore()

    /// 「你为什么收到这条」要读用户自己的筛选条件。
    /// 右栏里那些可点的小行，鼠标正停在哪一行上。
    ///
    /// 两处（地图楼盘的单元、日历某天的条目）共用一份：同时只可能悬停一行，
    /// 存 id 比给每行各配一个 `@State` 省事，也不用为此把行拆成独立的视图类型。
    @State private var hoveredRow: String?

    @Environment(AuthStore.self) private var auth

    /// 正在问坐标。按钮变成 `Locating…` 并禁用，免得连点发多次请求。
    @State private var locating = false
    /// 问不到时那句话。
    @State private var mapsFailure: String?

    /// 当天列表展开到全部的那一天。
    ///
    /// 存**哪一天**而不是一个 Bool：换一天时展开状态必须自动收回去，
    /// 存 Bool 就得再挂一个 `onChange` 去重置，而那种"两处状态要手动同步"
    /// 正是容易漏的地方。存日期的话，`expandedDay == day` 天然只对那一天成立。
    @State private var expandedDay: CalendarDay?

    /// 当天列表默认最多列几条。
    ///
    /// 不设上限的话，7 号那种一天 34 条的日子会把右栏撑到 1500pt，
    /// 下面"选中那条的详情"被埋得要滚很久——而右栏下半段才是这个面板的重点。
    /// 12 条约等于一屏，和格子里"+31 more"的收法是同一个语言。
    private let defaultDayRowLimit = 12

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let building = model.mapBuilding {
                    buildingUnits(building)
                    Divider().padding(.vertical, 14)
                }
                if let day = model.calendarDay {
                    calendarDay(day)
                    Divider().padding(.vertical, 14)
                }
                if let alert = model.focusedAlertRow {
                    alertDetail(alert)
                    Divider().padding(.vertical, 14)
                }
                // Stats 屏选中的那张图 —— **它是右栏的全部内容**，下面不再接
                // 房源详情。
                //
                // 和上面三块不一样：地图选中一栋楼、日历选中一天、通知选中一条，
                // 那三者底下接一条**具体房源**是自然的（点楼里的某一套、点那天的
                // 某一条）。一张统计图底下接一条跟它毫无关系的房源，只是"右栏
                // 恰好还留着上次选中的东西"。
                if let chart = model.statsChart {
                    chartBreakdown(chart)
                } else {
                    body(for: model.focused)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func body(for id: Listing.ID?) -> some View {
        if let l = model.listing(id) {
            detail(l)
        } else if let unit = model.mapBuilding?.units.first(where: { $0.id == id }) {
            // 地图上选中的这一套不在已加载的房源里——`/map` 和 `/listings` 覆盖的
            // 集合不完全一样（前者是坐标缓存 + 新鲜度窗口，后者是账号的筛选结果）。
            // 不假装没有：把地图那份有的字段照实显示，并说明为什么少了几行。
            partialDetail(unit)
        } else if let unit = calendarUnit(id) {
            // 同 `partialDetail(_:)`：`/calendar` 和 `/listings` 覆盖的集合不一样，
            // 日历里点到的这条不一定在已加载的房源里。
            partialDetail(unit)
        } else if model.mapBuilding == nil, model.calendarDay == nil {
            empty
        }
    }

    // MARK: - Stats 选中的那张图

    /// 完整明细：标签 / 数量 / 占比，外加一条按比例的底纹。
    ///
    /// 这是 Mac 取代 iOS 那个「点开看大图」sheet 的东西。卡里只画得下形状
    /// （城市那张还只画前 8 条），精确的数字在这儿。**左边看形状、右边看数字**
    /// ——这也是"多屏共用 inspector"这个结构第四次派上用场。
    ///
    /// 顺序**照抄卡里的顺序**，不在这儿重排：有序维度重排就毁了（见
    /// ``ChartPresentation``），而两边顺序不一致的话，用户在卡上认的第三根柱子
    /// 到这儿会对不上第三行。
    private func chartBreakdown(_ chart: StatsSelection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chart.title)
                    .font(.title2.weight(.semibold))
                    .tracking(-0.25)
                // 时序图说「31 天」，分布图说「20 类」。对着一列日期写
                // "31 categories" 是把实现词漏给了用户。
                Text("\(chart.entries.count) \(ChartPresentation.axis(for: chart.key) == .time ? "days" : "categories") · \(chart.total) listings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            VStack(spacing: 0) {
                ForEach(chart.entries) { entry in
                    breakdownRow(entry, chart: chart)
                }
            }
            .padding(.top, 2)
        }
    }

    private func breakdownRow(_ entry: ChartEntry, chart: StatsSelection) -> some View {
        let share = chart.total > 0 ? Double(entry.count) / Double(chart.total) : 0
        let tint = ChartPresentation.color(forKey: chart.key, label: entry.label) ?? Theme.chart
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(ChartPresentation.shortLabel(entry.label, forKey: chart.key))
                .font(.body)
                .lineLimit(1)
                // 从**头**截，理由同 `unitRow(_:)`：城市名前缀常常一样
                // （`Amsterdam Naritaweg` / `Amsterdam Diemen`），从尾截会把
                // 唯一能区分它们的那一段切掉。
                .truncationMode(.head)
            Spacer(minLength: 6)
            Text("\(entry.count)")
                .font(.body.monospacedDigit())
            Text(share.formatted(.percent.precision(.fractionLength(0))))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(alignment: .leading) {
            // 一条按比例的底纹。比另起一列条形图省地方，而且它就在数字底下，
            // 不用视线来回跳。
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(0.14))
                    .frame(width: max(2, geo.size.width * share))
            }
        }
    }

    // MARK: - 日历选中的那一天

    /// 日历点中一天时，列出当天起租的房源。
    ///
    /// 和 ``buildingUnits(_:)`` 是同一个位置、同一个角色：右栏上半段回答
    /// "你刚点的是什么"，下半段才是选中那一条的详情。
    ///
    /// 设计稿里这一段还有两个控件没做，都是数据不支持：
    /// - **Add to Calendar.app**：要 EventKit + 权限 + entitlement，是另一件事。
    /// - **Filter list to this day**：`/listings` 的查询参数里**没有任何日期
    ///   字段**（status/source/city/q/types/occupancies/contract/energy +
    ///   limit/offset/sort）。只能在客户端筛已加载的那 80 条——那正是
    ///   `1b365c9`「排序改走服务端」修掉的那类 bug，不能再造一个。
    ///
    /// 设计稿那张 "Why the 1st is crowded" 解释卡也**没有做**，理由不同：
    /// 它说的话在这份数据里是**错的**。实测 691 条里 7 号 130 条（18.8%）、
    /// 1 号 90 条（13.0%）——最扎堆的是 7 号不是 1 号。宁可不解释，
    /// 也不能在界面上讲一句自信的假话。
    private func calendarDay(_ day: CalendarDay) -> some View {
        let dayRowLimit = expandedDay == day ? day.count : defaultDayRowLimit
        return VStack(alignment: .leading, spacing: 6) {
            Text("Selected day")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Self.longDate.string(from: day.date))
                .font(.title2.weight(.semibold))
                .tracking(-0.25)
            Text(daySummary(day))
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(day.items.prefix(dayRowLimit), id: \.id) { item in
                    calendarRow(item)
                }
                if day.count > dayRowLimit {
                    Button("Show all \(day.count)") { expandedDay = day }
                        .buttonStyle(.link)
                        .font(.body)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
            // 设计稿的脚注，照留——这句话是真的，而且重要：起租日来自各平台，
            // 平台改了不会通知我们。
            Text("Dates come from the platforms and can shift without notice")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    /// "6 listings · 2 bookable"。
    ///
    /// 一定要把可订数单独说出来：实测 88% 的条目是 Occupied（起租日是未来的
    /// 退租日），只报总数会被读成"这天有 6 套能抢"。
    private func daySummary(_ day: CalendarDay) -> String {
        let n = day.count
        let bookable = day.items.filter {
            let k = ListingStatus.from($0.status)
            return k == .book || k == .lottery
        }.count
        let head = "\(n) listing\(n == 1 ? "" : "s")"
        return bookable == 0 ? "\(head) · none bookable yet"
                             : "\(head) · \(bookable) bookable"
    }

    private func calendarRow(_ item: CalendarListing) -> some View {
        let selected = model.focused == item.id
        return Button {
            model.focused = item.id
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(Theme.statusColor(ListingStatus.from(item.status)))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(1)
                        // 从头截，理由同 ``unitRow(_:)``：同楼的单元名前缀一样。
                        .truncationMode(.head)
                    if !item.city.isEmpty {
                        Text(item.building.isEmpty ? item.city : "\(item.city) · \(item.building)")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text(PriceText.compact(item.priceRaw) ?? "—")
                    .font(.body.weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            // 选中 / 悬停走全 App **同一份配方**（见 ``RowSurface``）：选中是染色的
            // 液态玻璃，把那一行从背景里抬起来；悬停是白底 + 投影。
            //
            // 原来这里是自己 `fill` 一层 `Theme.selectionFill`。那是块实心浅灰
            // （0xE7E7EA），压在 inspector 的玻璃底上几乎看不出选中——和日历格子
            // 遇到的是同一个毛病（见 `CalendarPane.cellBackground` 的注释）。
            // `RowSurface` 的文件头早就写了"两处各写一份迟早会漂移"，这就是那个"迟早"。
            .modifier(RowSurface(isSelected: selected, isHovered: hoveredRow == item.id))
            .contentShape(Rectangle())
            .onHover { hoveredRow = $0 ? item.id : (hoveredRow == item.id ? nil : hoveredRow) }
        }
        .buttonStyle(.plain)
    }

    /// 日历里点中的这条在不在已加载的房源里；不在就走 ``partialDetail(_:)``。
    private func calendarUnit(_ id: Listing.ID?) -> CalendarListing? {
        guard let id else { return nil }
        return model.calendarDay?.items.first { $0.id == id }
    }

    /// 只有 `/calendar` 那份字段时的详情。比 ``partialDetail(_:)`` 还少一个
    /// Area——`/calendar` 连面积都不回（实测 9 个键：id/name/status/source/
    /// price_raw/available_from/url/city/building）。缺的行明说缺。
    private func partialDetail(_ unit: CalendarListing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(unit.name)
                .font(.title2.weight(.semibold))
                .tracking(-0.25)
            HStack(spacing: 7) {
                StatusPill(status: unit.status)
                PlatformBadge(source: unit.source)
                Spacer(minLength: 0)
            }
            .padding(.top, 11)
            VStack(spacing: 0) {
                LabeledRow("Price", PriceText.compact(unit.priceRaw) ?? unit.priceRaw, mono: true)
                LabeledRow("City", unit.city)
                LabeledRow("Building", unit.building.isEmpty ? nil : unit.building)
                LabeledRow("Platform", Platform.displayName(unit.source))
                LabeledRow("Available", ServerTime.displayDate(unit.availableFrom))
            }
            .padding(.top, 20)
            Text("Full details load with the listings tab.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
            HStack(spacing: 7) {
                ListingActionButton(title: "Open on \(Platform.displayName(unit.source))", prominent: true) {
                    if let url = URL(string: unit.url) { NSWorkspace.shared.open(url) }
                }
                openInMapsButton(.needsLookup(id: unit.id, name: unit.name))
                Spacer(minLength: 0)
            }
            .padding(.top, 18)
            mapsFailureNote
        }
    }

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    // MARK: - 通知详情

    /// 右栏上半段：这条通知说了什么 + **你为什么会收到它**。
    ///
    /// `Why you got this` 是设计稿里最有价值的一块，也是唯一能落地的那半——
    /// 设计稿写的是「Rule · Rotterdam, A+ or better」，暗示有多条具名规则；
    /// 后端只有 `/me/filter` 一份 ``ListingFilter``。所以标题不写 "Rule"，
    /// 而是直接把**你的筛选条件**摊成 chip。少一层不存在的抽象，信息一样全。
    ///
    /// 访客态没有筛选器（也收不到通知），这一段自然就不显示。
    private func alertDetail(_ row: AlertRow) -> some View {
        // 下半段会不会把这套房再说一遍。
        //
        // 会的话，上半段只留**这条通知独有**的信息：说了什么、什么时候、为什么给你。
        // 房源的身份（名字、平台、当前状态）归下半段，上半段不再重复一遍——原来两段
        // 各画一次标题、一次平台徽章、一次状态胶囊，右栏上下两截看着像同一块内容贴了
        // 两遍。
        //
        // 状态那两个胶囊尤其坑：上面那个是**通知发生时**的状态，下面那个是**现在**的，
        // 值经常不一样（截图里上面 Book、下面 Occupied），但长得一模一样、挨着摆，
        // 读起来只会觉得是重复而不是"它变了"。现在上面不画胶囊，因为 `row.summary`
        // 本来就把这件事写成了话（`New listing · Available to book` /
        // `Reserved → Book`），下面那个胶囊就唯一地表示"现在"。
        let listingBelow = model.listing(row.listingID) != nil
        return VStack(alignment: .leading, spacing: 0) {
            // 下半段接管标题时，这一行升成这一段的标题——它才是"这条通知说了什么"。
            Text(row.summary)
                .font(listingBelow ? .title3.weight(.semibold) : .subheadline)
                .foregroundStyle(listingBelow ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

            // 房源不在已加载的那批里时下半段什么都不画，身份只能由这里给。
            if !listingBelow {
                Text(row.title)
                    .font(.title2.weight(.semibold))
                    .tracking(-0.25)
                    .padding(.top, 2)
                HStack(spacing: 7) {
                    if let to = row.to { StatusPill(status: to) }
                    if let from = row.from, from != row.to {
                        Text("was \(Theme.shortStatusLabel(ListingStatus.from(from)) ?? from)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let source = row.source { PlatformBadge(source: source) }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
            }

            if let when = row.date {
                Text("Notified at \(Self.longDateTime.string(from: when))")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }

            whyYouGotThis.padding(.top, 14)
        }
    }

    @ViewBuilder
    private var whyYouGotThis: some View {
        let chips = filterChips
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("Why you got this")
                    .font(.subheadline.weight(.semibold))
                Text("It matched your saved filter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // 换行排布：条件多的时候一行放不下，`Layout` 太重，
                // 用 chunk 成每行两个的 VStack——右栏只有 300pt 宽，两个正好。
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(stride(from: 0, to: chips.count, by: 2)), id: \.self) { i in
                        HStack(spacing: 5) {
                            ForEach(chips[i..<min(i + 2, chips.count)], id: \.self) { chip($0) }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: Capsule())
    }

    /// 把 ``ListingFilter`` 里**设了值**的那些条件变成 chip。
    ///
    /// 没设的条件不显示——设计稿有一个 `Any price` 的 chip，那是在说"这一项
    /// 没限制"。摊开看的话，没限制的项列出来只会把真正生效的条件淹掉。
    private var filterChips: [String] {
        guard let f = auth.userInfo?.listingFilter else { return [] }
        var out: [String] = []
        if let r = f.maxRent { out.append("≤ €\(Int(r))") }
        if let a = f.minArea { out.append("≥ \(Int(a)) m²") }
        // `minFloor` 为 0 等于**没有限制**，不是"至少 0 层"。列出来会让人以为
        // 自己设了一条根本不存在的条件。同理 maxRent / minArea 上面已经是可选。
        if let fl = f.minFloor, fl > 0 { out.append("Floor ≥ \(fl)") }
        if !f.allowedEnergy.isEmpty { out.append("\(f.allowedEnergy) or better") }
        out.append(contentsOf: f.allowedCities.prefix(3))
        // 房型在后端存的是裸数字（`"1"` / `"2"`），直接显示就是两个孤零零的
        // 数字，读不出是房型还是别的什么。走 ``RoomType/display(_:)``，
        // 和表格里的 Type 列同一个写法。
        out.append(contentsOf: f.allowedTypes.prefix(2).compactMap { RoomType.display($0) })
        out.append(contentsOf: f.allowedSources.prefix(2).map { Platform.displayName($0) })
        return out
    }

    private static let longDateTime: DateFormatter = {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM 'at' HH:mm"
        return f
    }()

    // MARK: - 这栋楼里的单元

    /// 地图选中一栋楼时列出楼里的所有单元。
    ///
    /// 这是地图那一屏存在的理由：标记聚合到楼盘之后，「这栋楼里有哪几套、
    /// 差在哪」就得有个地方看。放右栏而不是地图上的浮卡——浮卡会盖住地图，
    /// 而右栏本来就是"当前选中项"的地盘。
    private func buildingUnits(_ b: MapBuilding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(b.name)
                    .font(.title2.weight(.semibold))
                    .tracking(-0.25)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text("\(b.count)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(b.city)
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(b.units, id: \.id) { unit in
                    unitRow(unit)
                }
            }
            .padding(.top, 6)
        }
    }

    private func unitRow(_ unit: MapListing) -> some View {
        let selected = model.focused == unit.id
        return Button {
            model.focused = unit.id
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(Theme.statusColor(unit.statusKind))
                    .frame(width: 6, height: 6)
                Text(unit.name)
                    .font(.body)
                    .lineLimit(1)
                    // 从**头**截，不是从尾。一栋楼里的单元名前缀全一样
                    // （`Kon. Wilhelminaplein 29 F6` / `… 29 H23`），从尾截会把
                    // 唯一能区分它们的那一段切掉，整列变成一模一样的
                    // "Kon. Wilhelminaplein…"——而这一列存在的意义就是区分它们。
                    .truncationMode(.head)
                Spacer(minLength: 6)
                Text(PriceText.compact(unit.priceRaw) ?? unit.priceRaw)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            // 同上：走 ``RowSurface``，不自己画一层灰底。
            .modifier(RowSurface(isSelected: selected, isHovered: hoveredRow == unit.id))
            .contentShape(Rectangle())
            .onHover { hoveredRow = $0 ? unit.id : (hoveredRow == unit.id ? nil : hoveredRow) }
        }
        .buttonStyle(.plain)
    }

    /// 只有 `/map` 那份字段时的详情。缺的行**明说缺**，不留空白让人以为没数据。
    private func partialDetail(_ unit: MapListing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(unit.name)
                .font(.title2.weight(.semibold))
                .tracking(-0.25)
            HStack(spacing: 7) {
                StatusPill(status: unit.status)
                PlatformBadge(source: unit.source)
                Spacer(minLength: 0)
            }
            .padding(.top, 11)
            VStack(spacing: 0) {
                LabeledRow("Price", PriceText.compact(unit.priceRaw) ?? unit.priceRaw, mono: true)
                LabeledRow("Area", AreaText.normalized(unit.area), mono: true)
                LabeledRow("City", unit.city)
                LabeledRow("Platform", Platform.displayName(unit.source))
                LabeledRow("Available", unit.availableFrom.isEmpty ? nil
                                                                  : ServerTime.displayDate(unit.availableFrom))
            }
            .padding(.top, 20)
            Text("Full details load with the listings tab.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
            HStack(spacing: 7) {
                ListingActionButton(title: "Open on \(Platform.displayName(unit.source))", prominent: true) {
                    if let url = URL(string: unit.url) { NSWorkspace.shared.open(url) }
                }
                openInMapsButton(.mapListing(unit))
                Spacer(minLength: 0)
            }
            .padding(.top, 18)
            mapsFailureNote
        }
    }

    private var empty: some View {
        ContentUnavailableView("No Selection",
                               systemImage: "sidebar.right",
                               description: Text("Pick a listing on the left, or use ↑↓."))
            .frame(maxWidth: .infinity, minHeight: 260)
    }

    // MARK: - 详情

    @ViewBuilder
    private func detail(_ l: Listing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 这四段在 ``ListingFacts`` 里，和独立详情窗口 ``ListingWindow`` 共用
            // 同一份——两处显示的是同一套事实，不该有两个写法。
            ListingHeading(listing: l)
            ListingBadgeRow(listing: l).padding(.top, 11)
            ListingFactsTable(listing: l).padding(.top, 20)
            comparison(l).padding(.top, 16)
            // 地图屏不画小地图：左边整屏就是地图，右栏再来一张是**同一件事说两遍**，
            // 而且两张地图的视野还不一样（大图跟着用户平移缩放，小图钉死在 6km），
            // 同屏并置只会让人怀疑哪张是对的。
            //
            // 判据用 `section` 而不是 `mapBuilding != nil`：站在地图屏但还没点
            // 任何一个 pin 时 `mapBuilding` 是 nil，而右栏此时仍会显示列表那边
            // 选中的那条 —— 那种情况下小地图照样是多余的。
            //
            // 用 `if` 而不是 `.opacity(0)` / `.hidden()`：不构造这个视图，
            // ``MapThumbnail`` 的 `/map/locate` 请求就根本不会发出去。
            if model.section != .map {
                MapThumbnail(listing: l, store: thumbnails).padding(.top, 12)
            }
            actions(l).padding(.top, 18)
            ListingProvenance(listing: l).padding(.top, 14)
        }
    }

    // MARK: - 同类比价

    /// 「比同城同房型的中位数贵 8%」。
    ///
    /// **全部本地算**，不需要后端：Mac 端 `ListingsStore(pageSize: 500)` +
    /// `loadAllPages()` 已经把全量拉进内存，所以这里的中位数覆盖的是全集，
    /// 不是「已加载的那一页」——那正是 iOS 端排序 bug 的成因。
    ///
    /// 样本不足 5 条就不显示：3 条房源的「中位数」不是个能拿来做决定的数。
    @ViewBuilder
    private func comparison(_ l: Listing) -> some View {
        if let peer = peerComparison(l) {
            VStack(alignment: .leading, spacing: 4) {
                Text(peer.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(peer.deltaText)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                    Text("median \(peer.medianText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private struct PeerComparison {
        var caption: String
        var deltaText: String
        var medianText: String
    }

    private func peerComparison(_ l: Listing) -> PeerComparison? {
        guard let price = l.priceValue, price > 0, !l.city.isEmpty else { return nil }
        guard let type = l.typeText else { return nil }

        // 同城 + 同房型算一组。面积不进判据：面积是文本派生的，档位切得太细
        // 会让样本瞬间掉到个位数。
        let peers = model.listings.listings.filter {
            $0.id != l.id && $0.city == l.city && $0.typeText == type
        }.compactMap(\.priceValue).filter { $0 > 0 }.sorted()

        guard peers.count >= 5 else { return nil }
        let median = peers[peers.count / 2]
        guard median > 0 else { return nil }

        let pct = Int(((price - median) / median * 100).rounded())
        return PeerComparison(
            caption: "Price vs. \(RoomType.display(type)?.lowercased() ?? type) "
                   + "in \(l.city) (\(peers.count) listings)",
            deltaText: pct > 0 ? "+\(pct)%" : (pct == 0 ? "at median" : "\(pct)%"),
            medianText: "€\(Int(median.rounded()))")
    }

    // MARK: - 动作

    /// 三个按钮**会换行**（设计稿是 `flex-wrap: wrap`）。
    /// 不换行的话，"Open on Student Experience" 这种长平台名会在 300pt 的右栏里
    /// 把自己压成 "Open on Studen…"，而主操作的按钮文字被截断是最不该发生的。
    private func actions(_ l: Listing) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            WrappingRow {
                ListingActionButton(title: "Open on \(Platform.displayName(l.source))",
                                    prominent: true) {
                    open(l)
                }
                ListingActionButton(title: model.pinned.contains(l.id) ? "Unpin" : "Pin") {
                    model.togglePin(l.id)
                }
                ListingActionButton(title: "Copy Link") { copy(l) }
                // Share 和 Copy Link 是两件事，都留着：复制链接是"我自己待会儿用"，
                // 分享是"发给别人"，后者还带着摘要正文（见 ``ListingShare``）。
                ListingShareButton(listing: l)
                openInMapsButton(.needsLookup(id: l.id, name: l.name))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            mapsFailureNote
        }
    }

    /// 「在地图 app 里打开」——交给系统地图**导航**过去。
    ///
    /// 四屏都有：不管你是从列表、日历还是通知点到这套房，"怎么过去"都是同一个
    /// 问题。地图屏也保留——那张图回答的是"在城市哪一块"，不是路线。
    ///
    /// 坐标可能要现问一次（`/listings` 不回坐标），所以按下之后可能有一小段
    /// 等待；问不到就**明说问不到**，不能静悄悄什么都不发生。
    @ViewBuilder
    private func openInMapsButton(_ source: OpenInMaps.Source) -> some View {
        ListingActionButton(title: locating ? "Locating…" : "Open in Maps") {
            locating = true
            Task {
                let ok = await OpenInMaps.open(source, thumbnails: thumbnails)
                locating = false
                if !ok {
                    // 和小地图那处同一个口径：没坐标是"还没地理编码"，
                    // 不是"这套房不存在"。
                    mapsFailure = "No coordinates for this listing yet — its address "
                                + "has not been geocoded, so Maps cannot route to it."
                }
            }
        }
        .disabled(locating)
    }

    @ViewBuilder
    private var mapsFailureNote: some View {
        if let note = mapsFailure {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private func open(_ l: Listing) {
        guard let url = URL(string: l.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copy(_ l: Listing) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(l.url, forType: .string)
    }
}
