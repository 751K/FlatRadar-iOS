import SwiftUI
import AppKit
import FlatRadarCore

/// 一套房源的独立窗口。
///
/// 它是 Phase 4 第一条「把一套房源拖出来单开窗口，两个并排比」的落点，
/// 同时也回答了 ``InspectorPane`` 文件头留的那个问号：设计稿 t3 把比较卡从右栏
/// 移走之后，「并排比较」一直**没有显示的地方**（原注释写的是"多窗口？单独的
/// 比较视图？"）。答案是多窗口——两个真窗口并排，比一个塞进右栏的比较卡强在
/// 它们可以各自滚动、各自留在屏上、各自被 Mission Control 管理。
///
/// 为什么不复用 ``InspectorPane``
/// ---------------------------
/// 那个面板认识 `BrowseModel`：它要显示"地图选中的楼"、"日历选中的那天"、
/// "通知选中的那条"，还要读窗口的钉住列表。独立窗口里这些**一个都不存在**——
/// 它只认一套房。硬塞一个 `BrowseModel` 进来就是为了满足类型而造一个空壳。
///
/// 真正会重复的那几段（标题、徽章、八行事实、出处、矮按钮）已经抽进
/// ``ListingFacts``，两处共用，不会漂移。
///
/// 窗口是**按 id 去重**的
/// --------------------
/// `WindowGroup(id:for:)` 对同一个 value 只开一个窗口，再 `openWindow` 一次是
/// 把已有那个**激活**。风险 6 里「优先激活已显示该房源的窗口，否则打开详情窗口」
/// 这条因此是白送的，不用自己维护一张 id → 窗口的表。
struct ListingWindow: View {

    /// `nil` 只会出现在一种情况下：系统在恢复上次退出时的窗口，而那条房源的 id
    /// 没能反序列化。给一句明确的话，不留一个空窗。
    let id: Listing.ID?

    @State private var store = SingleListingStore()
    @State private var thumbnails = MapThumbnailStore()

    /// 正在问坐标。和 ``InspectorPane`` 同一套：按钮变 `Locating…` 并禁用。
    @State private var locating = false
    @State private var mapsFailure: String?

    var body: some View {
        content
            .frame(minWidth: 380, idealWidth: 420, maxWidth: 560,
                   minHeight: 420, idealHeight: 620)
            // 窗口标题就是房源名。没加载出来之前用占位，不让标题栏空着——
            // ⌘` 和 Mission Control 里全靠它区分两个详情窗口。
            .navigationTitle(store.listing?.name ?? "Listing")
            .navigationSubtitle(store.listing.map(ListingText.subtitle) ?? "")
            .task(id: id) {
                guard let id else { return }
                await store.load(id)
            }
    }

    @ViewBuilder
    private var content: some View {
        if id == nil {
            unavailable("This window lost track of which listing it was showing.")
        } else if let l = store.listing {
            detail(l)
        } else if store.isLoading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailable(store.failure ?? "This listing is no longer available.")
        }
    }

    private func detail(_ l: Listing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 标题在这里用 `prominent`：独立窗口里它就是主体，
                // 而右栏里它上面还压着"选中的楼 / 那一天 / 那条通知"。
                ListingHeading(listing: l, prominent: true)
                ListingBadgeRow(listing: l).padding(.top, 11)
                ListingFactsTable(listing: l).padding(.top, 20)
                MapThumbnail(listing: l, store: thumbnails).padding(.top, 14)
                actions(l).padding(.top, 18)
                ListingProvenance(listing: l).padding(.top, 14)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 独立窗口里**没有 Pin**。
    ///
    /// 钉住是「在那个浏览窗口里选两套对比」的状态，属于 `BrowseModel`——
    /// 而这个窗口本身就是比较的另一种形态。放一个按钮在这里，它要么改不了任何
    /// 窗口的状态（假按钮），要么得挑一个"当前窗口"去改（哪一个？）。
    private func actions(_ l: Listing) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            // 真换行，不是写死两行——理由见 ``WrappingRow``。这个窗口宽度可调
            // （380–560），写死分行在哪一端都不对。
            WrappingRow {
                ListingActionButton(title: "Open on \(Platform.displayName(l.source))",
                                    prominent: true) {
                    if let url = URL(string: l.url) { NSWorkspace.shared.open(url) }
                }
                ListingActionButton(title: "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(l.url, forType: .string)
                }
                ListingShareButton(listing: l)
                ListingActionButton(title: locating ? "Locating…" : "Open in Maps") {
                    locating = true
                    Task {
                        let ok = await OpenInMaps.open(.needsLookup(id: l.id, name: l.name),
                                                       thumbnails: thumbnails)
                        locating = false
                        if !ok {
                            mapsFailure = "No coordinates for this listing yet — its address "
                                        + "has not been geocoded, so Maps cannot route to it."
                        }
                    }
                }
                .disabled(locating)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let note = mapsFailure {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Listing Unavailable", systemImage: "house.slash")
        } description: {
            Text(message)
        } actions: {
            if let id {
                Button("Try Again") { Task { await store.load(id, force: true) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 按 id 取一套房源。
///
/// 为什么不从某个 `BrowseModel.listings` 里找
/// ---------------------------------------
/// 独立窗口可能在**没有任何浏览窗口**的时候存在：关掉主窗口、或者从菜单栏常驻
/// 里打开一条通知。那时候没有任何 store 里有这条数据。
///
/// 而且 `/listings` 的集合套着账号的个人筛选，`/map`、`/calendar` 各是另一个
/// 集合——从哪个里面找都可能找不到一条明明存在的房源。`GET /listings/{id}` 是
/// 唯一按 id 回答"这套房是什么"的接口。
@MainActor
@Observable
final class SingleListingStore {

    private(set) var listing: Listing?
    private(set) var isLoading = false
    private(set) var failure: String?

    /// 已经取到的是哪一条。`task(id:)` 在窗口恢复、切 Space 之类的场合会重跑，
    /// 有它就不会为同一条房源重复发请求。
    private var loadedID: Listing.ID?

    func load(_ id: Listing.ID, force: Bool = false) async {
        if !force, loadedID == id, listing != nil { return }
        guard !isLoading else { return }
        isLoading = true
        failure = nil
        do {
            listing = try await APIClient.shared.getListing(id: id)
            loadedID = id
        } catch {
            listing = nil
            loadedID = nil
            failure = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
