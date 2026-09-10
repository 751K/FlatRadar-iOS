import XCTest
@testable import FlatRadarCore

/// 价格串解析。
///
/// 这条路径上一个 bug 的代价是**一千倍**：`"€ 1.152"` 如果按"只留数字和点"
/// 解析成 1.152，地图上那栋楼会被涂成「under €600」，而它实际是 €1152。
/// 所以每一种平台写法都钉一条。
final class PriceTextTests: XCTestCase {

    /// 逗号分位（Holland2Stay 实测写法）。
    func testCommaThousands() {
        XCTAssertEqual(PriceText.parse("€1,067"), 1067)
        XCTAssertEqual(PriceText.parse("1,067"), 1067)
    }

    /// **点**分位（OurDomain 实测写法）。就是这条让"只留数字和点"的写法出错。
    func testDotThousands() {
        XCTAssertEqual(PriceText.parse("€ 1.152"), 1152)
        XCTAssertEqual(PriceText.parse("€ 1.647"), 1647)
    }

    /// 没有分隔符。
    func testPlain() {
        XCTAssertEqual(PriceText.parse("€407"), 407)
        XCTAssertEqual(PriceText.parse("900"), 900)
    }

    /// 带小数：两种分隔符同时出现时，**靠后的那个**是小数点。
    func testDecimals() {
        XCTAssertEqual(PriceText.parse("€1.067,50"), 1067.5)   // 欧陆
        XCTAssertEqual(PriceText.parse("€1,067.50"), 1067.5)   // 英美
    }

    /// 只有一个分隔符且后面不是三位 → 当小数点。
    func testSingleSeparatorAsDecimal() {
        XCTAssertEqual(PriceText.parse("12,5"), 12.5)
        XCTAssertEqual(PriceText.parse("12.5"), 12.5)
    }

    /// 多级分位：只有最后一个分隔符可能是小数点，前面的一律丢掉。
    func testMultipleGroupSeparators() {
        XCTAssertEqual(PriceText.parse("1.234.567"), 1_234_567)
        XCTAssertEqual(PriceText.parse("1,234,567"), 1_234_567)
    }

    /// 后缀和货币符号不影响结果。
    func testStripsNoise() {
        XCTAssertEqual(PriceText.parse("€ 1.152 per month"), 1152)
        XCTAssertEqual(PriceText.parse("EUR 850,-"), 850)
    }

    /// 解析不出来返回 nil，**不是 0**。
    ///
    /// 返回 0 的话「不知道多少钱」会静默落进"最便宜"那一档——
    /// 又是一次把「不知道」当成确定答案。
    func testUnparseableIsNilNotZero() {
        XCTAssertNil(PriceText.parse(nil))
        XCTAssertNil(PriceText.parse(""))
        XCTAssertNil(PriceText.parse("On request"))
        XCTAssertNil(PriceText.parse("—"))
    }

    // MARK: - compact

    /// 各平台的写法差得很远，`compact` 的意义就是把它们归一成同一个样子。
    /// 原样截断的话同一列里会同时出现三种格式。
    func test_compact把各平台的写法归一成同一个样子() {
        // 不带千位分隔符——和列表的 Price 列、详情的 `€1980 / mo` 保持一致。
        // 设计稿写的是 `€1,180`，但同一列里两种格式比没有逗号糟。
        XCTAssertEqual(PriceText.compact("€ 1.067,50 p/m"), "€1068")
        XCTAssertEqual(PriceText.compact("€1,067.50"), "€1068")
        XCTAssertEqual(PriceText.compact("1067.5"), "€1068")
        XCTAssertEqual(PriceText.compact("€452"), "€452")
    }

    /// 解析不出来时返回 nil，**不返回 "€0"**——那是在编一个数字。
    func test_compact解析不出来时返回nil() {
        XCTAssertNil(PriceText.compact("n.v.t."))
        XCTAssertNil(PriceText.compact(""))
        XCTAssertNil(PriceText.compact(nil))
    }
}
