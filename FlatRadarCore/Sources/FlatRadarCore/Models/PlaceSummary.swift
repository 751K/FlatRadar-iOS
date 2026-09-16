import Foundation

/// 房源下方那行「地点」文字。
///
/// 为什么需要它
/// ------------
/// 各平台往 city / building / neighborhood 里塞的东西不一致：OurCampus 的
/// `city` 和 `building` 都是 "OurCampus Amsterdam Diemen"，而房源名是
/// "OurCampus Diemen #3250"。照原样并排的结果是同一件事被念三遍：
///
///     OurCampus Diemen #3250
///     OurCampus Amsterdam Diemen · OurCampus Amsterdam Diemen
///
/// 三道过滤：空的去掉、重复的去掉、已经被标题包含的去掉。
///
/// **只有一份实现。** 原先在 iOS app 里（`FlatRadar/Views/PlaceSummary.swift`），
/// 用它的是地图弹卡、日历行、Dashboard 的卡。2026-09-16 提进包，因为 Mac 又写了
/// 第四份——`ListingText.subtitle`，而且更弱：只比了 city 和 building，**没跟房源名
/// 比**，于是 OurCampus 那类数据在 Mac 上照样把同一件事念两遍。
///
/// 这正是这个文件原来那句注释警告的事（"同一段逻辑写两遍、只改一处"），
/// 而它自己也没拦住——因为它当时只在 iOS target 里，Mac 根本看不见。
/// 放进包里才是真的只有一份。
public nonisolated enum PlaceSummary {

    /// - Parameters:
    ///   - name: 房源名，用来判断哪些部分是重复的。
    ///   - parts: 候选片段，按想要的先后顺序传入（如 `[building, city]`）。
    /// - Returns: 用 " · " 连接的地点串；没有值得显示的内容时返回 nil。
    public static func text(name: String, parts: [String]) -> String? {
        var used = Set(matchable(name).map { $0.lowercased() })
        var kept: [String] = []

        for raw in parts {
            // **按词过滤，不是整串比较。**
            //
            // 截图里的实例：标题 "OurCampus Diemen #3250"、片段
            // "OurCampus Amsterdam Diemen"——两串**互不包含**，整串比较会全部
            // 放行，于是同一件事念三遍。按词看就清楚了：OurCampus 和 Diemen
            // 标题里已经有，真正新的只有 Amsterdam。
            var words: [String] = []
            var freshCount = 0
            for token in allTokens(of: raw) {
                guard isMatchable(token) else {
                    // 纯数字 / 单字符**照抄**，不参与判重也不被丢掉，见下。
                    words.append(token)
                    continue
                }
                let key = token.lowercased()
                if used.contains(key) { continue }
                used.insert(key)
                freshCount += 1
                words.append(token)
            }
            // 判据是"有没有**新的实词**"。只剩门牌号之类的话这一段不值得显示。
            guard freshCount > 0 else { continue }
            kept.append(words.joined(separator: " "))
        }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }

    /// 切词，不做任何过滤。
    private static func allTokens(of text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// 这个词能不能拿来判重。
    ///
    /// 纯数字和单字符不行——门牌号、"#" 之类不承载地点信息，拿它们判重只会误伤。
    private static func isMatchable(_ token: String) -> Bool {
        token.count > 1 && !token.allSatisfy(\.isNumber)
    }

    private static func matchable(_ text: String) -> [String] {
        allTokens(of: text).filter(isMatchable)
    }
}

// MARK: - 一个搬家时才发现的 bug
//
// 上面那句"纯数字不参与判重"原先是这么实现的：切词时**直接把它们滤掉**，
// 然后用滤剩的词拼出结果。于是数字不只是不参与判重，**还从输出里消失了**：
//
//     PlaceSummary.text(name: "Some Flat", parts: ["Twin 3", "Amsterdam"])
//     → "Twin · Amsterdam"          ← 楼栋名的那个 3 没了
//
// 注释写的是"拿它们**判重**只会误伤"，一个字都没提要从输出里删掉——实现比
// 注释多做了一件事，而那件事是错的。
//
// 这个 bug 在 iOS 上躺了很久没人发现：地图和日历传的是 `[neighborhood, city]`，
// 这两个字段里基本没有数字。搬进包、Mac 的详情标题开始传 `building` 之后才露出来
// ——右栏本来显示 "Amsterdam · Twin 3"，接上之后会变成 "Amsterdam · Twin"。
//
// 现在分成两件事：`isMatchable` 决定谁能参与判重，输出照抄原词。
