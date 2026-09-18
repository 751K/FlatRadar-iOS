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

    @Environment(AuthStore.self) private var auth
    @Environment(\.openWindow) private var openWindow

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
            // 按**房源 + 会话身份**加载，不只按房源。
            //
            // 原先只认 id，完全不看认证状态（代码审查 P2）：
            // - 退出之后窗口照旧显示那套房的详情；
            // - 换了账号不清也不重载，旧账号取回来的那份一直挂着；
            // - 系统在启动时**恢复窗口**，那一刻会话恢复还没跑完、请求不带 token，
            //   取不到就停在一个错误上，会话恢复好了也不会再试。
            // 身份一变（含恢复完成、登出、换号）这个任务就重跑，见 ``gate``。
            .task(id: LoadKey(listing: id, session: auth.sessionIdentity,
                              restoring: auth.isRestoringSession)) {
                switch Self.gate(listing: id, isRestoringSession: auth.isRestoringSession,
                                 sessionIdentity: auth.sessionIdentity) {
                case .load(let key): await store.load(key)
                case .signedOut: store.clear()
                case .waitingForSession, .lostListing: break
                }
            }
    }

    /// `task(id:)` 的 id。三样东西任何一样变了都要重新判断一次。
    private struct LoadKey: Equatable {
        let listing: Listing.ID?
        let session: String?
        let restoring: Bool
    }

    /// 这个窗口此刻该干什么。拆成纯函数是为了能测——尤其是"恢复中不许取数"那条，
    /// 它只在系统恢复窗口的那几百毫秒里成立，手测很难撞上。
    enum Gate: Equatable {
        /// 系统恢复窗口时会话还没恢复完：先等，**不发请求**。
        case waitingForSession
        /// 没登录（从来没登过，或者刚登出）：不显示任何房源数据。
        case signedOut
        /// 恢复窗口时 id 没能反序列化。
        case lostListing
        case load(SingleListingStore.Key)
    }

    static func gate(listing: Listing.ID?, isRestoringSession: Bool,
                     sessionIdentity: String?) -> Gate {
        if isRestoringSession { return .waitingForSession }
        guard let session = sessionIdentity else { return .signedOut }
        guard let listing else { return .lostListing }
        return .load(.init(id: listing, session: session))
    }

    @ViewBuilder
    private var content: some View {
        switch Self.gate(listing: id, isRestoringSession: auth.isRestoringSession,
                         sessionIdentity: auth.sessionIdentity) {
        case .waitingForSession:
            ProgressView("Signing in…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            signedOut
        case .lostListing:
            unavailable(String(localized: "This window lost track of which listing it was showing."))
        case .load:
            loaded
        }
    }

    /// 退出之后这个窗口里**不能再有房源数据**——那是上一个会话取回来的。
    /// 不自动关窗：它可能是用户特意摆在旁边的，重新登录之后按上面的 `task` 会
    /// 自己重新加载回来。
    private var signedOut: some View {
        ContentUnavailableView {
            Label("Signed Out", systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text("Sign in to FlatRadar to see this listing.")
        } actions: {
            Button("Open FlatRadar") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: FlatRadarMacApp.mainWindowID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var loaded: some View {
        if let l = store.listing {
            detail(l)
        } else if store.isLoading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailable(store.failure ?? String(localized: "This listing is no longer available."))
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
                            mapsFailure = String(localized: "No coordinates for this listing yet — its address has not been geocoded, so Maps cannot route to it.")
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
            if case .load(let key) = Self.gate(listing: id,
                                               isRestoringSession: auth.isRestoringSession,
                                               sessionIdentity: auth.sessionIdentity) {
                Button("Try Again") { Task { await store.load(key, force: true) } }
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

    /// 取的是**哪个会话里的哪套房**。同一套房换个账号要重新取——旧账号那份不能留着。
    struct Key: Equatable {
        let id: Listing.ID
        let session: String
    }

    private(set) var listing: Listing?
    private(set) var isLoading = false
    private(set) var failure: String?

    /// 已经取到的是哪一份。`task(id:)` 在切 Space 之类的场合会重跑，
    /// 有它就不会为同一份重复发请求。
    @ObservationIgnored private var loadedKey: Key?

    /// 最近一次**要**的是哪一份。请求回来时和它比：不一样就说明期间换了人 / 登出了，
    /// 这份结果作废，什么都不碰。
    @ObservationIgnored private var requestedKey: Key?

    /// 发请求那一步。默认走 `APIClient`；测试换成能扣住请求的闭包——这里的 bug
    /// 全是"旧请求在新请求之后回来"，真网络上摆不出那个顺序。
    @ObservationIgnored var fetch: (Listing.ID) async throws -> Listing = {
        try await APIClient.shared.getListing(id: $0)
    }

    /// 取一份。
    ///
    /// 原先开头是 `guard !isLoading else { return }`。换号时 `task(id:)` 重跑，旧请求
    /// 还在收尾、`isLoading` 还是 true，**新请求被这一句直接挡掉**；旧请求随后以
    /// "已取消"结束，窗口停在一个错误上。和列表翻页那把锁是同一类问题，同一个修法：
    /// 过期的请求什么都不碰，"正在加载"归最新那一次。
    func load(_ key: Key, force: Bool = false) async {
        if !force, loadedKey == key, listing != nil { return }
        if isLoading, requestedKey == key { return }
        // 换了人：旧账号取回来的那份**立刻**撤掉，不等新的回来。
        if loadedKey?.session != key.session {
            listing = nil
            loadedKey = nil
        }
        requestedKey = key
        isLoading = true
        failure = nil
        do {
            let result = try await fetch(key.id)
            guard requestedKey == key else { return }
            listing = result
            loadedKey = key
        } catch {
            guard requestedKey == key else { return }
            if !error.isCancellation {
                listing = nil
                loadedKey = nil
                failure = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
        isLoading = false
    }

    /// 登出：清掉这个窗口里上一个会话的一切，在途的请求回来也不许再写。
    func clear() {
        requestedKey = nil
        loadedKey = nil
        listing = nil
        failure = nil
        isLoading = false
    }
}
