import SwiftUI
import MapKit
import FlatRadarCore

/// inspector 里那块小地图。**可以拖**。
///
/// 坐标从哪来
/// ---------
/// `Listing` 里**没有**经纬度，`/listings` 一次回几百条，给每条都塞坐标是白传；
/// 而且地理编码是有副作用的（`/map` 的 summary 特意写了 "never triggers geocoding
/// side effects"）。后端为这件事单独给了 `GET /map/locate?id=`，
/// 包里封成 ``APIClient/locateListing(id:)``。
///
/// 从静态快照换成实时地图
/// --------------------
/// 第一版用 `MKMapSnapshotter` 出一张图。要能拖就没法这么做了——拖一下重出一张图
/// 是不可能跟手的。换成 SwiftUI 的 `Map` 之后整层快照缓存（按边长重取、
/// 缩放清晰度、`NSImage` 缓存）全部删掉了，代码反而短。
///
/// 留下来的只有 **id → 坐标** 这一层缓存：那是网络请求，↑↓ 一路翻过去
/// 每条只该问一次。
@MainActor
@Observable
final class MapThumbnailStore {

    enum Entry {
        case loading
        case located(MapListing)
        /// 后端不认识这条房源。
        case notFound
        /// 认识，但还没地理编码出坐标。
        case noCoordinates
        /// 网络失败——和上面两种**分开**：这条是可以重试的。
        case failed
    }

    private var entries: [Listing.ID: Entry] = [:]
    private var inFlight: Set<Listing.ID> = []

    func entry(for id: Listing.ID) -> Entry? { entries[id] }

    /// 按 id 缓存。缓存**不设上限**：一次会话最多也就翻过全量那几百条，
    /// 每条只是一个坐标，比再发一遍请求便宜得多。
    func load(id: Listing.ID) async {
        guard entries[id] == nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        entries[id] = .loading
        defer { inFlight.remove(id) }

        do {
            switch try await APIClient.shared.locateListing(id: id) {
            case .notFound:              entries[id] = .notFound
            case .noCoordinates:         entries[id] = .noCoordinates
            case .located(let listing):  entries[id] = .located(listing)
            }
        } catch {
            entries[id] = .failed
            #if DEBUG
            print("[MapThumbnail] \(id): \(error.localizedDescription)")
            #endif
        }
    }

    /// 重试只清掉可重试的那一种。`notFound` / `noCoordinates` 是后端的事实，
    /// 再点一百次也不会变，不给重试入口。
    func retry(id: Listing.ID) {
        if case .failed = entries[id] { entries[id] = nil }
    }
}

// MARK: - 视图

struct MapThumbnail: View {

    let listing: Listing
    let store: MapThumbnailStore

    /// 缩略图是**正方形**，边长跟着 inspector 的宽度走。
    ///
    /// 地图的两个方向一样重要（"在城市的北边还是南边"和"东边还是西边"是同一个
    /// 问题），设计稿那个 2.3:1 的信箱框在同样比例尺下把南北的可见范围压到了
    /// 东西的 43%。正方形让两个方向对称。
    @State private var side: CGFloat = 0

    /// 镜头。换房源时重置回那套房的位置，拖过之后由用户说了算。
    @State private var camera: MapCameraPosition = .automatic

    /// 镜头被动过没有（拖走**或者**缩放过）。动过才显示「回到房源」——
    /// 没动的时候放个按钮在那儿只是噪音。
    @State private var cameraMoved = false

