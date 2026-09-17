import SwiftUI
import FlatRadarCore

/// 主窗口左栏：主导航 + 固定比较项，底部是设置入口和一条实时状态。
///
/// 这是 Mac 版取代 iOS tab bar 的位置，见 ``SidebarSection`` 顶部注释。
///
/// 视觉上按设计稿 t2「去线留白」走：侧栏和 inspector 用**一档灰**、内容区纯白，
/// 三栏之间**不画 1px 描边**——边界靠明度差，不靠线。
struct SidebarView: View {

    @Bindable var model: BrowseModel
    let summary: SummaryModel

    @State private var settingsHovered = false

    var body: some View {
        List(selection: $model.section) {
            ForEach(SidebarSection.allCases) { section in
                navRow(section).tag(section)
            }
            pinned
        }
        .listStyle(.sidebar)
        // 选中态用中性填充，不是实心强调色 —— 窗口的 tint 是 ink（近黑），
        // 直接拿它填一整行会变成黑底白字，比内容还抢眼。
        .tint(Theme.selectionFill)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                settingsRow
                liveFooter
            }
        }
    }

    // MARK: - 设置入口

    /// 设置的**第二个**入口。
    ///
    /// 第一个是应用菜单里的「Settings…」（⌘,），那是 Mac 上设置的规范位置，不动它。
    /// 这一条是给不翻菜单的人的：侧栏本来只放「看数据」的几屏，但设置是唯一一个
    /// 用户会主动去找、却在这一栏里找不到的东西。
    ///
    /// **不做成第五个导航项。** 那四项点了换内容区，这一条点了开一扇新窗口。
    /// 摆进同一个 `List` 会跟着带上选中态——一行亮着、内容区却没变，而且在点回
    /// Listings 之前它会一直亮着。所以它在列表外面，长得像一个动作，不像一个页面。
    ///
    /// 用 `SettingsLink` 而不是 `@Environment(\.openSettings)`：前者由 SwiftUI 直接
    /// 连到 `Settings` 场景，设置窗口已经开着时会把它**拿到前面**，而不是什么都不发生。
    private var settingsRow: some View {
        SettingsLink {
            HStack(spacing: 9) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .frame(width: 14)
                Text("Settings")
                    .font(.body)
                Spacer(minLength: 4)
                // 顺手把快捷键写出来。菜单里本来就有，但会走侧栏的人正是不翻菜单的那批。
                Text("⌘,")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            // 6 + 10 = 16pt，和 List 给侧栏行的缩进对齐。这个数是**量出来的**：
            // 窗口截图里导航行的图标左沿在 17.0pt（12pt 字形在 14pt 框里，框在 16），
            // 原来写 8 + 10 的时候这一行的齿轮落在 19pt，比上面四行右 2pt——
            // 单看不出来，和它们竖着排在一起就看出来了。
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(settingsHovered ? Theme.selectionFill : .clear))
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        // 列表里的行有系统给的悬停反馈，这一行在列表外面，得自己画。
        .onHover { settingsHovered = $0 }
    }

    // MARK: - 主导航

    private func navRow(_ section: SidebarSection) -> some View {
        HStack(spacing: 9) {
            Image(systemName: section.systemImage)
                .font(.system(size: 12))
                .frame(width: 14)
            Text(section.label)
                .font(.body.weight(model.section == section ? .semibold : .regular))
            Spacer(minLength: 4)
            countLabel(section)
        }
        .frame(height: 28)
    }

    /// 条目右侧的计数。
    ///
    /// **只显示真的有的数**。Listings 用 `ListingsStore.total`（后端给的全量，
    /// 不是已加载条数）；Alerts 的未读数要等通知那一屏接上 `NotificationsStore`
    /// 才有，现在什么都不画——而不是照着设计稿摆一个编出来的 7。
    @ViewBuilder
    private func countLabel(_ section: SidebarSection) -> some View {
        switch section {
        case .listings where model.listings.total > 0:
            Text("\(model.listings.total)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        default:
            EmptyView()
        }
    }

    // MARK: - 为什么没有「Saved Filters」
    //
    // 设计稿 t3 的侧栏里有一段「保存的筛选」，摆着四条命名的浏览筛选。**不做。**
    //
    // 它和这个产品的模型不符：**筛选条件是跟账号走的，只有一条**——后端
    // `/me/filter` 就是 GET / PUT 单数，那一条决定推送什么，在设置页的 Filters
    // tab 里编辑。"同时存着好几套命名筛选、在侧栏里来回切"是另一种产品的做法。
    //
    // 这一段曾经以空状态的形式留在这里（"No saved filters"）。撤掉的直接理由是：
    // App 里根本没有「保存当前筛选」这个动作，用户做任何操作都不可能让它非空。
    // 一个永远填不满的容器比没有更糟——它在承诺一个不存在的功能。
    //
    // 下次再照着设计稿往回加之前，先回答：那条筛选存在哪、跟不跟账号走、
    // 和 `/me/filter` 那一条是什么关系。

    // MARK: - 固定比较项

    /// 设计稿 t3 把比较卡从右栏移走之后，钉住的房源**只在这儿**（外加表格行首
    /// 那个墨色菱形）。所以这一段是「我钉了哪几套」的唯一去处。
    @ViewBuilder
    private var pinned: some View {
        if !model.pinned.isEmpty {
            Section {
                ForEach(model.pinnedListings, id: \.id) { entry in
                    pinnedRow(id: entry.id, listing: entry.listing)
                }
            } header: {
                sectionHeader("Pinned")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 10)
    }

    @ViewBuilder
    private func pinnedRow(id: Listing.ID, listing: Listing?) -> some View {
        Button {
            if listing != nil { model.focused = id }
        } label: {
            HStack(spacing: 9) {
                // 和表格行首同一个标记：6px 墨色菱形。
                Rectangle()
                    .fill(Theme.ink)
                    .frame(width: 6, height: 6)
                    .rotationEffect(.degrees(45))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    // 房源下架后**不自动换成另一套**——那会让人以为自己还在比较
                    // 原来那两套。
                    Text(listing?.name ?? "No longer available")
                        .font(.body)
                        .foregroundStyle(listing == nil ? AnyShapeStyle(Color.orange)
                                                        : AnyShapeStyle(Color.primary))
                        .lineLimit(1)
                    if let l = listing {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Theme.statusColor(ListingStatus.from(l.status)))
                                .frame(width: 5, height: 5)
                            Text(l.city)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Unpin") { model.togglePin(id) }
        }
    }

    // MARK: - 底部实时状态

    private var liveFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // 绿 = 数据新鲜，橙 = 拉取失败、看到的是旧数据。
                // iOS 那边这个点会呼吸，Mac 上刻意不做动画：侧栏底部一直在动的点
                // 是干扰，而这里的语义靠颜色就说清了。
                Circle()
                    .fill(isStale ? Color.statusLottery : Color.statusBook)
                    .frame(width: 6, height: 6)
                Text(isStale ? "Offline" : "Live")
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            Text(footerDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var isStale: Bool {
        model.listings.errorMessage != nil || summary.failed
    }

    /// `7 platforms · scanned 4m ago`。两半都可能缺，缺的那半整段省略，
    /// 不显示 "0 platforms" 或 "scanned unknown"。
    private var footerDetail: String {
        var parts: [String] = []
        let sources = Set(model.listings.listings.compactMap(\.source)).count
        if sources > 0 {
            parts.append(sources == 1 ? "1 platform" : "\(sources) platforms")
        }
        if let ago = summary.scannedAgoText {
            // 走共用的那一份（原先这里是第四处裸字面量）。这里**不**套
            // `sentence(_:)`：它跟在 `7 platforms · ` 后面。
            parts.append(StatusWording.scanned(ago))
        }
        return parts.joined(separator: " · ")
    }
}
