import SwiftUI
import AppKit
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
/// 地图最近一次的相机和可视区域。
///
/// 是 class 不是值类型：见 ``MapPane/track`` 的注释——窗口尺寸变化的补偿要在
/// 连续几十次几何回调之间累加，需要"写进去立刻读得回来"。
@MainActor
private final class CameraTrack {
    var region: MKCoordinateRegion?
    var camera: MapCamera?
    /// 当前纬度跨度。**不是界面状态**：缩放时每帧都在变，而画面只关心它落在
    /// 哪一档（见 ``MapZoomBand``）。放这里，写它不会触发 body 重算。
    var span: CLLocationDegrees = 1
}

struct MapPane: View {

    @Bindable var model: BrowseModel
    let store: MapStore

    /// 窗口内容区有多宽。地图拿它判断自己的右沿有没有顶到窗口右边缘。
    let windowWidth: CGFloat

    /// 地图的右沿是不是已经顶到窗口右边缘了——等价于"inspector 收起来了"。
    ///
    /// 和左边那个一样**自己量**，而且这次是必须的：原来用的是 `showInspector`
    /// 那个布尔值，它在点下去的**瞬间**就翻了，而 inspector 是滑进来的——于是
    /// 图例先弹到顶，地图这时还铺到窗口右边缘，图例就和刷新 / 钉住 / inspector
    /// 那三个工具栏按钮叠在一起闪一下。按几何判断就不会有这个时间差：地图的右沿
    /// 缩回来多少，图例就跟着让多少。
    @State private var atWindowTrailingEdge = false

    /// 顶栏那条带子的高度。实测 51pt——`Hide Sidebar` 按钮的 frame 就是
    /// `[148, 0, 43×51]`，整条带子和它一样高。
    private static let toolbarBand: CGFloat = 51

    /// 顶栏**右端**那三个按钮（刷新 / 钉住 / inspector）占的宽度。实测它们的 frame
    /// 从 1282 排到 1396，靠右留 4pt，取 150 留一点余量。
    ///
    /// `nonisolated`：它在 `onGeometryChange` 的 `of:` 闭包里读，那个闭包是
    /// `@Sendable`、不在主线程隔离里。一个常数不需要主线程保护。
    nonisolated private static let toolbarTrailing: CGFloat = 150

    @State private var camera: MapCameraPosition = .automatic
    /// 缩放落在哪一档：画不画城市团、显不显示 POI。
    ///
    /// 原先这里存的是连续的 `span`，`.continuous` 相机回调每帧写一次，于是缩放时
    /// 每一帧都整个重算 body——楼盘分组、城市聚合、空状态判断、计数全跟着重来
    /// （代码审查：2000 条下约 34ms 一次，缩放掉帧）。而画面真正随缩放变化的只有
    /// 这两个开关，所以界面状态只存档位，连续值记在 ``CameraTrack/span``。
    @State private var zoomBand = MapZoomBand(span: 1)

    /// 楼盘分组和城市聚合的缓存。键是决定"哪些房源画在图上"的全部输入
    /// （``MapStore/VisibilityKey``），悬停、相机移动这些都不在里面。见 ``Memo``。
    @State private var buildingMemo = Memo<MapStore.VisibilityKey, [MapBuilding]>()
    @State private var clusterMemo = Memo<MapStore.VisibilityKey, [MapCluster]>()

    /// 最近一次的相机 / 可视区域。
    ///
    /// 存在**引用类型**里，不用 `@State`：一次开合动画里几何回调会连着来几十次，
    /// 补偿要在回调之间累加（见下面的注释）。`@State` 在同一轮更新里连写连读不保证
    /// 读到刚写的值，累加就断了；一个 class 写进去立刻就能读回来。
    @State private var track = CameraTrack()


    /// 「All filters」浮层开没开。
    ///
    /// **本地状态，不用 `model.showFilterPanel`。** 那个 flag 只有 `ListingsPane`
    /// 在渲染，地图这边 toggle 它什么都不会发生——正是这个按钮点不开的原因。
    /// 而且它是两屏共用的：在地图上点一下，切回 Listings 会发现那条占位面板莫名
    /// 其妙地开着。两屏的筛选界面本来就是两回事，状态也该各存各的。
    @State private var showFilters = false

    /// 鼠标正停在哪个楼盘标记上。悬停卡按它显示，见 ``hoverCard(_:)``。
    @State private var hoveredBuilding: MapBuilding.ID?

    /// 地图自己要说的一句话（「这条不在列表里」「这条不在地图上」）。
    ///
    /// 不用弹窗：这些都是"没能跳过去"的解释，不是需要确认的事。弹窗要点掉，
    /// 而用户下一步多半是继续在图上找，让他先点一个 OK 是添乱。
    @State private var mapNote: String?

    /// 我们自己发起的一次飞行会持续到什么时候。
    ///
    /// 用来让下面那段**尺寸变化补偿**在飞行途中闭嘴。两者的目的是冲突的：
    /// 补偿要的是"视图变了但地图别动"，飞行要的是"地图动到指定的中心"。
    /// 从列表切到地图屏时两件事同时发生——布局刚换完，补偿就把刚落位的中心
    /// 又推走。实测推了 0.0032° 经度 ≈ 220m，而那时可视范围只有 1.1km，
    /// 等于把目标推到了视野的五分之一开外。
    @State private var flyingUntil: Date?