    /// 初始视野，**两个方向都是它**。
    ///
    /// 回答的问题是「在城市的哪一块」，不是「在哪条街」——右边那行地址已经写了
    /// 街名。6km 见方够覆盖一座荷兰中等城市的大半（Amsterdam 约 12km 横跨、
    /// Eindhoven 约 10km），能看出离市中心多远、在哪个方向。
    ///
    /// **每条房源都从这个尺度开始**，不按房源自适应：这个 app 的核心任务是比较，
    /// 两条房源只有在同一个起始比例尺下才比得了。拖 / 缩之后是用户自己的事，
    /// 但换一条房源就回到基准。
    private static let spanMeters: CLLocationDistance = 6000

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: max(side, 1))
            .overlay { if side > 0 { content } }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // 宽度是 inspector 给的、和高度无关，所以「量宽度 → 设高度」是单向的，
            // 不会转成布局循环。（`defaultMinListRowHeight` 那次崩溃就是双向依赖
            // 转的无限失效，这里刻意避开。）
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { side = $0 }
            .task(id: listing.id) { await store.load(id: listing.id) }
            // 换房源 → 镜头回到新那套房上。不重置的话你会盯着上一套的街区，
            // 而右边所有字段都已经换了——最容易看错的一种状态。
            .onChange(of: listing.id) { _, _ in recenter(animated: false) }
            .onChange(of: coordinateKey) { _, _ in recenter(animated: false) }
    }

    /// 坐标是异步来的：`.task` 拿到之前 `entry` 是 `.loading`，镜头没东西可对。
    /// 用它当 onChange 的触发器，坐标一到就把镜头摆好。
    private var coordinateKey: String {
        guard case .located(let l)? = store.entry(for: listing.id) else { return "" }
        return "\(l.displayCoordinate.latitude),\(l.displayCoordinate.longitude)"
    }

    @ViewBuilder
    private var content: some View {
        switch store.entry(for: listing.id) {
        case .located(let mapListing):
            liveMap(mapListing)
        case .notFound:
            placeholder("Not on the map", detail: "The server doesn’t have this listing.")
        case .noCoordinates:
            placeholder("No coordinates yet", detail: "This address hasn’t been geocoded.")
        case .failed:
            failedPlaceholder
        case .loading, .none:
            ZStack { ProgressView().controlSize(.small) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.06))
        }
    }

    // MARK: - 地图

    private func liveMap(_ mapListing: MapListing) -> some View {
        Map(position: $camera, interactionModes: Self.interactions) {
            // 空标题：`Annotation(l.name, …)` 会在针下面画一行字，
            // 在这个尺寸里只会盖住地图。名字右边那行地址已经写了。
            Annotation("", coordinate: mapListing.displayCoordinate, anchor: .center) {
                pin(for: mapListing)
            }
        }
        .mapStyle(.standard(elevation: .flat,
                            pointsOfInterest: .excludingAll))
        .onMapCameraChange(frequency: .onEnd) { context in
            cameraMoved = moved(context.region, from: mapListing.displayCoordinate)
        }
        .overlay(alignment: .topTrailing) { recenterButton }
        // 右下角，不是左下角：`Map` 自己会在**左下**画 Apple 的 Legal 链接，
        // 那块地方不归我们。摆在那儿两层字会叠在一起（实测 "Europahuis" 把
        // "Legal" 盖掉了一半）。而且那个链接是要能点的，盖住它不只是难看。
        .overlay(alignment: .bottomTrailing) { bottomLabels(mapListing) }
    }

    /// 拖 + 缩放。
    ///
    /// ⚠️ **代价是真的**：这块地图住在 inspector 的 `ScrollView` 里，光标停在
    /// 地图上滚动会被地图吃掉去缩放，右栏那一下就不滚了。实测确认过
    /// （滚一下地图从 6km 缩到能看见 Badhoevedorp）。
    ///
    /// 这不是 bug 而是取舍，网页里嵌的地图也都是这个行为。能接受的前提是
    /// **误操作可以一键撤销**——所以 `cameraMoved` 把缩放也算进「镜头动过」，
    /// 缩歪了 Recenter 按钮就会出现。少了那一半判据的话，滚轮缩放不改中心，
    /// 按钮永远不出现，用户就真的回不去了。
    ///
    /// 不开 `.rotate` / `.pitch`：这是一块用来回答「在城市哪一块」的小图，
    /// 转歪了或者倾斜了只会让人失去方向感，而且没有任何入口能扶正。
    private static let interactions: MapInteractionModes = [.pan, .zoom]

    /// 房源针，**和 iOS 地图上那个是同一个东西**。
    ///
    /// 抄的是 `FlatRadar/Views/Map/MapView.swift` 的 `pinView(for:)`：
    /// 状态色渐变实心圆 + 2.5pt 白描边 + 居中的白色 `house.fill`。
    /// 同一个产品里同一样东西该长一个样——用户在 iPhone 上认熟的绿圆房子，
    /// 到 Mac 上不该变成一个黑方块。
    ///
    /// 颜色走 ``Theme/statusColor(_:)`` 而不是 `ListingStatus.color`：认不出的状态
    /// 在 Mac 这一端是灰的，不是紫的。这样针和它正上方那枚状态胶囊**永远同色**。
    /// iOS 地图保留紫色有它自己的理由（不并进终态才不会被筛选默认隐藏），
    /// 那条顾虑在这里不存在：缩略图不筛任何东西。
    private func pin(for mapListing: MapListing) -> some View {
        let color = Theme.statusColor(mapListing.statusKind)
        let size: CGFloat = 26
        return ZStack {
            Circle()
                .fill(color.gradient)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
            Circle()
                .stroke(.white, lineWidth: 2.5)
                .frame(width: size, height: size)
            Image(systemName: "house.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        // 位置和状态都已经由下面的地址 chip 和上方的状态胶囊说过了。
        .accessibilityHidden(true)
    }

    // MARK: - 覆盖层

    /// 镜头动过之后才出现。地图能拖能缩就必须有回来的路——否则拖丢了 / 缩过头了
    /// 只能靠换一条房源再换回来。
    @ViewBuilder
    private var recenterButton: some View {
        if cameraMoved {
            Button {
                recenter(animated: true)
            } label: {
                Label("Recenter", systemImage: "scope")
                    .font(.subheadline.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    // 液态玻璃**在这儿**才成立：它浮在地图上，底下是一直在变的
                    // 街道和绿地，折射出来的东西是真的。表格行底下只有纯白，
                    // 玻璃没有可折射的内容，那里它和一块淡色填充几乎没区别。
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(8)
            .transition(.opacity)
        }
    }

    private func bottomLabels(_ mapListing: MapListing) -> some View {
        // 放进同一个容器，两块玻璃靠近时才会融成一片；各自单独 `glassEffect`
        // 的话中间那道边界是硬的。iOS 端 `GlassGroup` 是同一个道理。
        GlassEffectContainer(spacing: 3) {
            // 跟着容器一起靠右：两块 chip 长短不一样，左对齐的话右边会长出
            // 一个参差的缺口，正对着地图边缘更明显。
            VStack(alignment: .trailing, spacing: 3) {
                approximateNotice(mapListing)
                chip(addressText(mapListing))
            }
        }
        // 别让长楼盘名一路顶到左边去——左下角是 Apple 的 Legal 链接，
        // 刚把 chip 从那儿挪开，不能又从另一头撞回去。
        .frame(maxWidth: side * 0.62, alignment: .trailing)
        .padding(8)
    }

    /// **契约，不是可选项。** `MapListing` 的 schema 里写着：
    ///
    /// > `stack_n`：How many listings share this exact address.
    /// > Clients **MUST** tell the user the position is approximate when this is > 1.
    ///
    /// 同一栋楼里十几个单元共用一个地址，后端把它们撒在一个小圈上——图上那个针
    /// 不是这一套的真实位置。
    ///
    /// 6km 跨度下那个圈只有亚像素大小，**看不出来**——这恰恰是必须写字的理由，
    /// 不是可以省掉的理由：视觉上越像精确位置，文字就越得说清它不是。
    /// （现在能拖能放大了，凑近看也还是那个撒开的位置，不会变准。）
    @ViewBuilder
    private func approximateNotice(_ mapListing: MapListing) -> some View {
        if mapListing.stackCount > 1 {
            chip("Approximate · \(mapListing.stackCount) units share this address",
                 tint: Color.statusLottery)
        }
    }

    private func chip(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(tint ?? Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 5))
    }

    private func addressText(_ mapListing: MapListing) -> String {
        let building = listing.buildingText ?? ""
        return building.isEmpty ? (mapListing.city.isEmpty ? listing.name : mapListing.city)
                                : building
    }

    // MARK: - 镜头

    private func recenter(animated: Bool) {
        guard case .located(let l)? = store.entry(for: listing.id) else { return }
        let region = MKCoordinateRegion(center: l.displayCoordinate,
                                        latitudinalMeters: Self.spanMeters,
                                        longitudinalMeters: Self.spanMeters)
        // ⚠️ 不能只写 `camera = .region(region)`。
        //
        // 用户拖动时 SwiftUI **不一定**把新位置写回这个绑定，所以绑定里可能还存着
        // 上一次归位时那个一模一样的 `.region(region)`。`MapCameraPosition` 是
        // Equatable，赋一个相等的值 SwiftUI 当没变，地图纹丝不动——实测就是这样：
        // Recenter 按钮消失了（`didPan` 归位了），地图还停在拖走的地方。
        //
        // 先掰到 `.automatic` 再掰回来，保证这一步一定是一次「变化」。
        camera = .automatic
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
        cameraMoved = false
    }

    /// 镜头算不算「被动过」——**位移和缩放都要看**。
    ///
    /// 只看位移是不够的：滚轮缩放不改中心，那样缩过头之后 Recenter 按钮不出现，
    /// 用户就没有任何入口回到基准视野了。这是加上 `.zoom` 之后才冒出来的问题。
    ///
    /// 两个判据都留了余量，免得手抖一下就弹按钮：
    /// - 位移超过视野的 1/6
    /// - 跨度缩到基准的 70% 以下、或放到 140% 以上
    private func moved(_ region: MKCoordinateRegion,
                       from origin: CLLocationCoordinate2D) -> Bool {
        let a = CLLocation(latitude: region.center.latitude,
                           longitude: region.center.longitude)
        let b = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        if a.distance(from: b) > Self.spanMeters / 6 { return true }

        // 纬度 1° ≈ 111.32 km，全球通用（经度才随纬度收缩）。
        let span = region.span.latitudeDelta * 111_320
        return span < Self.spanMeters * 0.7 || span > Self.spanMeters * 1.4
    }

    // MARK: - 各种「没有地图」

    /// `notFound` / `noCoordinates` 是后端的事实，说清楚是哪一种，不给重试。
    private func placeholder(_ title: String, detail: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.06))
    }

    private var failedPlaceholder: some View {
        VStack(spacing: 4) {
            Text("Couldn’t load the map")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Try Again") { store.retry(id: listing.id) }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.06))
    }
}
