import XCTest
@testable import FlatRadarMac
@testable import FlatRadarCore

/// 设置页 Filters tab 的维度表（``FilterDimension``）逐行对账。
///
/// 每个维度把四件事绑在一起：后端维度名、候选取自 `FilterOptions` 的哪个字段、
/// 存进 `ListingFilter` 的哪个字段、显示名。前三件写串了**不会有任何报错**——
///
/// - `path` 串了：勾的是「城市」，存进后端的是「街区」，推送从此按错误的条件过滤；
/// - `choices` 串了：「城市」的浮层里列出来的是房型；
/// - `backendKey` 串了：`dim_sources` 查错维度，平台适用范围的提示指到别处。
///
/// 这张表是从 iOS `FilterEditView` 里私有的 `FilterDim` 抄过来的，抄的过程就是出错
/// 的机会。下面按**后端 JSON 键**对账：不信任 Swift 这边任何一个名字，直接看编码
/// 出去 / 解码进来的是哪个键。
final class FilterDimensionTests: XCTestCase {

    /// 后端维度名 → (`/filter/options` 里的键, `/me/filter` 里的键)。
    /// 取自 `FilterOptions.CodingKeys` / `ListingFilter.CodingKeys` 和后端 `dim_sources`。
    private static let expected: [String: (options: String, filter: String)] = [
        "city":         ("cities",        "allowed_cities"),
        "neighborhood": ("neighborhoods", "allowed_neighborhoods"),
        "type":         ("types",         "allowed_types"),
        "finishing":    ("finishing",     "allowed_finishing"),
        "tenant":       ("tenant",        "allowed_tenant"),
        "occupancy":    ("occupancy",     "allowed_occupancy"),
        "contract":     ("contract",      "allowed_contract"),
        "offer":        ("offer",         "allowed_offer"),
    ]

    @MainActor
    func test_八个维度都在且不重名() {
        let keys = FilterDimension.all.map(\.backendKey)
        XCTAssertEqual(Set(keys).count, keys.count, "backendKey 有重复：\(keys)")
        XCTAssertEqual(Set(keys), Set(Self.expected.keys))
    }

    /// 每个 `/filter/options` 数组里只放它**自己的键名**，看每个维度取回来的是谁。
    @MainActor
    func test_候选取自对应的options字段() throws {
        var json: [String: Any] = ["sources": ["sources"], "energy": ["energy"], "dim_sources": [:]]
        for (_, keys) in Self.expected { json[keys.options] = [keys.options] }
        let options = try JSONDecoder().decode(
            FilterOptions.self, from: JSONSerialization.data(withJSONObject: json))

        for dim in FilterDimension.all {
            let want = try XCTUnwrap(Self.expected[dim.backendKey]).options
            XCTAssertEqual(dim.choices(options), [want],
                           "\(dim.backendKey) 的候选取错了字段")
        }
    }

    /// 通过 `path` 写一个记号进 `ListingFilter`，编码成发给后端的 JSON，看记号落在哪个键上。
    @MainActor
    func test_勾选存进对应的filter字段() throws {
        for dim in FilterDimension.all {
            var filter = ListingFilter.empty
            filter[keyPath: dim.path] = ["MARK"]
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(filter)) as? [String: Any])
            let landed = obj.filter { ($0.value as? [String])?.contains("MARK") == true }.map(\.key)

            let want = try XCTUnwrap(Self.expected[dim.backendKey]).filter
            XCTAssertEqual(landed, [want], "\(dim.backendKey) 的勾选会存进 \(landed)")
        }
    }

    /// 两个维度要换显示函数，其余统一。房型剥括号注释那一层不能用在别的维度上
    /// （见 `FeatureText.displayType` 的注释），这里确认没被套到别处。
    @MainActor
    func test_显示函数只在房型和入住人数上特殊() {
        let raw = "2 (bedrooms)"
        for dim in FilterDimension.all {
            switch dim.backendKey {
            case "type":
                XCTAssertEqual(dim.display(raw), FeatureText.displayType(raw))
            case "occupancy":
                XCTAssertEqual(dim.display(raw), FeatureText.displayOccupancy(raw))
            default:
                XCTAssertEqual(dim.display(raw), FeatureText.display(raw), dim.backendKey)
            }
        }
    }

    @MainActor
    func test_只有房型给纯数字补说明() {
        XCTAssertNotNil(FilterDimension.types.hint(["1", "2", "Studio"]))
        XCTAssertNil(FilterDimension.types.hint(["Studio", "Apartment"]))
        XCTAssertNil(FilterDimension.cities.hint(["1", "2"]))
    }
}
