import Foundation

/// 「今天新增了多少，跟平时比是多还是少」那一对数。
///
/// 抽出来是因为它现在有**两个**读者：Mac 的统计带（``SummaryModel``）和桌面
/// 小组件。两处算法哪怕只差一个 `dropLast()`，同一天同一台机器上的两个数字
/// 就会不一样，而两边都"看起来正常"——没有任何一处会喊。
public nonisolated enum DailyNew {

    /// 除去今天之外的日均。
    ///
    /// **刻意排除最后一天**：拿今天去和「含今天的均值」比，今天自己会把基准
    /// 抬上去，涨幅被系统性地压小。
    ///
    /// 样本不足 3 天返回 nil——宁可不显示，也不显示一个没有意义的百分比。
    public static func baselineAverage(_ series: [Int]) -> Int? {
        let past = series.dropLast()
        guard past.count >= 3 else { return nil }
        return Int((Double(past.reduce(0, +)) / Double(past.count)).rounded())
    }

    /// 相对基准的涨跌，例如 `63` 表示 `+63%`。
    ///
    /// 基准为 0 时返回 nil：除以零得不到有意义的百分比，而「从 0 涨到 5」
    /// 写成 `+∞%` 或 `+500%` 都是在编。
    public static func changeVsBaseline(today: Int?, series: [Int]) -> Int? {
        guard let today, let base = baselineAverage(series), base > 0 else { return nil }
        return Int(((Double(today) - Double(base)) / Double(base) * 100).rounded())
    }
}