    /// 连点 + / − 时的**目标**跨度，以及它什么时候过期。
    ///
    /// `scale(by:)` 原先每次都从 `track.region` 现读当前跨度算。那个值是
    /// **动画进行中的中间值**——连点四下实测：0.0635 → 0.0614 → 0.0614 → 0.0611，
    /// 四次各自从几乎同一个起点算出几乎同一个终点，最后一次盖掉前三次，
    /// 于是**点四下只等于点了一下**。
    ///
    /// 记住目标之后，动画期间的第二下从"上一下要去的地方"接着算，连点才累积。
    /// 过期时间给得比动画（0.2s）长一点：超过这个间隔说明上一段已经落定，
    /// 或者用户中途自己拖过缩放过，这时候该以地图的真实状态为准。
    @State private var zoomTarget: (span: CLLocationDegrees, until: Date)?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .task { await load() }
            // 列表那边右键「Show on Map」→ 切到这一屏 → 这里接住并飞过去。
            //
            // 盯的是 `seq` 不是 id：连着对同一套房点两次也要生效（见
            // ``BrowseModel/mapFocusRequest``）。
            .onChange(of: model.mapFocusRequest?.seq) { _, _ in focusRequestedListing() }
            // 切到地图屏的**那一次**也要接：`onChange` 只认变化，而
            // `locateOnMap` 是先切 section 再写请求，这一屏可能是在请求写下之后
            // 才第一次出现的——那时 `onChange` 根本没挂上。
            .task(id: model.mapFocusRequest?.seq) { focusRequestedListing() }
    }

    @ViewBuilder
    private var content: some View {
        switch MapPaneState.resolve(isLoading: store.isLoading,
                                    errorMessage: store.errorMessage,
                                    hasListings: !store.listings.isEmpty,
                                    hasVisibleBuildings: !buildings.isEmpty) {
        case .loading:
            centered { ProgressView("Loading map…") }
        case .failed(let err):
            centered { loadFailure(err) }
        case .noCoordinates:
            centered { noCoordinates }
        case .map(let filteredOut):
            // 筛到一条不剩时**地图照画**，说明卡盖在上面。
            //
            // 原先这种情况整屏换成空状态，而「All filters」按钮、筛选 token、Reset
            // 全都长在地图的浮层里——地图一没，它们跟着没，筛选却还存在窗口的
            // store 里，切屏回来还是这张空卡。用户把自己筛进了一个出不来的地方
            // （代码审查 P2）。现在浮层一直在，卡上也直接给了两条退路。
            mapBody.overlay {
                if filteredOut {
                    MapFilteredOutCard(breakdown: store.emptyBreakdown,
                                       onShowEverything: { store.showEverything() },
                                       onReset: { store.resetFilters() })
                }
            }
        }
    }

    // MARK: - 派生数据

    /// 数据或筛选没变就直接用上次的分组。一次 body 里空状态判断、标记、计数
    /// 各读一遍，原先是各分组一遍。
    private var buildings: [MapBuilding] {
        buildingMemo.value(for: store.visibilityKey) { MapBuilding.group(store.visibleListings) }
    }
    private var clusters: [MapCluster] {
        clusterMemo.value(for: store.visibilityKey) { MapCluster.group(buildings) }
    }

    private var showsClusters: Bool { zoomBand.showsClusters }

    /// 当前缩放下显示哪些 POI。见 ``MapPOI``。
    private var visiblePointsOfInterest: PointOfInterestCategories {
        MapPOI.categories(visible: zoomBand.showsPOI)
    }

    /// 记下当前跨度；**只有跨过档位时才动界面状态**。见 ``zoomBand``。
    ///
    /// 所有改跨度的地方都走这里（相机回调、+ / −、飞行前的预置），档位的判断
    /// 只有 ``MapZoomBand`` 一处。
    private func setSpan(_ value: CLLocationDegrees) {
        track.span = value
        let band = MapZoomBand(span: value)
        if band != zoomBand { zoomBand = band }
    }

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
                // 可达圈画在标记**下面**：它是底图的一部分，压住 pin 就本末倒置了。
                reachRings
                ForEach(buildings) { building in
                    Annotation("", coordinate: building.coordinate, anchor: .center) {
                        buildingMarker(building)
                    }
                }
            }
        }
        // POI 跟着缩放开关，类目和阈值在包里（``MapPOI``），和 iOS 共用一份。
        //
        // 原先是死的 `.excludingAll`，理由是概览视角下满屏聚类气泡再叠 POI 太吵。
        // 那条理由只在**缩得远**的时候成立：放大到一个城区之后，"楼下有没有超市、
        // 离车站多远"恰恰是这张图能直接回答、而房源数据里没有的东西。
        //
        // 和可达圈是配套的：圈回答"十分钟能到哪儿"，POI 回答"到了那儿有什么"。
        // 只画圈不画 POI，圈里是空的。
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: visiblePointsOfInterest))
        .onMapCameraChange(frequency: .continuous) { context in
            setSpan(context.region.span.latitudeDelta)
            // `MapCameraPosition` 读不出当前 region，+ / − 按钮要拿它算新跨度，
            // 所以每次相机变化都留一份最近值。
            track.region = context.region
            track.camera = context.camera
        }
        // 停下来之后，把落点记成**相机**（中心 + 距离），而不是 region。
        //
        // 这一条修的是"收起侧栏地图会缩放"：`fitAll()` 存进 `camera` 的是
        // `.region(...)`，语义是**"这块经纬度范围要整个可见"**。视图一变宽、长宽比
        // 一变，MapKit 为了让整块范围仍然装得下就会重新缩放——实测收起侧栏后 span
        // 越过 0.5，标记从单套价格整片变成城市团。
        //
        // `.camera(...)` 的语义是"从多高往下看"，`distance` 以米计，和视图宽高无关。
        // 于是变宽只是**露出更多地图**，比例尺一点不动——这才是用户收侧栏时要的。
        //
        // 为什么是 `.onEnd` 不是 `.continuous`：`.continuous` 里往 `camera` 回写会
        // 和 MapKit 自己的更新打架（写一次触发一次变化，再触发一次写）。落定之后写
        // 一次，写进去的就是它当前的位置，不会再动。
        .onMapCameraChange(frequency: .onEnd) { context in
            // **只在当前存的还是 region 时**才转成相机。
            //
            // 已经是相机就别覆盖：尺寸变化的补偿（见下一条）刚把中心写进去，
            // 而这个回调会紧跟着以"补之前的相机"触发一次，无条件写回去正好把补偿
            // 抹掉——实测收 inspector 时补偿完全不生效，就是被这里盖的。
            if camera.region != nil {
                camera = .camera(context.camera)
            }
        }
        // 视图尺寸一变，把相机中心**补回去**，让地图在屏幕上纹丝不动。
        //
        // 上面那条只保住了比例尺，没保住位置：相机中心永远落在**视图的正中**，
        // 而收起侧栏时视图往左长了 195pt，中点跟着往左移了 97pt——同一块地理
        // 因此整体左移 97pt。用户看到的就是"地图偏移了一下"。
        //
        // 补法：中心按**视图中点在屏幕上移动了多少**反向挪回去。设旧中点在屏幕
        // 上是 m、新的是 m′，那么新中心应当取"补之前 m′ 那个位置上的地理"，
        // 也就是 `中心 + (m′ − m) × 每点多少度`。这个式子不关心是哪一侧变的：
        // 侧栏在左、inspector 在右，中点往哪边移就往哪边补。
        //
        // 每点多少度从 `lastRegion` 和**旧尺寸**算：region 的跨度正是那一版视图
        // 装下的范围。纬度方向屏幕向下为正、纬度向下为负，所以那一项取减号。
        .onGeometryChange(for: Bool.self) {
            // 阈值是**工具栏那三个按钮占的宽度**，不是 0。
            //
            // 先写的是 `maxX > windowWidth - 8`，意思是"地图右沿还贴着窗口右边缘"。
            // 稳态没问题，动画中途出事：inspector 滑进来时地图右沿是连续缩回去的，
            // 缩了 10pt 就不算"贴边"了，图例立刻弹到顶——而那三个按钮占着最右边
            // 约 140pt，这时图例正好落在它们底下闪一下。
            //
            // 改成"地图右沿还在按钮那一段里就继续让"，退到按钮左边才归位。
            windowWidth > 0 && $0.frame(in: .global).maxX > windowWidth - Self.toolbarTrailing
        } action: { edge in
            atWindowTrailingEdge = edge
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { old, new in
            // 正在飞就别补：见 ``flyingUntil``。
            if let until = flyingUntil {
                if Date() < until { return }
                flyingUntil = nil
            }
            guard old.width > 1, old.height > 1,
                  let region = track.region, let cam = track.camera else { return }
            let dx = new.midX - old.midX
            let dy = new.midY - old.midY
            // 只有尺寸变化才补。窗口被整体拖动时 frame 也会变，但那种情况下
            // 宽高不变、地图在屏幕上本来就跟着窗口走，补了反而会把地图挪掉。
            guard new.size != old.size, dx != 0 || dy != 0 else { return }
            let degPerPointX = region.span.longitudeDelta / old.width
            let degPerPointY = region.span.latitudeDelta / old.height
            let center = CLLocationCoordinate2D(
                latitude: region.center.latitude - dy * degPerPointY,
                longitude: region.center.longitude + dx * degPerPointX)
            let moved = MapCamera(centerCoordinate: center, distance: cam.distance,
                                  heading: cam.heading, pitch: cam.pitch)
            camera = .camera(moved)

            // **自己的记录要立刻跟上。**
            //
            // 一次开合动画里几何变化是连着来几十次的，每次只差两三个点（实测
            // `1237x816 → 1240x816`）。而 `onMapCameraChange` 不保证在两次之间插
            // 进来——不自己跟上的话，每一步都从**同一个旧中心**出发算偏移，后一步
            // 覆盖前一步，几十步累下来只剩最后那一步的一两个点，看着就是"完全没补"。
            //
            // 收侧栏那次之所以看着是好的，纯属它的 frame 变化恰好一步到位。
            // inspector 那次是逐帧长的，立刻暴露了这个问题。
            track.region = MKCoordinateRegion(center: center, span: region.span)
            track.camera = moved
        }
        // 右上角一摞：图例在上、筛选在下，右对齐。
        //
        // 原来筛选那一排在**左上角**、图例在右上角，两块浮层分踞两头。并到一起是
        // 因为它们是同一类东西——都是"这张图现在给你看的是什么"的说明，而地图本身
        // 才是内容；分在两个角会让眼睛在开头就分两路。
        //
        // 并过来还顺手去掉了一整块复杂度：左上角没有浮层了，就不用再防着交通灯和
        // 侧栏开关（那两个控件在窗口左上角，地图顶到窗口左边缘时会压住浮层）。
        //
        // **贴窗口上沿，不跟随工具栏的安全区。** 地图是满幅的（一直画到窗口顶边），
        // 而 overlay 默认吃工具栏那 51pt 的安全区，浮层会被压到 65pt 处，上面空出
        // 一整条纯地图、什么都不放。
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                legend
                filterTokens
            }
            .padding(14)
            // 右栏一收，地图就顶到窗口右边缘，而那儿是刷新 / 钉住 / 右栏开关三个
            // 工具栏按钮的地盘——这一摞得让开。
            .padding(.top, atWindowTrailingEdge ? Self.toolbarBand : 0)
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .overlay(alignment: .bottom) { noteBanner }
    }

    /// 地图自己要说的那一句话（跳不过去的两种情况）。
    ///
    /// 浮在底部中间、带一个 ✕，不自动消失：这是对"你刚才那个操作为什么没反应"的
    /// 回答，自动消失的话正好错过——用户点完菜单眼睛还在菜单原来的位置上。
    @ViewBuilder
    private var noteBanner: some View {
        if let note = mapNote {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(note)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    mapNote = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 380, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 16)
            .transition(.opacity)
        }
    }

    // MARK: - 可达圈

    /// 选中一栋楼时，在它周围画两个「多久能到」的圈。
    ///
    /// **跟着选中自动画，没有单独的开关。** 右键里再加一个「画可达圈」是多一步：
    /// 你点一栋楼，问的就是"这儿周围是什么样"，圈正是那个问题的答案。
    ///
    /// 两档都取 **10 分钟**：步行 641m、骑车 1923m，和 iOS 那边一样。
    ///
    /// 一度把步行收到 5 分钟（320m），想让内圈落在"楼下这一片"的量级上。
    /// 改回来了——**两个圈的分钟数一样，比较才是一句话**：站在同一个时间预算上，
    /// 走能到哪儿、骑能到哪儿，差的就是那三倍。分钟数不同的话，读者得先在脑子里
    /// 把两个数换算到同一个基准，而这张图本来是用来省掉那一步的。
    ///
    /// 顺带也让两端对齐了：同一套房在 iPhone 和 Mac 上画出来的圈一样大。
    ///
    /// 半径算法和绕路系数在包里（``Reachability``），和 iOS 共用一份。
    /// **这不是等时线**：圆是直线距离，除以 1.3 的绕路系数只是让它保守一点。
    private struct ReachRing: Identifiable {
        let id: String
        let minutes: Int
        let radius: CLLocationDistance
        let symbol: String
        let tint: Color
        /// 外圈画虚线：两个同心圆在这个尺度上相隔很远，实线看着像两个无关的圈；
        /// 虚线一眼就是"边界／大约到这儿"，也把内外层次分开。
        let dashed: Bool
    }

    /// 配色照搬 iOS，理由也一样：`ListingStatus` 已经占了绿（Book）、橙（Lottery）、
    /// 蓝（Reserved）、灰（Occupied）。骑车圈用绿是双重撞车——既撞"可直接预订"
    /// 这个语义，又画在一张大面积是绿地的底图上，低透明度下基本看不见。
    /// 紫色在状态色里没有，在苹果底图的调色板（绿地／灰建筑／白路／蓝水）里也没有。
    ///
    /// 步行那圈用蓝：它和 Reserved 的蓝确实同色系，但两者一个是**面**一个是
    /// 胶囊上的**点**，而且这一圈只在选中时出现——那时注意力本来就在这栋楼上。
    private static let reachRings: [ReachRing] = [
        ReachRing(id: "walk", minutes: 10,
                  radius: Reachability.radius(kmh: Reachability.walkingKmh, minutes: 10),
                  symbol: "figure.walk", tint: .blue, dashed: false),
        ReachRing(id: "cycle", minutes: 10,
                  radius: Reachability.radius(kmh: Reachability.cyclingKmh, minutes: 10),
                  symbol: "bicycle", tint: .purple, dashed: true),
    ]

    /// 外圈半径，米。相机要装得下它，见 ``focusRequestedListing()``。
    static var outerReachRadius: CLLocationDistance {
        reachRings.map(\.radius).max() ?? 0
    }

    @MapContentBuilder
    private var reachRings: some MapContent {
        if let b = model.mapBuilding {
            ForEach(Self.reachRings) { ring in
                MapCircle(center: b.coordinate, radius: ring.radius)
                    // 填充压得很淡：两个圆是同心的，内圈那块会被叠两层。
                    .foregroundStyle(ring.tint.opacity(0.045))
                    .stroke(ring.tint.opacity(0.55),
                            style: StrokeStyle(lineWidth: 2,
                                               dash: ring.dashed ? [10, 7] : []))
            }
            // 圈上的标签。不标的话两个同心圆不表达任何东西——用户看到的只是两个圈，
            // 不知道哪个是走的、哪个是骑的、各代表多久。
            ForEach(Self.reachRings) { ring in
                Annotation("", coordinate: CLLocationCoordinate2D(
                    latitude: Reachability.offsetNorth(latitude: b.coordinate.latitude,
                                                       meters: ring.radius),
                    longitude: b.coordinate.longitude)) {
                    Label("\(ring.minutes) min", systemImage: ring.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ring.tint)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                }
                .annotationTitles(.hidden)
            }
        }
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
        .accessibilityLabel(b.count == 1 ? "\(b.name), \(b.city), 1 listing"
                                         : "\(b.name), \(b.city), \(b.count) listings")
        // 悬停预览：Phase 4 的「地图 pin 划过出卡片」。
        //
        // 卡片走 `.overlay` + `.offset` 浮在标记上方，**不进标记自己的布局**——
        // 塞进 `VStack` 的话，鼠标一划过标记就会被卡片顶得往下跳，而标记的位置
        // 是它唯一的信息。
        .overlay(alignment: .bottom) {
            if hoveredBuilding == b.id, !selected {
                hoverCard(b)
                    // 卡片本身不接鼠标：它盖在标记上方，能接的话鼠标从标记移上去
                    // 会先离开标记 → 卡片消失 → 鼠标又回到标记 → 卡片出现，闪烁。
                    .allowsHitTesting(false)
                    .offset(y: -32)
                    .transition(.opacity)
            }
        }
        .onHover { inside in
            if inside {
                hoveredBuilding = b.id
            } else if hoveredBuilding == b.id {
                hoveredBuilding = nil
            }
        }
        .contextMenu { markerMenu(b) }
    }

    /// 悬停卡：楼盘名、城市、几套、最低价、状态分布。
    ///
    /// 和标记上那一行的分工：标记回答"这儿多少钱"（扫图时看的），卡片回答
    /// "这儿是什么"（停下来看的）。所以卡片上**不重复**价格以外的标记内容，
    /// 而是补标记放不下的那几件事。
    private func hoverCard(_ b: MapBuilding) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(b.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(b.city)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                ForEach(statusBreakdown(b), id: \.status) { part in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Theme.statusColor(part.status))
                            .frame(width: 5, height: 5)
                        Text("\(part.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 200, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        .fixedSize()
    }

    /// 楼里各状态各几套，按业务优先级排（可订在前）。
    private func statusBreakdown(_ b: MapBuilding) -> [(status: ListingStatus, count: Int)] {
        Dictionary(grouping: b.units, by: \.statusKind)
            .map { (status: $0.key, count: $0.value.count) }
            .sorted { $0.status.priority < $1.status.priority }
    }

    /// pin 的右键菜单。Phase 4 的「右键菜单：扩展在地图上定位、画可达圈等操作」。
    ///
    /// **没有「画可达圈」。** 那需要等时圈（isochrone）数据——从一个点出发 15 分钟
    /// 骑车能到哪儿，是一块多边形，不是一个半径。MapKit 只给路线（`MKDirections`），
    /// 算不出等时圈；后端也没有这个接口。画一个"半径 2km 的圆"冒充可达圈是假的：
    /// 阿姆斯特丹到处是运河，直线距离和骑行距离差得很远。宁可不做。
    @ViewBuilder
    private func markerMenu(_ b: MapBuilding) -> some View {
        Button("Zoom to This Building") {
            zoom(to: [b.coordinate], padding: 1)
        }
        Button("Zoom to All") { fitAll() }
        Divider()
        if let unit = b.units.first {
            Button("Open in New Window") {
                openWindow(id: FlatRadarMacApp.listingWindowID, value: unit.id)
            }
            Button("Show in List") { showInList(unit.id) }
            Divider()
            Button("Open on \(Platform.displayName(unit.source))") {
                if let url = URL(string: unit.url) { NSWorkspace.shared.open(url) }
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(unit.url, forType: .string)
            }
            // 走 `MapListing` 那个入口：地图上的这一套不一定在 `/listings` 里，
            // 见 ``ListingShareMenuItem``。
            ListingShareMenuItem(unit: unit)
        }
    }

    /// 从地图跳回列表并选中那一条。
    ///
    /// 可能**跳不过去**：`/map` 和 `/listings` 覆盖的集合不一样（前者是坐标缓存，
    /// 后者套着账号的个人筛选），地图上看得见的不一定在列表里。那就留在地图上
    /// 并说明，不做一次"切过去发现什么都没选中"的空跳。
    private func showInList(_ id: Listing.ID) {
        guard model.listing(id) != nil else {
            mapNote = String(localized: "This listing isn’t in the list — /map and /listings cover different sets, and your saved filter applies to the list.")
            return
        }
        model.focused = id
        model.selection = [id]
        model.section = .listings
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
                showFilters.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11, weight: .medium))
                    Text("All filters").font(.body)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                // 和地图上其它浮层同一种材质。原来这里是实心的 `Theme.ink` + 白字，
                // 在一排玻璃 token 中间像贴了块不透明的纸——而它和旁边那些 token
                // 是同一排、同一件事（筛选），不该是两种材质。
                //
                // `.interactive()` 跟 + / − / Fit 那三个按钮一致：会按下去的用
                // interactive，只是展示的（图例、token）用普通的 `.regular`。
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            // 明写 `.bottom`：按钮挪到右上角之后，不指定的话 SwiftUI 会把浮层朝**上**
            // 弹，直接顶出窗口上沿（按钮离窗口顶只有 180pt，而浮层高 520pt）。
            .popover(isPresented: $showFilters, arrowEdge: .bottom) { filterPopover }
        }
    }

    /// 「All filters」的浮层。
    ///
    /// 地图的筛选**一直是真的**：`MapStore` 上五个条件（城市 / 平台 / 最高租金 /
    /// 最小面积 / 状态）一直在过滤标记，左上角那排 token 也能逐个把它们删掉。
    /// 缺的只是**设**它们的地方——Mac 上一个都没有，token 只能减不能加。
    /// 所以这个浮层不是新功能，是把已经在跑的东西接上一个入口。
    ///
    /// 控件和 iOS 的 `MapFilterSheet` 一一对应（城市 / 平台两个 Picker、
    /// 租金 / 面积两个输入框、状态开关、Reset），因为背后是同一个 store。
    /// 用 popover 而不是像 Listings 那样往下推一块面板：地图是整屏的，
    /// 推一块面板下来会把图挤变形，而浮层从按钮上长出来，关掉就还原。
    private var filterPopover: some View {
        @Bindable var store = store
        return Form {
            Section {
                Picker("City", selection: $store.cityFilter) {
                    Text("All").tag("")
                    ForEach(store.cityOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("Platform", selection: $store.sourceFilter) {
                    Text("All").tag("")
                    ForEach(store.sourceOptions, id: \.self) {
                        Text(Platform.displayName($0)).tag($0)
                    }
                }
            }

            Section {
                LabeledContent("Max rent") {
                    TextField("Any", text: $store.maxRentText)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                LabeledContent("Min area") {
                    TextField("Any", text: $store.minAreaText)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            } footer: {
                // 读不出价格 ≠ 超预算。说清楚，免得用户以为漏了。和 iOS 同一句话。
                Text("Listings whose rent or area cannot be read are kept rather than hidden.")
            }

            Section("Status") {
                ForEach(ListingStatus.byPriority) { status in
                    Toggle(isOn: statusBinding(status)) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Theme.statusColor(status))
                                .frame(width: 7, height: 7)
                            Text(Theme.shortStatusLabel(status) ?? status.label)
                            Spacer(minLength: 8)
                            // 只显示这一档有几套。0 也照显示——"这一档一套都没有"
                            // 和"我把它关掉了"是两件事。
                            Text("\(store.statusCounts[status] ?? 0)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section {
                HStack {
                    // Reset 回**默认**（终态默认关），不是全开——全开是左上角那个
                    // `Status: N` token 的行为，两者语义不同，别混。
                    Button("Reset") { store.resetFilters() }
                    Spacer()
                    Button("Done") { showFilters = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        // 520 是量出来的：两个 Picker + 两个输入框 + 两行脚注 + 五档状态 + 按钮行，
        // 430 的时候正好差一截，浮层里会出现一条滚动条——一个能一眼看完的筛选面板
        // 不该要滚动。状态是固定五档，内容高度不会再涨。
        .frame(width: 300, height: 520)
    }

    private func statusBinding(_ status: ListingStatus) -> Binding<Bool> {
        Binding(
            get: { store.activeStatuses.contains(status) },
            set: { on in
                if on { store.activeStatuses.insert(status) }
                else { store.activeStatuses.remove(status) }
            })
    }

    private func mapToken(_ label: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Text(label).font(.body)
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
    /// 只说**看得见几套房**。
    ///
    /// 原来后面还跟着 `· 12 buildings` / `· 8 cities`——那是"地图上有几个标记"，
    /// 和用户在这一屏想知道的事（有多少套房）不是一回事，而且标记数会随缩放在
    /// 楼盘和城市团之间跳，读起来更像噪音。
    private var rangeText: String {
        "\(buildings.reduce(0) { $0 + $1.count }) shown"
    }

    // MARK: - 动作

    private func load() async {
        guard store.listings.isEmpty else { return }
        await store.fetch()
        fitAll()
    }

    /// 接住列表那边的「Show on Map」：找到这条房源所在的楼，选中并飞过去。
    ///
    /// 找不到就**明说找不到**。地图和列表覆盖的集合不一样（`/map` 是坐标缓存 +
    /// 新鲜度窗口，`/listings` 套着账号的个人筛选），而且地图数据可能还没拉完。
    /// 静悄悄什么都不发生的话，用户只会觉得这个菜单项坏了。
    private func focusRequestedListing() {
        guard let request = model.mapFocusRequest else { return }
        // 数据还没到：不清请求，等 `store` 拉完之后这个 `task(id:)` 会再跑一次。
        guard !store.listings.isEmpty else { return }
        model.clearMapFocusRequest()

        guard let building = buildings.first(where: { b in
            b.units.contains { $0.id == request.id }
        }) else {
            mapNote = String(localized: "This listing has no map position yet — its address hasn’t been geocoded, or it falls outside the map’s freshness window.")
            return
        }
        mapNote = nil
        model.mapBuilding = building
        model.focused = request.id
        // 缩到**装得下外面那个可达圈**，不是装得下这一个点。
        //
        // 「Show on Map」是"带我过去看看这附近"，而选中会自动画出两个圈——
        // 只按点定位的话默认跨度 0.01°（≈1.1km）比骑车 10 分钟那圈（1.92km）还小，
        // 一落地就有半个圈在视野外，看起来像画坏了。
        //
        // 把圈的四个边缘点丢给 `zoom(to:)`，让它已有的包围盒算法去算跨度。
        zoom(to: Self.ringBounds(around: building.coordinate), padding: 1.15)
    }

    /// 外圈的东南西北四个边缘点。喂给 `zoom(to:)` 当包围盒用。
    private static func ringBounds(
        around c: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        let r = outerReachRadius
        let dLat = r / 111_320
        // 经度方向要按纬度收窄：同样的米数在 52°N 上跨的经度更多。
        let dLon = r / (111_320 * cos(c.latitude * .pi / 180))
        return [
            CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude),
            CLLocationCoordinate2D(latitude: c.latitude - dLat, longitude: c.longitude),
            CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude + dLon),
            CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude - dLon),
        ]
    }

    /// 选中一栋楼：inspector 换成这栋楼的单元列表，镜头挪过去。
    private func select(_ b: MapBuilding) {
        model.mapBuilding = b
        // 顺手把焦点落到最值得看的那一套，右栏详情立刻有内容。
        model.focused = b.units.first?.id
        withAnimation(.easeOut(duration: 0.25)) {
            camera = .region(MKCoordinateRegion(center: b.coordinate,
                                                span: MKCoordinateSpan(latitudeDelta: max(track.span, 0.004),
                                                                       longitudeDelta: max(track.span, 0.004))))
        }
    }

    private func scale(by factor: Double) {
        guard let region = track.region else { return }
        // 连点时从**上一下的目标**接着算，不是从动画中间那一帧现读，见 ``zoomTarget``。
        let base: CLLocationDegrees
        if let target = zoomTarget, Date() < target.until {
            base = target.span
        } else {
            base = region.span.latitudeDelta
        }
        let lat = min(max(base * factor, 0.002), 60)
        // 经度按**当前视图的长宽比**同比缩，不各自乘 factor：各乘各的在连点时会把
        // 两个方向的比例越拉越偏（纬度被上下限夹住而经度没有时尤其明显）。
        let ratio = region.span.latitudeDelta > 0
            ? region.span.longitudeDelta / region.span.latitudeDelta : 1
        let s = MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lat * ratio)

        zoomTarget = (lat, Date().addingTimeInterval(0.35))
        // 和 `zoom(to:)` 同理：先把跨度推到目标，免得飞行途中穿过
        // `showsClusters` / POI 的阈值，标记整批换掉把动画掐断在半路。
        setSpan(lat)
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
        // **先把 `span` 推到目标值，再开始动画。**
        //
        // 不这么做的话，飞行途中 `span` 会穿过 `showsClusters` 的 0.5 阈值，
        // `Map` 里那个 `if showsClusters` 就在动画进行中把标记从「城市团」整批换成
        // 「楼盘」——内容一换，MapKit 把正在跑的相机动画**掐断在半路**。
        //
        // 实测：从列表右键「Show on Map」跳过去，落点离目标楼盘约 80pt，中心那儿
        // 一个标记都没有。日志里 `span=1.000000 clusters=1`——`span` 的初值就是 1，
        // 所以刚切到地图屏时画的是城市团，正好每次都撞上这个切换。
        //
        // 反方向（`fitAll` 缩到全局）同样受益：提前切成城市团比在动画途中切更稳，
        // 而且缩出去的过程里本来就该看到团。
        setSpan(s.latitudeDelta)
        // 动画 0.4s，留一点余量让布局也落定。
        flyingUntil = Date().addingTimeInterval(0.7)
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
                                   label: String(localized: "Status: \(store.activeStatuses.count)")) {
                store.showEverything()
            })
        }
        return out
    }

    // MARK: - 空状态

    private func loadFailure(_ message: String) -> some View {
        ContentUnavailableView {
            Label(store.lastError?.errorDescription ?? String(localized: "Unable to Load the Map"),
                  systemImage: store.lastError?.systemImage ?? "wifi.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await store.refresh() } }
        }
    }

    /// 一条带坐标的房源都没有。这时筛选改变不了什么，整屏说明就够了——
    /// 「筛到零条」那种情况不走这里，见 ``MapFilteredOutCard``。
    private var noCoordinates: some View {
        ContentUnavailableView("Nothing on the Map",
                               systemImage: "mappin.slash",
                               description: Text("No listings have coordinates yet."))
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 这一屏画什么

/// 地图屏的四种形态。拆成纯函数是为了能单独测那一条：**有房源、只是被筛光了，
/// 地图不能被换掉**——筛选入口全长在地图的浮层上，地图一换掉就再也回不去。
nonisolated enum MapPaneState: Equatable {
    case loading
    case failed(String)
    /// 一条带坐标的房源都没有，筛选帮不上忙。
    case noCoordinates
    /// 画地图。`filteredOut` = 有房源，但当前筛选一条都没放过。
    case map(filteredOut: Bool)

    static func resolve(isLoading: Bool, errorMessage: String?,
                        hasListings: Bool, hasVisibleBuildings: Bool) -> Self {
        // 已经有数据时，刷新中 / 刷新失败都继续画手上那批，不退回整屏状态。
        if !hasListings {
            if isLoading { return .loading }
            if let errorMessage { return .failed(errorMessage) }
            // 深链兜底的那一条（`focusExtra`）可能让没有列表时也有东西可画。
            return hasVisibleBuildings ? .map(filteredOut: false) : .noCoordinates
        }
        return .map(filteredOut: !hasVisibleBuildings)
    }
}

/// 筛到一套不剩时盖在地图上的那张卡。
///
/// 原因**从实际数据算**（``MapStore/emptyBreakdown``），和 iOS 那张同一个口径：
/// 各状态档各藏了几套，状态之外还有几套是被城市 / 平台 / 租金 / 面积挡掉的。
///
/// 两个按钮对应 store 上两个不同的动作，别混：
/// - **Show All** = 五档状态全开、其余条件全清（``MapStore/showEverything()``）
/// - **Reset Filters** = 回到默认（终态默认关，``MapStore/resetFilters()``），
///   和「All filters」浮层里那个 Reset 是同一个
struct MapFilteredOutCard: View {

    let breakdown: MapStore.EmptyBreakdown
    let onShowEverything: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("No listings match these filters")
                    .font(.headline)
                Text("\(breakdown.total) hidden by the current filters")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if !breakdown.byStatus.isEmpty {
                HStack(spacing: 6) {
                    ForEach(breakdown.byStatus.prefix(3), id: \.status) { item in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Theme.statusColor(item.status))
                                .frame(width: 7, height: 7)
                            Text("\(item.count)")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                            Text(Theme.shortStatusLabel(item.status) ?? item.status.label)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }

            // 状态之外还有别的条件在起作用时才提——不提的话，用户会以为
            // 只要把那几档打开就够了。
            if breakdown.byOtherFilters > 0 {
                Text("\(breakdown.byOtherFilters) more excluded by city, platform, rent or area")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Reset Filters", action: onReset)
                Button("Show All \(breakdown.total)", action: onShowEverything)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 320)
        // 不用玻璃，和 iOS 那张同一个理由：一整张说明卡糊在地图上，玻璃的折射会把
        // 卡片自己的字也搅浑。这里要的是把地图挡住、把字读清楚。
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

// MARK: - 缩放档位

/// 缩放落在哪一档。地图画面随缩放变化的只有这两件事。
///
/// 拆出来是为了让"缩放时要不要重画"有一个能测的答案：同一档里的跨度变化
/// 得到**相等**的档位，``MapPane`` 就不写界面状态、不重算 body。
nonisolated struct MapZoomBand: Equatable {

    /// 缩到多远就改画城市团。
    ///
    /// 判据用**纬度跨度**而不是 Leaflet 那种整数 zoom level：SwiftUI 的
    /// `MapCameraUpdateContext` 给的是 region，没有 zoom level，硬换算要引进
    /// 一堆瓦片数学。0.5° ≈ 55km，正好是"看得见整个兰斯塔德"那一档。
    static let clusterSpan: Double = 0.5

    let showsClusters: Bool
    /// 阈值在包里（``MapPOI``），和 iOS 共用一份。
    ///
    /// 不像 iOS 那样先把跨度量化：那边量化是因为它的 `currentRegion` 本来就按
    /// log2 桶更新（clustering 要用）。**跨度只在缩放时变、平移不变**，所以阈值
    /// 附近不会来回抖。
    let showsPOI: Bool

    init(span: Double) {
        showsClusters = span > Self.clusterSpan
        showsPOI = MapPOI.isVisible(atSpan: span)
    }
}
