import XCTest
@testable import FlatRadarCore

/// 分享出去的那几行字。
///
/// 这些断言等于把"收件人看到什么"写下来。两端共用一份之后，改动会同时影响
/// iPhone 和 Mac 的分享面板，所以格式值得钉住。
final class ListingShareTests: XCTestCase {

    func testMessageJoinsHeadWithMiddots() {
        let l = Self.listing()
        let msg = ListingShare.message(for: l)
        XCTAssertEqual(msg,
                       "H2S · Jan van Zutphenstraat 315 · €1766 · Amsterdam\n"
                       + "https://holland2stay.com/x")
    }

    func testMessageOmitsMissingPieces() {
        // 没价格、没城市、没链接：整段只剩平台和名字，不能留下空的 ` · ` 或空行。
        let l = Self.listing(price: nil, city: "", url: "")
        XCTAssertEqual(ListingShare.message(for: l), "H2S · Jan van Zutphenstraat 315")
    }

    func testMessageKeepsURLOnItsOwnLine() {
        // 分行是有意的：iMessage / 邮件里链接单独一行才好点。
        let msg = ListingShare.message(for: Self.listing())
        XCTAssertEqual(msg.components(separatedBy: "\n").count, 2)
        XCTAssertTrue(msg.hasSuffix("https://holland2stay.com/x"))
    }

    func testPreviewTitleIncludesPrice() {
        XCTAssertEqual(ListingShare.previewTitle(for: Self.listing()),
                       "Jan van Zutphenstraat 315 · €1766")
    }

    func testPreviewTitleFallsBackToNameOnly() {
        XCTAssertEqual(ListingShare.previewTitle(for: Self.listing(price: nil)),
                       "Jan van Zutphenstraat 315")
    }

    // MARK: - Universal Link

    private static let base = URL(string: "https://flatradar.app")!

    func testUniversalLinkShape() {
        XCTAssertEqual(ListingShare.universalLink(id: "xr_403225", base: Self.base)?.absoluteString,
                       "https://flatradar.app/l/xr_403225")
    }

    func testUniversalLinkTolerantesTrailingSlashOnBase() {
        // base 从 `server_url` 来，用户可能填带尾斜杠的。拼出来不能是 `//l/`。
        let slashed = URL(string: "https://flatradar.app/")!
        XCTAssertEqual(ListingShare.universalLink(id: "abc", base: slashed)?.absoluteString,
                       "https://flatradar.app/l/abc")
    }

    func testUniversalLinkKeepsSelfHostedPortAndHost() {
        // 自建实例分享出去的链接要指向他自己那台机器，不是官方那台。
        let own = URL(string: "https://home.example.net:8443")!
        XCTAssertEqual(ListingShare.universalLink(id: "abc", base: own)?.absoluteString,
                       "https://home.example.net:8443/l/abc")
    }

    func testUniversalLinkNeedsAnID() {
        XCTAssertNil(ListingShare.universalLink(id: "", base: Self.base))
    }

    func testRoundTrip() {
        let url = ListingShare.universalLink(id: "xr_403225", base: Self.base)!
        XCTAssertEqual(ListingShare.listingID(fromUniversalLink: url), "xr_403225")
    }

    func testParserRejectsOtherPaths() {
        // 系统会把这个域名下用户点过的任何链接都交给 app。认不出来的必须还给
        // 浏览器——否则在浏览器里点站内链接会被莫名拽进 app 然后什么也没发生。
        for path in ["/", "/settings", "/l", "/l/", "/l/a/b", "/lucky/abc", "/stats"] {
            let url = URL(string: "https://flatradar.app" + path)!
            XCTAssertNil(ListingShare.listingID(fromUniversalLink: url),
                         "不该认下 \(path)")
        }
    }

    func testParserRejectsTheCustomScheme() {
        // `h2smonitor://listing/x` 走的是另一条路（`.onOpenURL`），不能从这里进。
        let url = URL(string: "h2smonitor://listing/abc")!
        XCTAssertNil(ListingShare.listingID(fromUniversalLink: url))
    }

    func testParserIgnoresQueryAndFragment() {
        // 邮件客户端常常往链接尾巴上挂追踪参数。
        let url = URL(string: "https://flatradar.app/l/abc?utm_source=mail#top")!
        XCTAssertEqual(ListingShare.listingID(fromUniversalLink: url), "abc")
    }

    func testDeepLinkShape() {
        XCTAssertEqual(ListingShare.deepLink(id: "abc").absoluteString,
                       "h2smonitor://listing/abc")
    }

    func testWebURLIsNilWhenThePlatformGaveNoLink() {
        // 分享入口要靠它决定显不显示——分享一个打不开的链接比没有分享更糟。
        XCTAssertNil(ListingShare.webURL(Self.listing(url: "")))
        XCTAssertNotNil(ListingShare.webURL(Self.listing()))
    }

    // MARK: -

    private static func listing(price: String? = "€1766",
                                city: String = "Amsterdam",
                                url: String = "https://holland2stay.com/x") -> Listing {
        let priceField = price.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id":"abc","name":"Jan van Zutphenstraat 315","status":"available",
         "source":"holland2stay","price_raw":\(priceField),"price_value":null,
         "available_from":null,"features":[],"feature_map":{},"city":"\(city)",
         "url":"\(url)","first_seen":null,"last_seen":null}
        """
        return try! JSONDecoder().decode(Listing.self, from: Data(json.utf8))
    }
}
