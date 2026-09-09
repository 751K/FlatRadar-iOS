import XCTest
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import FlatRadarCore

/// 包资源必须真的能从 `Bundle.module` 查到。
///
/// 为什么值得一条测试
/// ------------------
/// `Color("Status/Book", bundle: .module)` 查不到资源时**不报错**：SwiftUI 静默
/// 返回一个默认颜色，编译绿、测试绿、界面上是黑的。2026-09-09 把语义色从
/// `FlatRadar/Assets.xcassets` 搬进包资源时，只要 `Package.swift` 的
/// `resources:` 漏了一行，或者 catalog 路径写错，就是这个下场——而且要等到
/// 有人盯着房源卡片看才会发现。
///
/// 本地化同理：`String(localized:bundle:)` 查不到就回退成 key 本身（英文），
/// 非英文用户看到中英混排。`tests/test_localizations.py` 只检查目录里**有没有
/// 译文**，检查不了运行时能不能**读到**。这条补的是后半截。
final class PackageResourcesTests: XCTestCase {

    /// `Color+Tokens.swift` 里的 8 个语义色。名字写死——它们就是契约。
    private static let colorNames = [
        "Status/Book", "Status/Lottery", "Status/Occupied",
        "Status/Reserved", "Status/Unknown",
        "Energy/Top", "Energy/APlus", "Energy/A",
    ]

    func testSemanticColorsResolveFromPackageBundle() throws {
        for name in Self.colorNames {
            #if canImport(UIKit)
            let found = UIColor(named: name, in: .module, compatibleWith: nil)
            #elseif canImport(AppKit)
            let found = NSColor(named: name, bundle: .module)
            #else
            let found: Any? = nil
            #endif
            XCTAssertNotNil(found, "语义色 \(name) 不在包资源里——界面上会静默变黑")
        }
    }

    func testLocalizedStringsResolveFromPackageBundle() {
        // APIError 的标题，五种语言都配了译文。查不到时 NSLocalizedString 返回
        // key 本身，所以这里断言「不等于 key」不成立（en 的译文就等于 key），
        // 改成断言 zh-Hans 能拿到跟 key 不同的值。
        let bundle = Bundle.module
        guard let path = bundle.path(forResource: "zh-Hans", ofType: "lproj"),
              let zh = Bundle(path: path) else {
            return XCTFail("包里没有 zh-Hans.lproj —— 中文文案会整体回退成英文")
        }
        let value = zh.localizedString(forKey: "Login Failed", value: nil, table: nil)
        XCTAssertNotEqual(value, "Login Failed",
                          "zh-Hans 没读到译文，说明包的本地化资源没打进去")
    }

    func testAllFiveLocalizationsArePackaged() {
        for lang in ["en", "es", "nl", "zh-Hans", "zh-Hant"] {
            XCTAssertNotNil(Bundle.module.path(forResource: lang, ofType: "lproj"),
                            "包里缺 \(lang).lproj")
        }
    }
}
