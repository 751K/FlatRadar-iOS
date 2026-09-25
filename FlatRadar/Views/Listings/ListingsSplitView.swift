import SwiftUI
import FlatRadarCore

/// iPad 宽窗口的房源列表与详情，共用单列导航的路径作为唯一选择状态。
/// 窗口缩窄后 BrowseView 会把同一条路径显示为 push 详情，无需搬移状态。
struct ListingsSplitView: View {
    @Environment(NavigationCoordinator.self) private var coord
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var selectedRoute: ListingRoute? { coord.listingsPath.last }

    var body: some View {
        GeometryReader { proxy in
            splitView(isLandscape: proxy.size.width > proxy.size.height)
        }
    }

    private func splitView(isLandscape: Bool) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ListingsView(
                state: coord.listingsState,
                selectedListingID: selectedRoute?.listingID,
                onSelectListing: { listing in
                    // 点击下一套房是替换右栏选择，不累积详情返回栈。
                    guard selectedRoute?.listingID != listing.id else { return }
                    coord.listingsPath = [.known(listing)]
                }
            )
            .navigationTitle("Listings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .sidebarToggle)
            .modifier(ListingsColumnSurface())
            // 放在列的最外层，避免导航容器背景截断列宽偏好。
            .navigationSplitViewColumnWidth(
                min: isLandscape ? 420 : 320,
                ideal: isLandscape ? 460 : 320,
                max: isLandscape ? 520 : 320
            )
        } detail: {
            Group {
                if let route = selectedRoute {
                    ListingDetailView(route: route, isSplitDetail: true)
                        // 详情持有异步加载状态；换房源时必须重置，避免沿用上一套数据。
                        .id(route)
                } else {
                    ContentUnavailableView(
                        "Select a Listing",
                        systemImage: "house",
                        description: Text("Choose a listing to view its details.")
                    )
                }
            }
            .modifier(ListingsColumnSurface())
        }
        .navigationSplitViewStyle(.balanced)
        .containerBackground(Color(.systemGroupedBackground), for: .navigationSplitView)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

/// 列背景、导航栏使用相同的不透明底色，避免系统 sidebar 材质给列表染色。
private struct ListingsColumnSurface: ViewModifier {
    func body(content: Content) -> some View {
        surface(content)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .containerBackground(Color(.systemGroupedBackground), for: .navigation)
            .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // 分栏已有固定导航栏，不再用渐变模糊层覆盖滚动到顶部的标题。
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}
