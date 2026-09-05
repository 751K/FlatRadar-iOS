import XCTest
@testable import FlatRadar

/// 后端 feature 值的显示形态。
///
/// 守的是同一类错：**把两个不同的后端值显示成同一句话。**
///
/// 房型里 `"Loft (open bedroom area)"` 的括号是平台对户型的补充描述，跟"这是什么
/// 房型"无关，列表上只要 "Loft"。很自然会想把"剥掉尾部括号"做成所有维度通用的
/// 规则——而那是错的：occupancy 的取值里括号是有意义的，剥掉之后
/// `"Two (only couples)"` 会变成 `"Two"`，跟已经存在的 `"Two"` 撞成同一个显示值。
///
/// 这批测试把"按维度剥"这件事钉死：`displayType` 剥，`display` 不剥。
///
/// 取值不是编的，是 2026-09-05 从线上 `/filter/options` 拉下来的实测值。
final class FeatureTextTests: XCTestCase {

    /// 线上 types 的全部取值。
    private static let realTypes = [
        "1", "2", "3", "4",
        "2-room apartment", "3-room apartment",
        "Apartment", "House", "Loft (open bedroom area)", "Studio",
    ]

    /// 线上 occupancy 的全部取值——括号在这里是有意义的。
    private static let realOccupancy = [
        "One", "Two", "Two (only couples)", "Family (parents with children)",
    ]

    // MARK: - displayType 剥括号

    func test_displayType_strips_the_trailing_parenthetical() {
        XCTAssertEqual(FeatureText.displayType("Loft (open bedroom area)"), "Loft")
    }

    func test_displayType_leaves_the_other_real_types_alone() {
        for value in Self.realTypes where !value.contains("(") {
            XCTAssertEqual(FeatureText.displayType(value), value,
                           "\(value) 不带括号，不该被改动")
        }
    }

    func test_displayType_is_idempotent() {
        for value in Self.realTypes {
            let once = FeatureText.displayType(value)
            XCTAssertEqual(FeatureText.displayType(once), once, value)
        }
    }

    /// 剥完之后不能有两个房型显示成同一句话。
    ///
    /// 今天成立（只有 Loft 带括号）。哪天后端加一个 `"Loft (closed bedroom)"`，
    /// 这条会红——那正是该改成显式映射表的信号，而不是把括号还回来。
    func test_displayType_keeps_every_real_type_distinguishable() {
        let shown = Self.realTypes.map(FeatureText.displayType)
        XCTAssertEqual(Set(shown).count, shown.count,
                       "有房型被显示成了同一句话：\(shown)")
    }

    // MARK: - displayOccupancy 换词，不删信息

    /// 括号里那句话是 `"Two (only couples)"` 和 `"Two"` 的**全部区别**——都是两个人，
    /// 一个限定情侣一个不限。所以换个词，而不是把括号删掉。
    func test_displayOccupancy_uses_an_explicit_table() {
        XCTAssertEqual(FeatureText.displayOccupancy("Two (only couples)"), "Couple")
        XCTAssertEqual(FeatureText.displayOccupancy("Family (parents with children)"), "Family")
    }

    func test_displayOccupancy_leaves_the_plain_values_alone() {
        XCTAssertEqual(FeatureText.displayOccupancy("One"), "One")
        XCTAssertEqual(FeatureText.displayOccupancy("Two"), "Two")
    }

    /// 换词之后 `Couple` 和 `Two` 是两个不同的显示值——这正是当初不能机械剥括号
    /// 的那个撞车点，现在被解决掉了。
    func test_displayOccupancy_keeps_every_real_value_distinguishable() {
        let shown = Self.realOccupancy.map(FeatureText.displayOccupancy)
        XCTAssertEqual(Set(shown).count, shown.count,
                       "有 occupancy 被显示成了同一句话：\(shown)")
    }

    func test_displayOccupancy_is_idempotent() {
        for value in Self.realOccupancy {
            let once = FeatureText.displayOccupancy(value)
            XCTAssertEqual(FeatureText.displayOccupancy(once), once, value)
        }
    }

    // MARK: - 通用 display 仍然不剥括号

    /// 通用 display 一旦开始剥括号，任何"括号里才是区别"的维度都会撞车。
    /// occupancy 现在有自己的映射表，但这条规则本身要守住。
    func test_display_does_not_strip_parentheses() {
        XCTAssertEqual(FeatureText.display("Two (only couples)"), "Two (only couples)")
        XCTAssertEqual(FeatureText.display("Family (parents with children)"),
                       "Family (parents with children)")
    }

    // MARK: - 按 key 分发

    func test_display_forKey_routes_to_the_right_rule() {
        XCTAssertEqual(FeatureText.display("Loft (open bedroom area)", forKey: "type"), "Loft")
        XCTAssertEqual(FeatureText.display("Loft (open bedroom area)", forKey: "property type"), "Loft")
        XCTAssertEqual(FeatureText.display("Two (only couples)", forKey: "occupancy"), "Couple")
        XCTAssertEqual(FeatureText.display("Two (only couples)", forKey: "Occupancy"), "Couple")
        // 不认识的 key 退回通用规则
        XCTAssertEqual(FeatureText.display("student only", forKey: "tenant"), "Student only")
        XCTAssertEqual(FeatureText.display("Two (only couples)", forKey: "tenant"),
                       "Two (only couples)")
    }

    // MARK: - display 原有行为不受影响

    func test_display_uppercases_a_lowercase_first_letter() {
        XCTAssertEqual(FeatureText.display("student only"), "Student only")
    }

    func test_display_leaves_values_that_do_not_start_lowercase_alone() {
        for value in ["m²", "21.5 m²", "1-Bedroom", "A+", "XC 1112"] {
            XCTAssertEqual(FeatureText.display(value), value)
        }
    }
}
