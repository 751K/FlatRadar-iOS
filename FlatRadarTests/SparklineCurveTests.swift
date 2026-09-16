import XCTest
import SwiftUI
@testable import FlatRadar

/// 曲线插值：**不许画出数据里没有的峰谷**。
///
/// 这条线画的是「每天新增几套」。普通的 Catmull-Rom 样条会过冲——两个相等的值
/// 之间会鼓一个包，鼓出来的那个高度对应一个**从来没发生过的数字**。上一版 iOS
/// 是靠"把控制点夹回画布"挡这件事，那个夹子只管画布边界，框内的鼓包夹不到。
///
/// 单调三次 Hermite（Fritsch–Carlson）的性质保证：每一段的控制点都落在这一段两个
/// 端点的 y 之间，于是曲线不会越过这一段的数据范围。下面直接验这条性质。
///
/// 两端（FlatRadarMacTests/SparklineCurveTests）有一份一模一样的测试。改了一边没改另一边，这里会红。
final class SparklineCurveTests: XCTestCase {

    /// 数据故意造了一个"平段夹在两侧落差里"的形状：
    /// 索引 1、2 都是 5，左边是 1、右边是 1，再右边跳到 9。
    /// Catmull-Rom 会在这两个 5 之间鼓出一个包；单调插值不会。
    private static let data = [1, 5, 5, 1, 9]
    private static let rect = CGRect(x: 0, y: 0, width: 100, height: 50)

    private func segments(_ path: Path) -> [(from: CGPoint, c1: CGPoint, c2: CGPoint, to: CGPoint)] {
        var out: [(from: CGPoint, c1: CGPoint, c2: CGPoint, to: CGPoint)] = []
        var current = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let to):
                current = to
            case .line(let to):
                current = to
            case .quadCurve(let to, _):
                current = to
            case .curve(let to, let c1, let c2):
                out.append((current, c1, c2, to))
                current = to
            case .closeSubpath:
                break
            }
        }
        return out
    }

    func test_每段都是三次贝塞尔且段数对得上() {
        let segs = segments(Sparkline(data: Self.data).path(in: Self.rect))
        XCTAssertEqual(segs.count, Self.data.count - 1)
    }

    /// 核心断言：控制点不许跑到这一段两个端点之外。
    func test_控制点不越出本段的数据范围() {
        for (i, seg) in segments(Sparkline(data: Self.data).path(in: Self.rect)).enumerated() {
            let lo = min(seg.from.y, seg.to.y) - 1e-6
            let hi = max(seg.from.y, seg.to.y) + 1e-6
            XCTAssertTrue((lo...hi).contains(seg.c1.y),
                          "第 \(i) 段的 c1 越界：\(seg.c1.y) 不在 \(lo)…\(hi)")
            XCTAssertTrue((lo...hi).contains(seg.c2.y),
                          "第 \(i) 段的 c2 越界：\(seg.c2.y) 不在 \(lo)…\(hi)")
        }
    }

    /// 两个相等的值之间必须是**直的**。这一条是 Catmull-Rom 唯一过不去的地方，
    /// 也是"夹回画布"那个补丁挡不住的地方。
    func test_相等的两天之间是平的() {
        let flat = segments(Sparkline(data: Self.data).path(in: Self.rect)).filter { abs($0.from.y - $0.to.y) < 1e-6 }
        XCTAssertEqual(flat.count, 1, "测试数据应当恰好有一个平段")
        let seg = try? XCTUnwrap(flat.first)
        guard let seg else { return }
        XCTAssertEqual(seg.c1.y, seg.from.y, accuracy: 1e-6, "平段鼓包了")
        XCTAssertEqual(seg.c2.y, seg.to.y, accuracy: 1e-6, "平段鼓包了")
    }

    /// 顺带钉住上下余量：和另一端一样是 4。
    func test_上下余量是4() {
        let ys = segments(Sparkline(data: Self.data).path(in: Self.rect)).flatMap { [$0.from.y, $0.to.y] }
        XCTAssertEqual(ys.min() ?? 0, 4, accuracy: 1e-6)
        XCTAssertEqual(ys.max() ?? 0, Self.rect.height - 4, accuracy: 1e-6)
    }
}
