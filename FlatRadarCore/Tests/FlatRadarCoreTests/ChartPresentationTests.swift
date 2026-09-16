import XCTest
@testable import FlatRadarCore

/// 统计图的排序和上色。
///
/// 最要紧的一条是**有序的维度不许按数量重排**——那条轴本身在传达"从低到高"，
/// 重排之后价格分布会变成一串乱序的区间，而且**看起来完全正常**，
/// 不会崩、不会空，只是读出来的结论是错的。
final class ChartPresentationTests: XCTestCase {

    // MARK: - 轴

    func testTimeAxisKeys() {
        for key in ["daily_new", "daily_changes", "hourly_dist"] {
            XCTAssertEqual(ChartPresentation.axis(for: key), .time, key)
        }
    }

    func testOrderedAxisKeys() {
        for key in ["price_dist", "area_dist", "floor_dist", "energy_dist", "status_dist"] {
            XCTAssertEqual(ChartPresentation.axis(for: key), .ordered, key)
        }
    }

    func testCategoricalAxisKeys() {
        for key in ["city_dist", "source_dist", "type_dist", "tenant_dist"] {
            XCTAssertEqual(ChartPresentation.axis(for: key), .categorical, key)
        }
    }

    // MARK: - 形状和排序是两个问题

    func testStatusIsOrderedButStillDrawnAsHorizontalBars() {
        // 这一条是第一版的 bug 现场：`Axis` 一个枚举同时管排序和形状，
        // 撞在 `status_dist` 上——它要"别重排"（有业务顺序），但要横条
        // （标签是 `Available to book` 这种名字）。合在一起改对一个就改坏另一个。
        XCTAssertEqual(ChartPresentation.axis(for: "status_dist"), .ordered)
        XCTAssertEqual(ChartPresentation.shape(for: "status_dist"), .horizontalBars)
    }

    func testShapeFollowsWhetherLabelsAreNames() {
        // 名字 → 横条
        for key in ["city_dist", "source_dist", "type_dist", "tenant_dist", "status_dist"] {
            XCTAssertEqual(ChartPresentation.shape(for: key), .horizontalBars, key)
        }
        // 区间 / 等级 / 时间 → 竖柱
        for key in ["price_dist", "area_dist", "floor_dist", "energy_dist",
                    "daily_new", "daily_changes", "hourly_dist"] {
            XCTAssertEqual(ChartPresentation.shape(for: key), .verticalBars, key)
        }
    }

    func testUnknownKeyIsCategorical() {
        // 后端以后加了新 key，默认按数量排是安全的猜测——看得懂，只是可能
        // 不是最佳。默认成"有序"才危险：它会保留一个我们没理解的顺序。
        XCTAssertEqual(ChartPresentation.axis(for: "something_new"), .categorical)
    }

    // MARK: - 排序

    func testPriceBucketsKeepTheirOrder() {
        // 线上实测的那一组（days=30）。按数量排会变成
        // €1000-1200, €1200-1400, €1400-1600, >€1600, €800-900 …
        let raw = [
            ChartEntry(label: "<€600", count: 0),
            ChartEntry(label: "€600-700", count: 0),
            ChartEntry(label: "€700-800", count: 26),
            ChartEntry(label: "€800-900", count: 45),
            ChartEntry(label: "€900-1000", count: 38),
            ChartEntry(label: "€1000-1200", count: 85),
            ChartEntry(label: "€1200-1400", count: 55),
            ChartEntry(label: "€1400-1600", count: 52),
            ChartEntry(label: ">€1600", count: 46),
        ]
        XCTAssertEqual(ChartPresentation.display(raw, forKey: "price_dist").map(\.label),
                       raw.map(\.label))
    }

    func testAreaAndFloorKeepTheirOrder() {
        let area = [
            ChartEntry(label: "<20 m²", count: 69),
            ChartEntry(label: "20-30 m²", count: 131),
            ChartEntry(label: "30-50 m²", count: 67),
            ChartEntry(label: "50-80 m²", count: 73),
            ChartEntry(label: ">80 m²", count: 7),
        ]
        XCTAssertEqual(ChartPresentation.display(area, forKey: "area_dist").map(\.label),
                       area.map(\.label))
    }

    func testTimeSeriesKeepsChronologicalOrder() {
        let days = [
            ChartEntry(label: "2026-09-15", count: 21),
            ChartEntry(label: "2026-09-16", count: 4),
            ChartEntry(label: "2026-09-17", count: 0),
        ]
        XCTAssertEqual(ChartPresentation.display(days, forKey: "daily_new").map(\.label),
                       days.map(\.label))
    }

    func testCategoricalIsSortedByCount() {
        let cities = [
            ChartEntry(label: "Utrecht", count: 38),
            ChartEntry(label: "Eindhoven", count: 119),
            ChartEntry(label: "Amsterdam", count: 66),
        ]
        XCTAssertEqual(ChartPresentation.display(cities, forKey: "city_dist").map(\.label),
                       ["Eindhoven", "Amsterdam", "Utrecht"])
    }

