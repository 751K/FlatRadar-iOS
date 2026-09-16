import SwiftUI
import AppKit
import FlatRadarCore

/// 分享一套房源。
///
/// 四个地方要用同一份：右栏的动作行、独立详情窗、表格行的右键菜单、地图标记的
/// 右键菜单。分享的内容（链接、正文、预览标题）在包里的 ``ListingShare``，
/// 和 iOS 的分享面板共用——同一套房从 iPhone 发和从 Mac 发，收件人看到的
/// 不该是两种格式。
///
/// 分享的是 **Universal Link**：`https://<服务器>/l/<id>`
/// ---------------------------------------------------
/// 收件人装了 FlatRadar，系统把链接直接交给 app；没装就在浏览器里看一个公开的
/// 房源页。**一条链接同时满足两边**——自定义 scheme（`h2smonitor://`）对没装的人
/// 是死链，平台网址对装了的人不唤起 app，两者都只成立一半。
///
/// 链接的生成和解析都在 ``ListingShare``，两端共用；服务器那一半是
/// `/.well-known/apple-app-site-association` 加 `/l/<id>` 落地页。
/// 少任何一半都会**静默失效**：系统不报错，链接只是"在浏览器里打开了"。
///
/// **拿不到链接就不显示入口。** `universalLink` 只在 id 为空时返回 nil，
/// 实际上等于总是有——但仍然判一次，因为"分享一个打不开的链接比没有分享更糟"
/// 这条判断以后还会有别的来源（比如将来允许分享一条只在地图里存在的记录）。

/// 详情里那种矮按钮形态，和 ``ListingActionButton`` 同一套尺寸。
struct ListingShareButton: View {

    let listing: Listing

    var body: some View {
        if let url = ListingShare.universalLink(id: listing.id) {
            ShareLink(item: url,
                      subject: Text(listing.name),
                      message: Text(ListingShare.message(for: listing)),
                      preview: SharePreview(ListingShare.previewTitle(for: listing),
                                            image: ListingShareIcon.image)) {
                Text("Share…")
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
    }
}

/// 菜单项形态。放进 `.contextMenu` 或 `CommandMenu` 里就是一条普通菜单项，
/// 点开弹系统的分享面板。
///
/// 收散字段而不是一个 `Listing`：地图屏点中的那一套是 `MapListing`，和 `Listing`
/// 是两个模型。只接 `Listing` 的话，地图上有一半的 pin 会没有这一项。
struct ListingShareMenuItem: View {

    let id: String
    let name: String
    let shortSource: String
    let price: String?
    let city: String
    /// 平台原页的网址。**不是分享出去的那条链接**，只进正文当兜底。
    let url: String

    init(listing: Listing?) {
        id = listing?.id ?? ""
        name = listing?.name ?? ""
        shortSource = listing?.sourceShortText ?? ""
        price = listing?.priceText
        city = listing?.city ?? ""
        url = listing?.url ?? ""
    }

    init(unit: MapListing) {
        id = unit.id
        name = unit.name
        shortSource = Platform.shortName(unit.source)
        price = PriceText.compact(unit.priceRaw)
        city = unit.city
        url = unit.url
    }

    var body: some View {
        if let link = ListingShare.universalLink(id: id) {
            ShareLink("Share…",
                      item: link,
                      subject: Text(name),
                      message: Text(ListingShare.message(shortSource: shortSource,
                                                         name: name,
                                                         price: price,
                                                         city: city,
                                                         url: url)),
                      preview: SharePreview(
                        ListingShare.previewTitle(name: name, price: price),
                        image: ListingShareIcon.image))
        } else {
            // 分享不了的时候画一条**灰着的**，不是把它整条拿掉。
            //
            // Mac 的惯例是命令一直在原位、不能用就变灰——菜单项忽有忽无会让人
            // 以为自己记错了位置。这里真会发生：站在地图屏时 `focused` 那一套
            // 可能不在 `/listings` 里（两个接口覆盖的集合不一样），`Listing`
            // 取不到，第一版就是那时候整条消失。
            Button("Share…") {}.disabled(true)
        }
    }
}

/// 分享面板顶部那个预览图标。
///
/// 用 app 自己的图标，让收件人／拷贝面板里有品牌识别度。macOS 上不用像 iOS 那样
/// 去 `CFBundleIcons` 里翻文件名——`NSApplication` 直接给得到。
/// 读不到（极少见）退回 SF 房子符号。`static let` 一次加载终生复用。
enum ListingShareIcon {
    static let image: Image = {
        if let icon = NSApp?.applicationIconImage {
            return Image(nsImage: icon)
        }
        return Image(systemName: "house.fill")
    }()
}
