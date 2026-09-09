import XCTest
@testable import FlatRadarCore

/// `sort` 的线格式必须跟后端 openapi 的 enum 逐字对上。
///
/// 为什么把字符串钉死
/// ----------------
/// `ListingSortKey` 里有一半的 case 用的是**隐式** raw value（`case price` →
/// `"price"`）。把 `price` 改名成 `rent` 之类，Swift 编译照过，线上却开始发
/// `sort=rent` —— 后端 1.23.0 对未知值返回 400（这是它有意的设计，不静默回退），
/// 于是列表页整个空掉。编译期没有任何东西能拦住这个改名。
///
/// 2026-09-09 用真实后端逐值验过：这 18 个全部 200，`name` / `-name` 是 400
/// （后端 enum 里没有 name），所以 `ListingSortOption.name` 那一项在 iOS 上
/// 仍然是本地排序。
final class ListingSortTests: XCTestCase {

    /// 后端 openapi 1.23.0 `GET /listings` 的 `sort` enum，原样抄下来。
    private static let contractValues: Set<String> = [
        "price", "-price",
        "area", "-area",
        "energy", "-energy",
        "first_seen", "-first_seen",
        "last_seen", "-last_seen",
        "available_from", "-available_from",
        "city", "-city",
        "status", "-status",
        "source", "-source",
    ]

    func testEveryKeyProducesBothDirectionsInTheContract() {
        var produced: Set<String> = []
        for key in ListingSortKey.allCases {
            produced.insert(ListingSort(key: key, ascending: true).wireValue)
            produced.insert(ListingSort(key: key, ascending: false).wireValue)
        }
        XCTAssertEqual(produced, Self.contractValues,
                       "客户端能产生的 sort 值与后端 enum 不一致；"
                       + "多出来的会被 400，少掉的是丢了功能")
    }

    func testDescendingUsesLeadingMinus() {
        XCTAssertEqual(ListingSort(key: .price, ascending: true).wireValue, "price")
        XCTAssertEqual(ListingSort(key: .price, ascending: false).wireValue, "-price")
    }

    /// 不传 `sort` 时后端用 `-first_seen`，且这是写进契约的默认值。
    /// 客户端的默认必须和它一致，否则「不传」和「传默认」两条路会给出不同顺序。
    func testDefaultMatchesTheServerDefault() {
        XCTAssertEqual(ListingSort.newestFirst.wireValue, "-first_seen")
    }

    /// 逗号形式后端保留给将来的多键排序，当前会 400——所以任何单个值都不该含逗号。
    func testNoWireValueContainsAComma() {
        for key in ListingSortKey.allCases {
            XCTAssertFalse(ListingSort(key: key, ascending: true).wireValue.contains(","))
        }
    }
}