    func testTypeIsBucketedThenSorted() {
        // 线上原始数据里 `"1"` / `"2"` 是"几居"，要先合并成 Apt 才谈得上顺序。
        let raw = [
            ChartEntry(label: "Studio", count: 184),
            ChartEntry(label: "studio", count: 26),
            ChartEntry(label: "Loft (open bedroom area)", count: 31),
            ChartEntry(label: "1", count: 55),
            ChartEntry(label: "2", count: 13),
        ]
        let shown = ChartPresentation.display(raw, forKey: "type_dist")
        XCTAssertEqual(shown.map(\.label), ["Studio", "Apt", "Loft"])
        XCTAssertEqual(shown.map(\.count), [210, 68, 31])
    }

    func testEnergyIsBucketedAndStaysInGradeOrder() {
        // A++++ / A++ / A+ 合并成 A+，然后 A → G。**不按数量排**。
        let raw = [
            ChartEntry(label: "A++++", count: 11),
            ChartEntry(label: "A++", count: 12),
            ChartEntry(label: "A+", count: 24),
            ChartEntry(label: "A", count: 56),
            ChartEntry(label: "B", count: 11),
            ChartEntry(label: "C", count: 10),
        ]
        let shown = ChartPresentation.display(raw, forKey: "energy_dist")
        XCTAssertEqual(shown.map(\.label), ["A+", "A", "B", "C"])
        XCTAssertEqual(shown.first?.count, 47, "A++++ + A++ + A+ 要合成一桶")
    }

    func testStatusMergesLabelsThatMeanTheSameThing() {
        // 线上原始数据：后端发的是平台原话，`Occupied` 和 `Not available`
        // 是两条，但 `ListingStatus.from` 把它们都归到 `.occupied`。
        //
        // **不合并的后果是看不见的**：图上会出现两条都叫 Occupied 的柱子，
        // Swift Charts 按分类值定位，两条落在同一格互相盖住——实测 281 被 30
        // 盖掉，卡上显示的是小的那个。不报错、不空白，只是数字错了。
        let raw = [
            ChartEntry(label: "Occupied", count: 281),
            ChartEntry(label: "Not available", count: 30),
            ChartEntry(label: "Available to book", count: 17),
            ChartEntry(label: "Reserved", count: 14),
            ChartEntry(label: "Available in lottery", count: 5),
        ]
        let shown = ChartPresentation.display(raw, forKey: "status_dist")
        XCTAssertEqual(shown.count, 4, "Occupied 和 Not available 要合成一条")
        let occupied = shown.first { $0.label == "Occupied" }
        XCTAssertEqual(occupied?.count, 311, "281 + 30")
    }

    func testStatusIsOrderedByBusinessPriorityNotCount() {
        // 这一列的读法是"从最值得看的到最不值得看的"：能订的排最前，
        // 哪怕它只有 17 条而 Occupied 有 311。
        let raw = [
            ChartEntry(label: "Occupied", count: 311),
            ChartEntry(label: "Available to book", count: 17),
            ChartEntry(label: "Reserved", count: 14),
            ChartEntry(label: "Available in lottery", count: 5),
        ]
        XCTAssertEqual(ChartPresentation.display(raw, forKey: "status_dist").map(\.label),
                       ["Available to book", "Available in lottery", "Reserved", "Occupied"])
    }

    func testMergedStatusLabelsStillShortenForTheAxis() {
        // 合并出来的是标准写法，轴上还要再缩一次——两件事分开做，
        // 见 `statusBucketLabel` 的注释。
        XCTAssertEqual(ChartPresentation.shortLabel("Available to book", forKey: "status_dist"),
                       "Book")
    }

    // MARK: - 颜色

    func testStatusUsesTheStatusTokens() {
        // 图里的颜色必须和状态胶囊一致——用户是靠颜色认出它们的。
        XCTAssertEqual(ChartPresentation.color(forKey: "status_dist", label: "Available to book"),
                       ListingStatus.book.color)
        XCTAssertEqual(ChartPresentation.color(forKey: "status_dist", label: "Occupied"),
                       ListingStatus.occupied.color)
    }

    func testSourceUsesThePlatformColors() {
        // docs/DESIGN.md §1.2：「一个平台在任何页面、**任何图表**、任何排序下
        // 都是同一个颜色」。
        XCTAssertEqual(ChartPresentation.color(forKey: "source_dist", label: "holland2stay"),
                       Platform.color("holland2stay"))
        XCTAssertEqual(ChartPresentation.color(forKey: "source_dist", label: "xior"),
                       Platform.color("xior"))
    }

