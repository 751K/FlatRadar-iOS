import SwiftUI
import MapKit
import FlatRadarCore

/// 地图屏。
///
/// 和 iOS 地图的关系
/// ---------------
/// 数据层整个复用 `FlatRadarCore.MapStore`（取数、筛选、状态计数），一行没重写。
/// 视图层是新的，因为要回答的问题不一样：iPhone 上是"我附近有什么"，
/// Mac 上是**"这一批房源分布在哪儿"**——所以标记显示价格和套数，而不是一枚枚针。
///
/// 标记的单位是**楼盘**不是房源，理由见 ``MapBuilding``：同一地址的若干套共用
/// 一个近似坐标，画成 12 枚针是用 12 个假位置冒充 12 个地点。
struct MapPane: View {

    @Bindable var model: BrowseModel
    let store: MapStore

    @State private var camera: MapCameraPosition = .automatic
    /// 当前缩放对应的纬度跨度，用来决定画楼盘还是画城市团。
    @State private var span: CLLocationDegrees = 1

    /// 最近一次的可视区域。
    ///
    /// `MapCameraPosition` 读不出当前 region（它只是"要去哪儿"的指令，不是
    /// "现在在哪儿"的状态），而 + / − 按钮要拿当前跨度乘个系数。
    /// 所以在 `onMapCameraChange` 里留一份。
    @State private var lastRegion: MKCoordinateRegion?

    var body: some View {
        content.task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.listings.isEmpty {
            centered { ProgressView("Loading map…") }
        } else if let err = store.errorMessage, store.listings.isEmpty {
            centered { loadFailure(err) }
        } else if buildings.isEmpty {
            centered { noMatches }
        } else {
            mapBody
        }
    }

    // MARK: - 派生数据

    private var buildings: [MapBuilding] { MapBuilding.group(store.visibleListings) }
    private var clusters: [MapCluster] { MapCluster.group(buildings) }

    /// 缩到多远就改画城市团。
    ///
    /// 判据用**纬度跨度**而不是 Leaflet 那种整数 zoom level：SwiftUI 的
    /// `MapCameraUpdateContext` 给的是 region，没有 zoom level，硬换算要引进
    /// 一堆瓦片数学。0.5° ≈ 55km，正好是"看得见整个兰斯塔德"那一档。
    private var showsClusters: Bool { span > 0.5 }

    // MARK: - 地图

