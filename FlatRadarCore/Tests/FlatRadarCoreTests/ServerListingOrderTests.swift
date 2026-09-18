import XCTest
@testable import FlatRadarCore

/// ``ServerListingOrder`` 必须和服务端的排序**逐条**一致。
///
/// 下面的夹具不是手写的期望值：它由 `tools/server-sort/make_fixture.py` 生成——那个脚本
/// 从后端仓库取出 `sort_listing_rows` 等几个函数的**源码原文**直接运行，样本专挑规则的
/// 边角（并列、未知值、2050 哨兵、写法变体、码位序）。自己写期望值等于同一个人出题又答题。
///
/// 后端改了排序规则：更新脚本里的 `BACKEND_SHA`，重跑，把输出整段替换进 `fixture`。
final class ServerListingOrderTests: XCTestCase {

    private struct Fixture: Decodable {
        let backend_sha: String
        let listings: [Listing]
        let orders: [String: [String]]
    }

    private func load() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(Self.fixture.utf8))
    }

    func test_十八种排序和后端逐条一致() throws {
        let fx = try load()
        XCTAssertEqual(fx.orders.count, ListingSortKey.allCases.count * 2,
                       "后端的排序键和 ListingSortKey 对不上了")
        for key in ListingSortKey.allCases {
            for ascending in [true, false] {
                let sort = ListingSort(key: key, ascending: ascending)
                let expected = try XCTUnwrap(fx.orders[sort.wireValue], "夹具里没有 \(sort.wireValue)")
                let actual = ServerListingOrder.sorted(fx.listings, by: sort).map(\.id)
                XCTAssertEqual(actual, expected, "sort=\(sort.wireValue) 和服务端的顺序不一样")
            }
        }
    }

    func test_parse_float_和后端的几个例子一致() {
        // 后端 docstring 里的例子，外加几种分隔符组合。
        XCTAssertEqual(ServerListingOrder.parseFloat("€707"), 707)
        XCTAssertEqual(ServerListingOrder.parseFloat("1,200.50"), 1200.5)
        XCTAssertEqual(ServerListingOrder.parseFloat("26.0 m²"), 26)
        XCTAssertEqual(ServerListingOrder.parseFloat("€ 1.587"), 1587)
        XCTAssertEqual(ServerListingOrder.parseFloat("€1.200,50"), 1200.5)
        XCTAssertEqual(ServerListingOrder.parseFloat("45,5 m²"), 45.5)
        XCTAssertEqual(ServerListingOrder.parseFloat("€1.234.567"), 1_234_567)
        XCTAssertNil(ServerListingOrder.parseFloat(""))
        XCTAssertNil(ServerListingOrder.parseFloat("on request"))
    }

    // MARK: - 夹具（make_fixture.py 的输出，勿手改）

    static let fixture = #"""
{
 "backend_sha": "a0ac8c631d6094c73137953904f7d879a84d6a0d",
 "listings": [
  {
   "id": "h2s_10",
   "name": "h2s_10",
   "status": "Available to book",
   "price_raw": "€707",
   "price_value": 707.0,
   "available_from": "2026-10-01",
   "city": "Amsterdam",
   "source": "holland2stay",
   "url": "",
   "features": [
    "Area: 26.0 m²",
    "Energy: A+"
   ],
   "feature_map": {
    "area": "26.0 m²",
    "energy_label": "A+"
   },
   "first_seen": "2026-09-01T10:00:00+00:00",
   "last_seen": "2026-09-10T10:00:00+00:00"
  },
  {
   "id": "h2s_9",
   "name": "h2s_9",
   "status": "available_to_book",
   "price_raw": "€707",
   "price_value": 707.0,
   "available_from": "2026-10-01",
   "city": "amsterdam",
   "source": "holland2stay",
   "url": "",
   "features": [
    "Area: 26 m²",
    "Energy: a+"
   ],
   "feature_map": {
    "area": "26 m²",
    "energy_label": "a+"
   },
   "first_seen": "2026-09-01T10:00:00+00:00",
   "last_seen": "2026-09-11T10:00:00+00:00"
  },
  {
   "id": "xr_2",
   "name": "xr_2",
   "status": "Available in lottery",
   "price_raw": "€1.587",
   "price_value": 1587.0,
   "available_from": "2050-01-01",
   "city": "Utrecht",
   "source": "xior",
   "url": "",
   "features": [
    "Area: 87.28 m²",
    "Energy: A+++"
   ],
   "feature_map": {
    "area": "87.28 m²",
    "energy_label": "A+++"
   },
   "first_seen": "2026-08-01T09:00:00+00:00",
   "last_seen": ""
  },
  {
   "id": "xr_10",
   "name": "xr_10",
   "status": "To be in lottery",
   "price_raw": "€ 1.587",
   "price_value": 1587.0,
   "available_from": "",
   "city": " Utrecht",
   "source": "xior",
   "url": "",
   "features": [
    "Area: 9 m²",
    "Energy: B"
   ],
   "feature_map": {
    "area": "9 m²",
    "energy_label": "B"
   },
   "first_seen": "",
   "last_seen": "2026-09-12T08:00:00+00:00"
  },
  {
   "id": "A1",
   "name": "A1",
   "status": "Reserved",
   "price_raw": "on request",
   "price_value": null,
   "available_from": "2099-12-31",
   "city": "Den Haag",
   "source": "ourdomain",
   "url": "",
   "features": [
    "Area: 0 m²",
    "Energy: G"
   ],
   "feature_map": {
    "area": "0 m²",
    "energy_label": "G"
   },
   "first_seen": "2026-07-15T00:00:00+00:00",
   "last_seen": "2026-09-01T00:00:00+00:00"
  },
  {
   "id": "a1",
   "name": "a1",
   "status": "Occupied",
   "price_raw": "",
   "price_value": null,
   "available_from": "2026-09-15",
   "city": "den haag",
   "source": "ourdomain",
   "url": "",
   "features": [
    "Energy: A++"
   ],
   "feature_map": {
    "energy_label": "A++"
   },
   "first_seen": "2026-07-15T00:00:00+00:00",
   "last_seen": "2026-09-01T00:00:00+00:00"
  },
  {
   "id": "b7",
   "name": "b7",
   "status": "Rented",
   "price_raw": "€1,200.50",
   "price_value": 1200.5,
   "available_from": "2027-01-01",
   "city": "Zürich",
   "source": "holland2stay",
   "url": "",
   "features": [
    "Area: 45,5 m²"
   ],
   "feature_map": {
    "area": "45,5 m²"
   },
   "first_seen": "2026-09-02T00:00:00+00:00",
   "last_seen": "2026-09-02T00:00:00+00:00"
  },
  {
   "id": "b8",
   "name": "b8",
   "status": "Not available",
   "price_raw": "€1.200,50",
   "price_value": 1200.5,
   "available_from": "2026-12-24",
   "city": "zwolle",
   "source": "vestide",
   "url": "",
   "features": [
    "Area: 45.5 m²",
    "Energy: C"
   ],
   "feature_map": {
    "area": "45.5 m²",
    "energy_label": "C"
   },
   "first_seen": "2026-09-03T00:00:00+00:00",
   "last_seen": "2026-09-03T00:00:00+00:00"
  },
  {
   "id": "c3",
   "name": "c3",
   "status": "Something else",
   "price_raw": "1,5",
   "price_value": 1.5,
   "available_from": "2026-10-01",
   "city": "",
   "source": "vestide",
   "url": "",
   "features": [
    "Energy: A"
   ],
   "feature_map": {
    "energy_label": "A"
   },
   "first_seen": "2026-09-03T00:00:00+00:00",
   "last_seen": "2026-09-04T00:00:00+00:00"
  },
  {
   "id": "c30",
   "name": "c30",
   "status": "",
   "price_raw": "€1.234.567",
   "price_value": 1234567.0,
   "available_from": "  2026-10-02  ",
   "city": "Eindhoven",
   "source": "xior",
   "url": "",
   "features": [
    "Area: 1.234 m²",
    "Energy: F"
   ],
   "feature_map": {
    "area": "1.234 m²",
    "energy_label": "F"
   },
   "first_seen": "2026-09-04T00:00:00+00:00",
   "last_seen": "2026-09-05T00:00:00+00:00"
  },
  {
   "id": "d4",
   "name": "d4",
   "status": "Available to book",
   "price_raw": "€0",
   "price_value": 0.0,
   "available_from": "2051-06-01",
   "city": "Eindhoven",
   "source": "holland2stay",
   "url": "",
   "features": [
    "Area: 30 m²",
    "Energy: E"
   ],
   "feature_map": {
    "area": "30 m²",
    "energy_label": "E"
   },
   "first_seen": "2026-09-04T00:00:00+00:00",
   "last_seen": "2026-09-05T00:00:00+00:00"
  },
  {
   "id": "d40",
   "name": "d40",
   "status": "RESERVED",
   "price_raw": "€950",
   "price_value": 950.0,
   "available_from": "2026-11-01",
   "city": "Rotterdam",
   "source": "holland2stay",
   "url": "",
   "features": [
    "Area: 30.0 m²",
    "Energy: D"
   ],
   "feature_map": {
    "area": "30.0 m²",
    "energy_label": "D"
   },
   "first_seen": "2026-09-05T00:00:00+00:00",
   "last_seen": ""
  },
  {
   "id": "e5",
   "name": "e5",
   "status": "Available in lottery",
   "price_raw": "€950",
   "price_value": 950.0,
   "available_from": "2026-11-01",
   "city": "rotterdam",
   "source": "vestide",
   "url": "",
   "features": [
    "Area: 30 m²",
    "Energy: A+++"
   ],
   "feature_map": {
    "area": "30 m²",
    "energy_label": "A+++"
   },
   "first_seen": "2026-09-05T00:00:00+00:00",
   "last_seen": "2026-09-06T00:00:00+00:00"
  },
  {
   "id": "Z9",
   "name": "Z9",
   "status": "Occupied",
   "price_raw": "€12",
   "price_value": 12.0,
   "available_from": "20",
   "city": "Rotterdam",
   "source": "xior",
   "url": "",
   "features": [
    "Area: 120 m²",
    "Energy: A++"
   ],
   "feature_map": {
    "area": "120 m²",
    "energy_label": "A++"
   },
   "first_seen": "2026-09-06T00:00:00+00:00",
   "last_seen": "2026-09-06T00:00:00+00:00"
  }
 ],
 "orders": {
  "price": [
   "d4",
   "c3",
   "Z9",
   "h2s_10",
   "h2s_9",
   "d40",
   "e5",
   "b7",
   "b8",
   "xr_10",
   "xr_2",
   "c30",
   "A1",
   "a1"
  ],
  "-price": [
   "c30",
   "xr_10",
   "xr_2",
   "b7",
   "b8",
   "d40",
   "e5",
   "h2s_10",
   "h2s_9",
   "Z9",
   "c3",
   "d4",
   "A1",
   "a1"
  ],
  "area": [
   "xr_10",
   "h2s_10",
   "h2s_9",
   "d4",
   "d40",
   "e5",
   "b7",
   "b8",
   "xr_2",
   "Z9",
   "c30",
   "A1",
   "a1",
   "c3"
  ],
  "-area": [
   "c30",
   "Z9",
   "xr_2",
   "b7",
   "b8",
   "d4",
   "d40",
   "e5",
   "h2s_10",
   "h2s_9",
   "xr_10",
   "A1",
   "a1",
   "c3"
  ],
  "energy": [
   "e5",
   "xr_2",
   "Z9",
   "a1",
   "h2s_10",
   "h2s_9",
   "c3",
   "xr_10",
   "b8",
   "d40",
   "d4",
   "c30",
   "A1",
   "b7"
  ],
  "-energy": [
   "c30",
   "d4",
   "d40",
   "b8",
   "xr_10",
   "c3",
   "h2s_10",
   "h2s_9",
   "Z9",
   "a1",
   "e5",
   "xr_2",
   "A1",
   "b7"
  ],
  "first_seen": [
   "A1",
   "a1",
   "xr_2",
   "h2s_10",
   "h2s_9",
   "b7",
   "b8",
   "c3",
   "c30",
   "d4",
   "d40",
   "e5",
   "Z9",
   "xr_10"
  ],
  "-first_seen": [
   "Z9",
   "d40",
   "e5",
   "c30",
   "d4",
   "b8",
   "c3",
   "b7",
   "h2s_10",
   "h2s_9",
   "xr_2",
   "A1",
   "a1",
   "xr_10"
  ],
  "last_seen": [
   "A1",
   "a1",
   "b7",
   "b8",
   "c3",
   "c30",
   "d4",
   "Z9",
   "e5",
   "h2s_10",
   "h2s_9",
   "xr_10",
   "d40",
   "xr_2"
  ],
  "-last_seen": [
   "xr_10",
   "h2s_9",
   "h2s_10",
   "Z9",
   "e5",
   "c30",
   "d4",
   "c3",
   "b8",
   "b7",
   "A1",
   "a1",
   "d40",
   "xr_2"
  ],
  "available_from": [
   "Z9",
   "a1",
   "c3",
   "h2s_10",
   "h2s_9",
   "c30",
   "d40",
   "e5",
   "b8",
   "b7",
   "A1",
   "d4",
   "xr_10",
   "xr_2"
  ],
  "-available_from": [
   "b7",
   "b8",
   "d40",
   "e5",
   "c30",
   "c3",
   "h2s_10",
   "h2s_9",
   "a1",
   "Z9",
   "A1",
   "d4",
   "xr_10",
   "xr_2"
  ],
  "city": [
   "h2s_10",
   "h2s_9",
   "A1",
   "a1",
   "c30",
   "d4",
   "Z9",
   "d40",
   "e5",
   "xr_10",
   "xr_2",
   "b8",
   "b7",
   "c3"
  ],
  "-city": [
   "b7",
   "b8",
   "xr_10",
   "xr_2",
   "Z9",
   "d40",
   "e5",
   "c30",
   "d4",
   "A1",
   "a1",
   "h2s_10",
   "h2s_9",
   "c3"
  ],
  "status": [
   "d4",
   "h2s_10",
   "h2s_9",
   "e5",
   "xr_10",
   "xr_2",
   "A1",
   "d40",
   "Z9",
   "a1",
   "b7",
   "b8",
   "c3",
   "c30"
  ],
  "-status": [
   "c3",
   "c30",
   "Z9",
   "a1",
   "b7",
   "b8",
   "A1",
   "d40",
   "e5",
   "xr_10",
   "xr_2",
   "d4",
   "h2s_10",
   "h2s_9"
  ],
  "source": [
   "b7",
   "d4",
   "d40",
   "h2s_10",
   "h2s_9",
   "A1",
   "a1",
   "b8",
   "c3",
   "e5",
   "Z9",
   "c30",
   "xr_10",
   "xr_2"
  ],
  "-source": [
   "Z9",
   "c30",
   "xr_10",
   "xr_2",
   "b8",
   "c3",
   "e5",
   "A1",
   "a1",
   "b7",
   "d4",
   "d40",
   "h2s_10",
   "h2s_9"
  ]
 }
}
"""#
}
