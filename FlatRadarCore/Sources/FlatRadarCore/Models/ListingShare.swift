import Foundation

/// 分享一套房源时，说给收件人听的那几行字。
///
/// 原先这几段在 iOS 的 `ListingDetailView` 里（`shareMessage` / `sharePreviewTitle`
/// / `deepLink`）。Mac 也要分享，而"分享出去的是什么样子"应该两端一致——
/// 同一套房从 iPhone 发和从 Mac 发，收件人看到的不该是两种格式。
///
/// **两端唯一有意分歧的是「分享的那个链接是什么」**，见 ``deepLink(id:)`` 和
/// ``webURL(_:)`` 各自的注释。
public nonisolated enum ListingShare {

    /// `h2smonitor://listing/<id>`。
    ///
    /// **不再用作分享链接**——那是 ``universalLink(id:base:)`` 的活。
    /// 自定义 scheme 对没装 app 的收件人是一条死链，而 Universal Link 两边都成立。
    ///
    /// 留着是因为它还有两个用处：推送 payload 里的 `deep_link` 就是这个格式，
    /// 以及从别处（旧链接、手工输入）进来的 `h2smonitor://` 两端都仍然接得住。
    public static func deepLink(id: String) -> URL {
        URL(string: "h2smonitor://listing/\(id)") ?? URL(string: "h2smonitor://")!
    }

    /// 分享链接里那一段路径。改它要同时改后端的路由和 AASA 文件。
    public static let path = "/l/"

    /// **分享出去的就是它**：`https://<服务器>/l/<id>`。
    ///
    /// 这是一条 Universal Link：
    /// - 收件人装了 FlatRadar → 系统直接把链接交给 app（靠服务器上的
    ///   `/.well-known/apple-app-site-association`）
    /// - 没装 → 浏览器打开一个公开的房源页
    ///
    /// 一条链接同时满足两边，是自定义 scheme（`h2smonitor://`）和平台网址
    /// 都做不到的：前者对没装 app 的人是死链，后者对装了的人不会唤起 app。
    ///
    /// 用**当前服务器**而不是写死 `flatradar.app`：自建实例的用户分享出去的
    /// 链接得能打开他自己那台机器上的房源。官方那台的 AASA 已经配好，自建的
    /// 那份是自建者自己的事——即便没配，链接在浏览器里照样打得开。
    /// 收**显式的 base**，不自己去问 `APIClient`。
    ///
    /// 这样这个函数是纯的：测试里传一个固定的 base 就能断言拼出来的形状，
    /// 不必起一个主 actor 上的单例。真正读当前服务器的是下面那个便利版。
    public static func universalLink(id: String, base: URL) -> URL? {
        guard !id.isEmpty else { return nil }
        // 用 `relativeTo:` 而不是字符串拼接：base 带不带尾斜杠、带不带端口，
        // 由 `URL` 去处理，拼错的空间小很多。
        return URL(string: path + id, relativeTo: base)?.absoluteURL
    }

    /// 用**当前服务器**拼。分享入口用的是这个。
    @MainActor
    public static func universalLink(id: String) -> URL? {
        universalLink(id: id, base: APIClient.shared.currentBaseURL())
    }

    /// 反过来：从一条 Universal Link 里取出房源 id。
    ///
    /// **只认 `/l/<id>` 这一种形状**，其余一律返回 nil。系统会把这个域名下
    /// 用户点过的**任何**链接都交给 app（`applinks` 认领的是路径前缀），
    /// 认不出来的要老老实实还给浏览器，不能默默吞掉——否则用户在浏览器里点
    /// 一个站内链接会莫名其妙地被拽进 app 然后什么也没发生。
    public static func listingID(fromUniversalLink url: URL) -> String? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        // `path` 形如 `/l/xr_403225`。用 pathComponents 而不是字符串前缀：
        // `/lucky/...` 也是 `/l` 开头，但它不是分享链接。
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "l" else { return nil }
        let id = parts[1]
        return id.isEmpty ? nil : id
    }

    /// 房源在平台上的真实网址。
    ///
    /// **不再用作分享链接**（那是 ``universalLink(id:)`` 的活），但留着——
    /// 「Open on Holland2Stay」「Copy Link」用的都是它，而且分享入口要靠它
    /// 判断"这条房源有没有一个真实的出处"：`/listings` 里的 `url` 是平台原样
    /// 给的，可能是空串。
    public static func webURL(_ listing: Listing) -> URL? {
        guard !listing.url.isEmpty else { return nil }
        return URL(string: listing.url)
    }

    /// 分享文本：`平台 · 地址 · 价格 · 城市` 加一行官网链接。
    ///
    /// 用 `\n` 分行，让 iMessage / 邮件 / 备忘录这类接收方显示得清楚些。
    ///
    /// 收的是**散字段**而不是一个 `Listing`：地图屏点中的那一套来自
    /// `MapListing`，它和 `Listing` 是两个模型（`/map` 和 `/listings` 覆盖的集合
    /// 不一样，地图上看得见的不一定在列表里）。只接 `Listing` 的话，地图上有一半
    /// 的 pin 会莫名其妙没有「分享」这一项。
    public static func message(shortSource: String,
                               name: String,
                               price: String?,
                               city: String,
                               url: String) -> String {
        var head: [String] = [shortSource, name]
        if let price, !price.isEmpty { head.append(price) }
        if !city.isEmpty { head.append(city) }
        var lines = [head.joined(separator: " · ")]
        if !url.isEmpty { lines.append(url) }
        return lines.joined(separator: "\n")
    }

    public static func message(for listing: Listing) -> String {
        message(shortSource: listing.sourceShortText,
                name: listing.name,
                price: listing.priceText,
                city: listing.city,
                url: listing.url)
    }

    /// 分享面板顶部那行预览标题——地址 + 价格（如有），比链接本身友好得多。
    public static func previewTitle(name: String, price: String?) -> String {
        if let price, !price.isEmpty { return "\(name) · \(price)" }
        return name
    }

    public static func previewTitle(for listing: Listing) -> String {
        previewTitle(name: listing.name, price: listing.priceText)
    }
}