    private var mapBody: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if showsClusters {
                ForEach(clusters) { cluster in
                    Annotation("", coordinate: cluster.coordinate, anchor: .center) {
                        clusterMarker(cluster)
                    }
                }
            } else {
                ForEach(buildings) { building in
                    Annotation("", coordinate: building.coordinate, anchor: .center) {
                        buildingMarker(building)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .onMapCameraChange(frequency: .continuous) { context in
            span = context.region.span.latitudeDelta
            // `MapCameraPosition` 读不出当前 region，+ / − 按钮要拿它算新跨度，
            // 所以每次相机变化都留一份最近值。
            lastRegion = context.region
        }
        .overlay(alignment: .topLeading) { filterTokens.padding(14) }
        .overlay(alignment: .topTrailing) { legend.padding(14) }
        .overlay(alignment: .bottomTrailing) { zoomControls }
    }

    // MARK: - 标记

    /// 楼盘标记：一个状态点 + 最低价 + 套数。
    ///
    /// 显示**价格**而不是房源名，因为这一屏在回答"哪儿便宜"。名字在 inspector 里。
    private func buildingMarker(_ b: MapBuilding) -> some View {
        let selected = model.mapBuilding?.id == b.id
        return Button {
            select(b)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(markerColor(b))
                    .frame(width: 7, height: 7)
                Text(priceLabel(b))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if b.count > 1 {
                    Text("· \(b.count)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? .white.opacity(0.6) : .secondary)
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .frame(height: 24)
            .background(selected ? AnyShapeStyle(Theme.ink)
                                 : AnyShapeStyle(Color(nsColor: .textBackgroundColor)),
                        in: Capsule())
            .shadow(color: .black.opacity(selected ? 0.4 : 0.22),
                    radius: selected ? 8 : 3, y: selected ? 3 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(b.name), \(b.city), \(b.count) listing\(b.count == 1 ? "" : "s")")
    }

    /// 城市团：墨色圆 + 套数。点一下飞过去。
    private func clusterMarker(_ c: MapCluster) -> some View {
        Button {
            zoom(to: c.buildings.map(\.coordinate), padding: 1.6)
        } label: {
            Text("\(c.unitCount)")
                .font(.callout.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.ink, in: Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.38), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(c.id), \(c.unitCount) listings")
    }

    private func priceLabel(_ b: MapBuilding) -> String {
        guard let low = b.lowestPrice else {
            // 兜底也要归一：OurDomain 的 `"€ 1.125"` 原样贴到地图标记上会被读成小数。
            let raw = b.units.first?.priceRaw
            return PriceText.compact(raw) ?? raw ?? "—"
        }
        let n = Int(low.rounded())
        return b.count > 1 ? "from €\(n)" : "€\(n)"
    }

    /// 标记一律用**状态色**。
    ///
    /// 曾经还有一个"按价格上色"的模式（墨色四级透明度）。去掉了：价格已经**写在
    /// 标记上**（`from €1171`），再用深浅表示一遍是同一份信息说两次；而颜色是这张
    /// 图上唯一的通道，留给"能不能租"更值——那是看地图时真正在扫的东西。
    private func markerColor(_ b: MapBuilding) -> Color {
        Theme.statusColor(b.leadStatus)
    }

    // MARK: - 浮层

    private var filterTokens: some View {
        HStack(spacing: 6) {
            ForEach(activeTokens) { token in
                mapToken(token.label, remove: token.remove)
            }
            Button {
                model.showFilterPanel.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11, weight: .medium))
                    Text("All filters").font(.callout)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private func mapToken(_ label: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Text(label).font(.callout)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter: \(label)")
    }

    /// 图例，外加"看到了多少"。放**右上角**：左上角是筛选 token，那一排会随着
    /// 筛选条件变长变短，图例挨着它就会跟着被推来推去。分到两头，各自钉住一个角。
    ///
    /// **没有图例的颜色等于没有信息**——虽然状态色和右栏的胶囊是同一套，
    /// 但地图上没有胶囊可以对照。
    /// 图例，外加"看到了多少"。
    ///
    /// 原来底部有一条 26pt 的白带装这两个数。它把地图从下面切掉一块，
    /// 只为放两行短字——而左下角本来就有一块浮层。并进来之后地图铺满，
    /// **也没有多出任何一块底色**：计数用的是图例已经有的那层玻璃。
    ///
    /// 顺手删掉的还有原来右下那句 "Drag to pan · click a marker to inspect"。
    /// 拖动和点击在 Mac 上是不需要教的，而它常驻占着一整条。
    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rangeText)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
            if store.uncached > 0 {
                // 后端明说了有多少条**没有坐标**。不说的话用户会以为地图上
                // 就是全部，而实际少了一截。
                Text("\(store.uncached) without coordinates")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider().padding(.vertical, 2)
            Text("Status")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(legendItems, id: \.label) { item in
                HStack(spacing: 7) {
                    Circle().fill(item.color).frame(width: 8, height: 8)
                    Text(item.label).font(.subheadline)
                }
            }
        }
        // `Divider()` 在 VStack 里会**撑满可用宽度**——不收一下，这块浮层会横着
        // 拉通整个地图（实测就是这样）。`fixedSize` 让它退回到最宽那行文字的宽度。
        .fixedSize()
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9))
    }

    /// 只列四档业务状态，不列 `.other`——它在表格里显示后端给的原始串，
    /// 在图例里没法给一个稳定的名字。
    private var legendItems: [(color: Color, label: String)] {
        [ListingStatus.book, .lottery, .reserved, .occupied].map {
            (Theme.statusColor($0), Theme.shortStatusLabel($0) ?? "—")
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 4) {
            zoomButton("plus") { scale(by: 0.5) }
            zoomButton("minus") { scale(by: 2) }
            Button { fitAll() } label: {
                Text("Fit")
                    .font(.caption.weight(.medium))
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Zoom out to show every listing")
        }
        .padding(14)
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// 「看到了多少」。缩到城市团那一档时说城市数，否则说楼盘数——
    /// 因为那一档屏幕上根本没有楼盘标记，报楼盘数对不上眼前看到的东西。
    private var rangeText: String {
        let units = buildings.reduce(0) { $0 + $1.count }
        if showsClusters {
            return "\(units) shown · \(clusters.count) cities"
        }
        return "\(units) shown · \(buildings.count) buildings"
    }

    // MARK: - 动作

    private func load() async {
        guard store.listings.isEmpty else { return }
        await store.fetch()
        fitAll()
    }

    /// 选中一栋楼：inspector 换成这栋楼的单元列表，镜头挪过去。
    private func select(_ b: MapBuilding) {
        model.mapBuilding = b
        // 顺手把焦点落到最值得看的那一套，右栏详情立刻有内容。
        model.focused = b.units.first?.id
        withAnimation(.easeOut(duration: 0.25)) {
            camera = .region(MKCoordinateRegion(center: b.coordinate,
                                                span: MKCoordinateSpan(latitudeDelta: max(span, 0.004),
                                                                       longitudeDelta: max(span, 0.004))))
        }
    }

    private func scale(by factor: Double) {
        guard let region = lastRegion else { return }
        let s = MKCoordinateSpan(
            latitudeDelta: min(max(region.span.latitudeDelta * factor, 0.002), 60),
            longitudeDelta: min(max(region.span.longitudeDelta * factor, 0.002), 60))
        withAnimation(.easeOut(duration: 0.2)) {
            camera = .region(MKCoordinateRegion(center: region.center, span: s))
        }
    }

    /// 缩到能装下全部房源。首屏和 `Fit` 都走它。
    private func fitAll() {
        zoom(to: buildings.map(\.coordinate), padding: 1.35)
    }

    private func zoom(to coords: [CLLocationCoordinate2D], padding: Double) {
        guard !coords.isEmpty else { return }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2)
        // 下限 0.01° ≈ 1.1km：只有一栋楼时不要把镜头怼到贴脸。
        let s = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * padding, 0.01),
            longitudeDelta: max((lons.max()! - lons.min()!) * padding, 0.01))
        withAnimation(.easeOut(duration: 0.4)) {
            camera = .region(MKCoordinateRegion(center: center, span: s))
        }
    }

    /// 筛选条上那一排 token，从 ``MapStore`` 的筛选字段现算。
    ///
    /// **状态那一档只在被收窄时才出现**：五档全开是默认值，画一个
    /// 「Status: 5 ✕」的 token 等于告诉用户"你筛过了"，而他没有。
    private var activeTokens: [FilterToken] {
        var out: [FilterToken] = []
        if !store.cityFilter.isEmpty {
            out.append(FilterToken(id: "city", label: store.cityFilter) { store.cityFilter = "" })
        }
        if !store.sourceFilter.isEmpty {
            out.append(FilterToken(id: "source",
                                   label: Platform.displayName(store.sourceFilter)) {
                store.sourceFilter = ""
            })
        }
        if !store.maxRentText.isEmpty {
            out.append(FilterToken(id: "rent", label: "≤ €\(store.maxRentText)") {
                store.maxRentText = ""
            })
        }
        if !store.minAreaText.isEmpty {
            out.append(FilterToken(id: "area", label: "≥ \(store.minAreaText) m²") {
                store.minAreaText = ""
            })
        }
        let all = ListingStatus.allCases.count
        if store.activeStatuses.count < all {
            out.append(FilterToken(id: "status",
                                   label: "Status: \(store.activeStatuses.count)") {
                store.showEverything()
            })
        }
        return out
    }

    // MARK: - 空状态

    private func loadFailure(_ message: String) -> some View {
        ContentUnavailableView {
            Label(store.lastError?.errorDescription ?? "Unable to Load the Map",
                  systemImage: store.lastError?.systemImage ?? "wifi.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await store.refresh() } }
        }
    }

    private var noMatches: some View {
        ContentUnavailableView("Nothing on the Map",
                               systemImage: "mappin.slash",
                               description: Text(store.listings.isEmpty
                                                 ? "No listings have coordinates yet."
                                                 : "No listing matches the current filters."))
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
