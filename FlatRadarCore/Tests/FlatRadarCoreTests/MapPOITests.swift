import XCTest
import MapKit
@testable import FlatRadarCore

/// 地图 POI 的类目和阈值。
///
/// 这几条钉的是**产品判断**，不是实现细节：哪几类 POI 和"租不租得下去"有关、
/// 缩到多远就该把它们收起来。两端共用一份之后，改动会同时影响 iPhone 和 Mac，
/// 所以值得写死——尤其是"不含餐饮零售"这一条，它很容易在某次"顺手加一个"里丢掉。
final class MapPOITests: XCTestCase {

    func testKeepsTheThreeCategoriesThatDataCannotAnswer() {
        // 判据：地图能直接回答、而房源数据里没有的三件事。
        XCTAssertEqual(Set(MapPOI.categories),
                       Set([.foodMarket, .publicTransport, .school]))
    }

    func testDoesNotIncludeTheNoisyCategories() {
        // 餐饮 / 咖啡 / 夜生活 / 零售：密度高、和住得下去没关系。
        // `.store` 尤其宽——一放开就把整条商业街铺满，房源标记反而淹了。
        for noisy: MKPointOfInterestCategory in [.restaurant, .cafe, .nightlife, .store] {
            XCTAssertFalse(MapPOI.categories.contains(noisy),
                           "\(noisy) 不该在名单里")
        }
    }

    func testHiddenWhenZoomedOut() {
        // 概览视角下满屏是聚类气泡，叠 POI 就是把"地图太吵"原样请回来。
        XCTAssertFalse(MapPOI.isVisible(atSpan: 0.5))
        XCTAssertFalse(MapPOI.isVisible(atSpan: MapPOI.maxSpan * 1.01))
    }

    func testShownWhenZoomedIn() {
        XCTAssertTrue(MapPOI.isVisible(atSpan: 0.01))
        // 阈值本身算"已经放大到了"。
        XCTAssertTrue(MapPOI.isVisible(atSpan: MapPOI.maxSpan))
    }

    func testThresholdIsAboutOneNeighbourhood() {
        // 0.05° ≈ 5.5km，大约一个城区。这条是为了让"改了阈值"这件事看得见——
        // 改成 0.5 的话 POI 会在整个兰斯塔德视角下就冒出来。
        XCTAssertEqual(MapPOI.maxSpan * 111.32, 5.566, accuracy: 0.01)
    }

    func testTheReachabilityRingFitsInsideThePOIWindow() {
        // Mac 的「Show on Map」会缩到装得下骑车 10 分钟那圈（≈1.9km 半径）。
        // 那个跨度必须落在 POI 的显示窗口里，否则"圈画出来了但圈里是空的"——
        // 而 POI 和可达圈本来就是配套的：圈说能到哪儿，POI 说到了有什么。
        let outer = Reachability.radius(kmh: Reachability.cyclingKmh, minutes: 10)
        let spanNeeded = 2 * outer / 111_320 * 1.15   // 直径 + 15% 留白
        XCTAssertTrue(MapPOI.isVisible(atSpan: spanNeeded),
                      "可达圈的视角比 POI 阈值还远，圈里会是空的")
    }
}
