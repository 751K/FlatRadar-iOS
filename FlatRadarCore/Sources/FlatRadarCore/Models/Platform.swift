import SwiftUI

/// 平台（source）显示名——**全 App 唯一一份**。
///
/// 为什么单独抽出来
/// ----------------
/// 收拢之前，这份映射在七个文件里各写了一遍：`MapListing`、`CalendarListing`、
/// `Listing`、`ListingFilter`、`ChartData`、`ListingsView`（两处）、
/// `FilterEditView`。七份没有一份是全的——最好的认得 3 个平台，地图那份只认得
/// 2 个，而后端有 7 个。于是 OurCampus / Magis / Student Experience / Plaza
/// 在界面上一路显示成 `OURCAMPUS` `MAGIS` `STUDENTEXPERIENCE` `PLAZA`
/// （把 source key 直接大写）。
///
/// 这不是会崩的那种错，是**每接一个新平台就悄悄多一处**的错：加平台的人改了
/// 后端和一两个显眼的地方，剩下五处要等有人截图才会发现。
///
/// 与后端的对应
/// ------------
/// 与 `static/app.js` 的 `SOURCE_LABELS` / `SOURCE_SHORT`、以及
/// `notifier.py` 的 `_source_short` 对齐。新增平台时三处一起加。
public nonisolated enum Platform {

    /// 全名，用于卡片、徽章、筛选器选项。
    private static let displayNames: [String: String] = [
        "holland2stay": "Holland2Stay",
        "ourdomain": "OurDomain",
        "ourcampus": "OurCampus",
        "xior": "Xior",
        "magis": "Magis",
        "studentexperience": "Student Experience",
        "plaza": "Plaza",
    ]

    /// 缩写，用于图表坐标轴和空间紧张的徽章（放全名会挤成一团）。
    private static let shortNames: [String: String] = [
        "holland2stay": "H2S",
        "ourdomain": "OD",
        "ourcampus": "OC",
        "xior": "XR",
        "magis": "MG",
        "studentexperience": "SE",
        "plaza": "PZ",
    ]

    /// 已登记的平台 key，按显示名排序。
    public static var knownKeys: [String] {
        displayNames.keys.sorted { displayNames[$0]! < displayNames[$1]! }
    }

    /// 登录屏上那排平台缩写的顺序。
    ///
    /// **不是** ``knownKeys``：那份按显示名的字母排，H2S 会掉到 MG / OC 后面去。
    /// 登录屏是用户第一眼看到的东西，设计稿（Mac / iPad 两份都是）把体量大的放
    /// 前面——先让人认出自己已经在用的那家。
    ///
    /// 放在包里而不是各端各写一份：Mac 的 `SignInPane` 和 iOS 的 `LoginView` 用的
    /// 是同一个顺序，抄两份迟早有一份在加第八个平台时被忘掉。这个文件开头那段
    /// 注释讲的就是这件事——收拢之前同一份映射在七个文件里各写了一遍，没有一份是全的。
    ///
    /// 只列已登记的；``knownKeys`` 里有而这里没有的，会被追加在末尾。
    public static var featuredOrder: [String] {
        let featured = ["holland2stay", "ourdomain", "ourcampus",
                        "xior", "magis", "studentexperience", "plaza"]
        let known = Set(knownKeys)
        return featured.filter(known.contains) + knownKeys.filter { !featured.contains($0) }
    }

    /// 平台全名。
    ///
    /// 认不出的 key **不套一个默认平台名**——把未知 source 显示成
    /// "Holland2Stay" 会让人以为数据是那边来的。退回一个可读的转写：
    /// `some_new_site` → `Some New Site`。
    public static func displayName(_ source: String?) -> String {
        let key = normalize(source)
        if key.isEmpty { return "Platform" }
        return displayNames[key] ?? titleCased(key)
    }

    /// 平台缩写。认不出时退回前三个字母大写，而不是整段大写——
    /// `STUDENTEXPERIENCE` 会把徽章撑变形。
    public static func shortName(_ source: String?) -> String {
        let key = normalize(source)
        if key.isEmpty { return "PLT" }
        if let s = shortNames[key] { return s }
        return String(key.prefix(3)).uppercased()
    }

    /// 每个平台一个**稳定**的颜色。
    ///
    /// 图表原先用 `palette[idx % 3]`——三个平台时够用，接到七个之后颜色开始重复，
    /// 堆叠条上相邻两段可能同色，图例和条形也对不上号。按平台取色之后，同一个
    /// 平台在任何图表、任何排序下都是同一个颜色。
    ///
    /// 刻意避开 statusBook / statusLottery 那套语义色：那几个表示"能不能租"，
    /// 用在平台上会让人误读。
    public static func color(_ source: String?) -> Color {
        switch resolveKey(source) {
        // 前三个沿用界面上原有的取值，不动——徽标的颜色是用户已经认熟的东西，
        // 为了"配一套新色"把它们换掉，代价比收益大。
        case "holland2stay":      return .blue
        case "ourdomain":         return .purple
        case "xior":              return .teal
        // 后四个此前全部落到 default 的蓝色，和 H2S 撞在一起——等于没有颜色。
        // OurCampus 与 OurDomain 同属一家，取相邻的 indigo，既能区分又能看出亲缘。
        case "ourcampus":         return .indigo
        case "magis":             return .pink
        case "studentexperience": return .orange
        case "plaza":             return .brown
        default:                  return .gray
        }
    }

    /// 把 key 或缩写都归到 key 上——图表里传进来的往往已经是缩写（"OC"）。
    private static func resolveKey(_ source: String?) -> String {
        let raw = normalize(source)
        if displayNames[raw] != nil { return raw }
        for (key, short) in shortNames where short.lowercased() == raw { return key }
        return raw
    }

    /// 归一化：去空白、小写。`nil` / 空串返回空串，由调用方决定兜底文案。
    static func normalize(_ source: String?) -> String {
        (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func titleCased(_ key: String) -> String {
        key.split { $0 == "_" || $0 == "-" || $0 == " " }
            .map { word in
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}
