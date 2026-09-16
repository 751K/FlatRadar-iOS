import Foundation

/// 把各平台的面积显示串归一成同一个写法。
///
/// **为什么需要它**
/// -------------
/// 面积和价格是同一个病根：后端给的是**平台原样字符串**，没有数值字段。
/// 各平台的写法不是一套——OurDomain 给 `"22,56"`（荷兰式逗号小数点），
/// Holland2Stay 给 `"33.78 m²"`。原样显示的话同一列里会同时出现
/// `22,56 m²` 和 `33.78 m²`：说的是同一件事，读的人却得先判断这是哪种写法。
///
/// **为什么在包里而不是各端各写一份**
/// -------------------------------
/// 列表、详情、地图卡片、Inspector 都要显示面积，两端加起来六七处。
/// 各写一份的结果就是这次要修的东西：Mac 的表格归一了、地图没归一。
public nonisolated enum AreaText {

    /// 归一后的面积串（`"22.56 m²"`）。空串 / nil 返回 `nil`——
    /// 调用方据此显示「缺」，而不是显示一个空格。
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let dotted = dotDecimalSeparator(trimmed)
        return dotted.lowercased().contains("m") ? dotted : "\(dotted)m²"
    }

    /// 把逗号当小数点的平台（OurDomain 给 `"22,56"`）统一成点。
    ///
    /// 只改**小数点**，不碰分位符：逗号后面正好三位数字时当分位符原样留着
    /// （`"1,067"`）。面积不会有四位数，这一条纯属防御。已经有点了就不动
    /// （`"73.35"`），那说明这个平台本来就用英美写法。
    ///
    /// 不用正则：这个函数在列表滚动时每帧每行都要走一遍，一次线性扫描就够。
    static func dotDecimalSeparator(_ s: String) -> String {
        guard s.firstIndex(of: ".") == nil, let comma = s.lastIndex(of: ",") else { return s }
        let digitsAfter = s[s.index(after: comma)...].prefix { $0.isNumber }.count
        guard (1...2).contains(digitsAfter) else { return s }
        return s.replacingCharacters(in: comma...comma, with: ".")
    }
}
