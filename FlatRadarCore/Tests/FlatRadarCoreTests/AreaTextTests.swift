import XCTest
@testable import FlatRadarCore

/// 面积和价格是同一个病根：后端给的是**平台原样字符串**，各平台写法不一套。
/// 原样显示的话同一列里会同时出现 `22,56 m²` 和 `33.78 m²`。
final class AreaTextTests: XCTestCase {

    /// OurDomain 用荷兰式逗号小数点。
    func test_逗号小数点统一成点() {
        XCTAssertEqual(AreaText.normalized("22,56 m²"), "22.56 m²")
        XCTAssertEqual(AreaText.normalized("29,3"), "29.3m²")
    }

    /// 本来就是英美写法的、以及整数，一个字符都不许动。
    func test_本来就对的不动() {
        XCTAssertEqual(AreaText.normalized("33.78 m²"), "33.78 m²")
        XCTAssertEqual(AreaText.normalized("28 m²"), "28 m²")
        XCTAssertEqual(AreaText.normalized("65"), "65m²")
    }

    /// 逗号后正好三位数字是**分位符**不是小数点，换成点会把 1067 变成 1.067。
    /// 面积不会有四位数，这条是防御——但防御失效的后果是差一千倍。
    func test_三位数字后的逗号当分位符不动() {
        XCTAssertEqual(AreaText.dotDecimalSeparator("1,067"), "1,067")
        XCTAssertEqual(AreaText.dotDecimalSeparator("22,56"), "22.56")
    }

    /// 空串和 nil 返回 nil，调用方据此显示「缺」，而不是显示一个孤零零的 "m²"。
    func test_空的返回nil() {
        XCTAssertNil(AreaText.normalized(nil))
        XCTAssertNil(AreaText.normalized(""))
        XCTAssertNil(AreaText.normalized("   "))
    }
}
