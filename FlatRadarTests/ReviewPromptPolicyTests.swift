import XCTest
@testable import FlatRadar

/// 评分引导的时机判断。
///
/// 为什么这条判断值得单独测
/// ------------------------
/// `requestReview` 每 365 天最多真正弹 3 次，而且**调用方看不到有没有弹出来**。
/// 所以这段逻辑写错了不会报错、不会崩、日志里也看不出来——表现只是「用户莫名
/// 其妙被打扰」或者「一年白问三次」，两种都要等上架很久才可能被发现。
///
/// 它又恰好是纯函数（``ReviewPromptState`` 是值类型），所以能钉死。
final class ReviewPromptPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 一个各项门槛都刚好满足的基线，测试里按需破坏其中一项。
    private func eligible(
        activeDays: Int = 3,
        listingOpens: Int = 5,
        hasNotifications: Bool = true,
        lastPromptedAt: Date? = nil,
        lastPromptedVersion: String? = nil,
        currentVersion: String = "2.1.0"
    ) -> ReviewPromptState {
        ReviewPromptState(
            activeDays: activeDays,
            listingOpens: listingOpens,
            hasNotifications: hasNotifications,
            lastPromptedAt: lastPromptedAt,
            lastPromptedVersion: lastPromptedVersion,
            currentVersion: currentVersion)
    }

    private func ask(_ s: ReviewPromptState,
                     _ t: ReviewPromptPolicy.Trigger = .listingClosed) -> Bool {
        ReviewPromptPolicy.shouldAsk(s, trigger: t, now: now)
    }

    // MARK: - 门槛

    func testAsksWhenEveryThresholdIsMet() {
        XCTAssertTrue(ask(eligible()))
    }

    /// 三条门槛**各自**都要能单独挡住——只测「全满足会问」的话，某一条被写成
    /// 恒真也发现不了。
    func testEachThresholdAloneBlocks() {
        XCTAssertFalse(ask(eligible(activeDays: 2)), "用了不到 3 天不该问")
        XCTAssertFalse(ask(eligible(listingOpens: 4)), "看了不到 5 条不该问")
        XCTAssertFalse(ask(eligible(hasNotifications: false)), "没开通知不该问")
    }

    // MARK: - 去重

    func testSameVersionAsksOnlyOnce() {
        XCTAssertFalse(ask(eligible(lastPromptedVersion: "2.1.0")))
    }

    /// 换了版本要能重新问——「这一版变好了」本身就是重新征求意见的理由。
    /// 但冷却期仍然要过。
    func testNewVersionCanAskAgainAfterCooldown() {
        let old = now.addingTimeInterval(-200 * 86_400)
        XCTAssertTrue(ask(eligible(lastPromptedAt: old, lastPromptedVersion: "2.0.0")))
    }

    func testCooldownBlocksEvenAcrossVersions() {
        let recent = now.addingTimeInterval(-30 * 86_400)
        XCTAssertFalse(ask(eligible(lastPromptedAt: recent, lastPromptedVersion: "2.0.0")),
                       "距上次才 30 天，换了版本也不该问")
    }

    /// 边界两侧各钉一个：119 天不行、121 天可以。只测中间值的话，把 `<` 写成
    /// `<=`（或者天数搞错一个数量级）都测不出来。
    func testCooldownBoundary() {
        let v = "2.0.0"
        let justUnder = now.addingTimeInterval(-(ReviewPromptPolicy.cooldownDays - 1) * 86_400)
        let justOver = now.addingTimeInterval(-(ReviewPromptPolicy.cooldownDays + 1) * 86_400)
        XCTAssertFalse(ask(eligible(lastPromptedAt: justUnder, lastPromptedVersion: v)))
        XCTAssertTrue(ask(eligible(lastPromptedAt: justOver, lastPromptedVersion: v)))
    }

    // MARK: - 打赏那一路

    /// 打赏成功不看使用门槛——已经掏钱了，比任何启发式都准。
    func testTipIgnoresUsageThresholds() {
        let cold = eligible(activeDays: 0, listingOpens: 0, hasNotifications: false)
        XCTAssertFalse(ask(cold, .listingClosed))
        XCTAssertTrue(ask(cold, .tipCompleted))
    }

    /// 但**去重仍然管它**。不然打赏两次就问两次，而系统一年只给三次机会。
    func testTipStillRespectsDedupe() {
        XCTAssertFalse(ask(eligible(lastPromptedVersion: "2.1.0"), .tipCompleted))
        let recent = now.addingTimeInterval(-30 * 86_400)
        XCTAssertFalse(ask(eligible(lastPromptedAt: recent, lastPromptedVersion: "2.0.0"),
                           .tipCompleted))
    }

    // MARK: - 首次运行

    /// 全新用户什么都没有：两个计数是 0，两个「上次问过」是 nil。
    /// 这条守的是「nil 被当成很久以前，于是第一天就问」。
    func testBrandNewUserIsNotAsked() {
        XCTAssertFalse(ask(eligible(activeDays: 1, listingOpens: 0, hasNotifications: false)))
    }
}
