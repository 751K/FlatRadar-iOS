import XCTest
@testable import FlatRadarCore

/// ``MapStore/VisibilityKey`` 必须覆盖 ``MapStore/visibleListings`` 的**每一个**输入。
///
/// Mac 地图拿这个键缓存楼盘分组（缩放时每帧重新分组两千条会掉帧）。键漏掉一项，
/// 就是那一项变了而地图不动——比慢更糟，因为看不出来。这里逐项改一遍，每一项都
/// 必须让键变；同时改完之后 `visibleListings` 也确实变了，证明这一项真是输入。
@MainActor
final class MapVisibilityKeyTests: XCTestCase {

    private func listing(_ id: String, status: String = "Available to book",
                         city: String = "Eindhoven", source: String = "holland2stay",
                         price: String = "€1,200", area: String = "50 m²") -> MapListing {
        let dict: [String: Any] = [
            "id": id, "name": "Somestraat \(id)", "status": status,
            "source": source, "price_raw": price, "city": city,
            "neighborhood": "", "building": "", "area": area, "address": "Somestraat \(id)",
            "available_from": "2026-10-01", "url": "https://example.invalid/\(id)",
            "lat": 51.44, "lng": 5.47,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(MapListing.self, from: data)
    }

    private func store() -> MapStore {
        let s = MapStore()
        s.listings = [
            listing("a"),
            listing("b", city: "Amsterdam", source: "xior", price: "€900", area: "20 m²"),
            listing("c", status: "Occupied"),
        ]
        // 显式定下状态档，不靠默认值：c 是被状态挡掉的那一套，
        // 后面「打开 Occupied」和「聚焦 c」两步要靠它才看得出变化。
        s.activeStatuses = [.book]
        return s
    }

    func test_什么都没改_键相等() {
        let s = store()
        XCTAssertEqual(s.visibilityKey, s.visibilityKey)
    }

    func test_每一个输入变了_键都变_可见结果也变() {
        let changes: [(String, (MapStore) -> Void)] = [
            ("listings", { $0.listings.append(self.listing("d")) }),
            ("activeStatuses", { $0.activeStatuses.insert(.occupied) }),
            ("cityFilter", { $0.cityFilter = "Amsterdam" }),
            ("sourceFilter", { $0.sourceFilter = "xior" }),
            ("maxRentText", { $0.maxRentText = "1000" }),
            ("minAreaText", { $0.minAreaText = "30" }),
            ("focusID", { $0.focusID = "c" }),
            ("focusExtra", { $0.focusExtra = self.listing("x") }),
        ]
        for (name, change) in changes {
            let s = store()
            let before = s.visibilityKey
            let visibleBefore = s.visibleListings.map(\.id)
            change(s)
            XCTAssertNotEqual(s.visibilityKey, before, "\(name) 变了，键却没变——地图缓存会停在旧分组上")
            XCTAssertNotEqual(s.visibleListings.map(\.id), visibleBefore,
                              "\(name) 这一步没改变可见结果，这条用例没测到东西")
        }
    }

    func test_房源内容变了_哪怕_id_一样_键也变() {
        // 刷新回来同一批 id、但状态变了：楼盘标记的颜色得跟着变。
        let s = store()
        let before = s.visibilityKey
        s.listings[0] = listing("a", status: "Reserved")
        XCTAssertNotEqual(s.visibilityKey, before)
    }
}
