import SwiftUI
import FlatRadarCore

/// 主窗口左栏：主导航 + 保存的筛选器 + 固定比较项，底部一条实时状态。
///
/// 这是 Mac 版取代 iOS tab bar 的位置，见 ``SidebarSection`` 顶部注释。
///
/// 视觉上按设计稿 t2「去线留白」走：侧栏和 inspector 用**一档灰**、内容区纯白，
/// 三栏之间**不画 1px 描边**——边界靠明度差，不靠线。
struct SidebarView: View {

    @Bindable var model: BrowseModel
    let summary: SummaryModel

    var body: some View {
        List(selection: $model.section) {
            ForEach(SidebarSection.allCases) { section in
                navRow(section).tag(section)
            }
            savedFilters
            pinned
        }
        .listStyle(.sidebar)
        // 选中态用中性填充，不是实心强调色 —— 窗口的 tint 是 ink（近黑），
        // 直接拿它填一整行会变成黑底白字，比内容还抢眼。
        .tint(Theme.selectionFill)
        .safeAreaInset(edge: .bottom, spacing: 0) { liveFooter }
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

    // MARK: - 保存的筛选器

    /// 后端 `/me/filter` 是 **GET / PUT 单数**——每个账号只有一个筛选器，
    /// 而且那是**通知**筛选器，不是浏览筛选器。设计稿上那四条需要先定：
    /// 加后端多筛选器，还是只存在 Mac 本地（那样和 iOS 不同步）。
    ///
    /// 定下来之前显示真实的空状态，**不摆四条假数据**——假数据会让人以为功能
    /// 已经在了，然后在别处发现它不工作。
    private var savedFilters: some View {
        Section {
            Text("No saved filters")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(height: 26)
        } header: {
            sectionHeader("Saved Filters")
        }
    }

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
                        .font(.callout)
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
            parts.append("scanned \(ago)")
        }
        return parts.joined(separator: " · ")
    }
}
