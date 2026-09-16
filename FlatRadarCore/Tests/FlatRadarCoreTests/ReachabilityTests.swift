import XCTest
@testable import FlatRadarCore

/// 可达圈半径。
///
/// 这几条钉住的是**从 iOS 搬过来时数值没变**。原来的注释里写死了两个结果
/// （10 分钟步行 ≈ 640m、10 分钟骑车 ≈ 1920m），搬家最容易出的错就是系数位置
/// 放错——`× 1.3` 和 `÷ 1.3` 都能跑，但圈会差 69%。
final class ReachabilityTests: XCTestCase {

    func testWalkingTenMinutesMatchesTheDocumentedValue() {
        // 5 km/h = 83.3 m/min，除以绕路系数 1.3 → 64.1 m/min，10 分钟 ≈ 641m。
        XCTAssertEqual(Reachability.radius(kmh: Reachability.walkingKmh, minutes: 10),
                       641, accuracy: 1)
    }

    func testCyclingTenMinutesMatchesTheDocumentedValue() {
        // 15 km/h = 250 m/min，除以 1.3 → 192.3 m/min，10 分钟 ≈ 1923m。
        XCTAssertEqual(Reachability.radius(kmh: Reachability.cyclingKmh, minutes: 10),
                       1923, accuracy: 1)
    }

    func testBothRingsUseTheSameMinuteBudget() {
        // 两端画的都是「步行 10 分钟 / 骑车 10 分钟」：同一个时间预算下，
        // 骑车能到的地方正好是走路的三倍远。这个 3 倍就是 15÷5——绕路系数
        // 对两者是同一个数，所以它在比值里被约掉了。
        let walk = Reachability.radius(kmh: Reachability.walkingKmh, minutes: 10)
        let cycle = Reachability.radius(kmh: Reachability.cyclingKmh, minutes: 10)
        XCTAssertEqual(walk, 641, accuracy: 1)
        XCTAssertEqual(cycle, 1923, accuracy: 1)
        XCTAssertEqual(cycle / walk, 3, accuracy: 0.001)
    }

    func testDetourFactorShrinksTheCircle() {
        // 系数放错边（乘而不是除）会让圈**变大** 69%。这一条就是那个方向的哨兵：
        // 有绕路校正的半径必须比"速度 × 时间"的裸值小。
        let naive = Reachability.walkingKmh * 1000 / 60 * 10
        let corrected = Reachability.radius(kmh: Reachability.walkingKmh, minutes: 10)
        XCTAssertLessThan(corrected, naive)
        XCTAssertEqual(corrected * Reachability.detourFactor, naive, accuracy: 0.001)
    }

    func testRadiusScalesLinearlyWithMinutes() {
        let five = Reachability.radius(kmh: Reachability.walkingKmh, minutes: 5)
        let ten = Reachability.radius(kmh: Reachability.walkingKmh, minutes: 10)
        XCTAssertEqual(ten, five * 2, accuracy: 0.001)
    }

    func testOffsetNorthMovesLatitudeOnly() {
        // 1 度纬度 ≈ 111.32km，所以 1113.2m ≈ 0.01 度。
        let moved = Reachability.offsetNorth(latitude: 52.37, meters: 1113.2)
        XCTAssertEqual(moved, 52.38, accuracy: 0.0001)
    }

    func testOffsetNorthIsExactlyTheLabelRadius() {
        // 标签要正好落在圈顶上：往北挪的距离必须等于半径。
        let r = Reachability.radius(kmh: Reachability.cyclingKmh, minutes: 10)
        let lat = Reachability.offsetNorth(latitude: 52.0, meters: r)
        XCTAssertEqual((lat - 52.0) * 111_320, r, accuracy: 0.001)
    }
}