    func testChartsWithoutSemanticColorsReturnNil() {
        // 城市、房型、价格没有"属于自己的颜色"，交给图表的默认色。
        for key in ["city_dist", "type_dist", "price_dist", "daily_new"] {
            XCTAssertNil(ChartPresentation.color(forKey: key, label: "whatever"), key)
        }
    }

    func testEnergyRankOrdersGrades() {
        XCTAssertEqual(ChartPresentation.energyRank("A+++"), 0)
        XCTAssertEqual(ChartPresentation.energyRank("A++"), 1)
        XCTAssertEqual(ChartPresentation.energyRank("A+"), 2)
        XCTAssertEqual(ChartPresentation.energyRank("A"), 3)
        XCTAssertEqual(ChartPresentation.energyRank("B"), 4)
        XCTAssertEqual(ChartPresentation.energyRank("G"), 9)
        XCTAssertEqual(ChartPresentation.energyRank("???"), 99)
    }

    func testEnergyColorsAreDistinctAcrossGrades() {
        // 一张条形图的职责就是把档次区分开。全一个色等于没画。
        let colors = ["A+", "A", "B", "C", "D"].compactMap {
            ChartPresentation.color(forKey: "energy_dist", label: $0)
        }
        XCTAssertEqual(colors.count, 5)
        XCTAssertEqual(Set(colors.map { "\($0)" }).count, 5, "五个档次给了重复的颜色")
    }

    // MARK: - 轴上排不排得下

    /// 这几条锁的是**判断的方向**，不是那个 5.5pt 的估算有多准。
    ///
    /// 现场是这样的：`price_dist` 九个区间在一张 320pt 宽的卡里并排画出来，
    /// 实拍是 `<€600€600-70€700-800…` 糊成一条。所以规则必须在价格上说
    /// "放不下"，而在只有 `Ground` / `1-2` / `3-5` / `6+` 的楼层上说"放得下"。
    /// 两头搞反了比估不准糟得多：多标是一整条读不出来的糊带。
    func testNinePriceBucketsDoNotFitANarrowColumn() {
        let labels = ["<€600", "€600-700", "€700-800", "€800-900", "€900-1000",
                      "€1000-1200", "€1200-1400", "€1400-1600", ">€1600"]
        XCTAssertFalse(ChartPresentation.axisLabelsFit(labels, within: 250))
    }

    func testShortOrderedLabelsFit() {
        // 楼层四档、能效五档——这些是**必须**标出来的，全关掉就只剩两个端点，
        // 而 `Ground … 6+` 这种两头没什么信息量。
        XCTAssertTrue(ChartPresentation.axisLabelsFit(["Ground", "1-2", "3-5", "6+"], within: 250))
        XCTAssertTrue(ChartPresentation.axisLabelsFit(["A+", "A", "B", "C", "D"], within: 250))
        XCTAssertTrue(ChartPresentation.axisLabelsFit(
            ["<20 m²", "20-30 m²", "30-50 m²", "50-80 m²", ">80 m²"], within: 250))
    }

    func testFitCountsTotalWidthNotHowManyLabels() {
        // 条数一样、长度不同，结论就该不同。这条是"按字符数不按条数"的底线：
        // 若哪天改成"超过 N 条就关轴"，这一条会红。
        let short = ["a", "b", "c", "d"]
        let long = ["€1000-1200", "€1200-1400", "€1400-1600", "€1600-1800"]
        XCTAssertTrue(ChartPresentation.axisLabelsFit(short, within: 100))
        XCTAssertFalse(ChartPresentation.axisLabelsFit(long, within: 100))
    }

    func testNoLabelsAlwaysFit() {
        // 空的图不该被判成"放不下"然后掉进端点分支——那分支会读 first/last，
        // 空数组上画出来是两个空 `Text`。
        XCTAssertTrue(ChartPresentation.axisLabelsFit([], within: 0))
    }

    // MARK: - 标签

    func testDateLabelsAreShortened() {
        // 完整日期在轴上排不下。
        XCTAssertEqual(ChartPresentation.shortLabel("2026-09-17", forKey: "daily_new"), "09-17")
    }

    func testHourLabelsGetAClockShape() {
        XCTAssertEqual(ChartPresentation.shortLabel("3", forKey: "hourly_dist"), "03:00")
        XCTAssertEqual(ChartPresentation.shortLabel("23", forKey: "hourly_dist"), "23:00")
    }

    func testStatusLabelsAreShortened() {
        // "Available to book" 在一根柱子下面必被截断。
        XCTAssertEqual(ChartPresentation.shortLabel("Available to book", forKey: "status_dist"),
                       "Book")
        XCTAssertEqual(ChartPresentation.shortLabel("Available in lottery", forKey: "status_dist"),
                       "Lottery")
    }

    func testOtherLabelsPassThrough() {
        XCTAssertEqual(ChartPresentation.shortLabel("Eindhoven", forKey: "city_dist"), "Eindhoven")
    }
}
