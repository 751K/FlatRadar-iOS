import XCTest
@testable import FlatRadarCore

/// 房源下面那行「地点」。
///
/// 这个文件是**跟着搬家一起补的**——`PlaceSummary` 在 iOS app 里待了很久，
/// 一条测试都没有。搬进包之后它多了一个调用方（Mac 的详情标题），而那边原来
/// 的实现更弱，等于行为变了，更该钉住。
final class PlaceSummaryTests: XCTestCase {

    func testDropsWordsAlreadyInTheName() {
        // 文件头那个原始例子：整串比较会全部放行，因为
        // "OurCampus Diemen #3250" 和 "OurCampus Amsterdam Diemen" 互不包含。
        // 按词看才对：OurCampus 和 Diemen 名字里已经有，真正新的只有 Amsterdam。
        XCTAssertEqual(
            PlaceSummary.text(name: "OurCampus Diemen #3250",
                              parts: ["OurCampus Amsterdam Diemen",
                                      "OurCampus Amsterdam Diemen"]),
            "Amsterdam")
    }

    func testDropsDuplicatePartsAmongThemselves() {
        // Xior 实测：157R 的 city 和 building 是同一个串。
        XCTAssertEqual(
            PlaceSummary.text(name: "157R",
                              parts: ["Amsterdam Naritaweg", "Amsterdam Naritaweg"]),
            "Amsterdam Naritaweg")
    }

    func testKeepsOrderOfParts() {
        XCTAssertEqual(
            PlaceSummary.text(name: "Some Flat", parts: ["Twin 3", "Amsterdam"]),
            "Twin 3 · Amsterdam")
        XCTAssertEqual(
            PlaceSummary.text(name: "Some Flat", parts: ["Amsterdam", "Twin 3"]),
            "Amsterdam · Twin 3")
    }

    func testSkipsEmptyParts() {
        // 调用方常常传一个可能为空的字段（`buildingText ?? ""`），
        // 空串不能变成一个孤零零的 " · "。
        XCTAssertEqual(
            PlaceSummary.text(name: "Some Flat", parts: ["Amsterdam", ""]),
            "Amsterdam")
        XCTAssertEqual(
            PlaceSummary.text(name: "Some Flat", parts: ["", ""]),
            nil)
    }

    func testReturnsNilWhenEverythingIsRedundant() {
        // 全被名字包含 → 整行不画，而不是画一个空串。
        XCTAssertNil(PlaceSummary.text(name: "Amsterdam Naritaweg 155L",
                                       parts: ["Amsterdam Naritaweg"]))
    }

    func testIgnoresPureNumbersAndSingleCharacters() {
        // 门牌号和 "#" 不承载地点信息，拿它们判重只会误伤：
        // 名字里的 "3250" 不该让片段里的 "3250 Amsterdam" 丢掉 Amsterdam。
        XCTAssertEqual(
            PlaceSummary.text(name: "Flat 3250", parts: ["3250 Amsterdam"]),
            "3250 Amsterdam")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertNil(PlaceSummary.text(name: "AMSTERDAM Naritaweg",
                                       parts: ["amsterdam naritaweg"]))
    }

    func testKeepsTheNewWordsOnlyWithinAPart() {
        // 一个片段里既有重复词也有新词时，只留新的那几个——不是整段留下、
        // 也不是整段丢掉。
        XCTAssertEqual(
            PlaceSummary.text(name: "Kon. Wilhelminaplein 29 F6",
                              parts: ["Wilhelminaplein WFC Lofts"]),
            "WFC Lofts")
    }
}
