import Foundation
import MapKit
import CoreLocation
import FlatRadarCore

/// 把一套房源交给系统的**地图 app 导航**。
///
/// 和 app 内那张地图是两件事：内嵌地图回答"它在城市的哪一块"，这个按钮回答
/// "怎么过去"。后者不该由我们重做一遍——路线、实时公交、离线地图都在系统那边。
enum OpenInMaps {

    /// 坐标从哪儿来。
    ///
    /// `/listings` **不回坐标**（openapi 里 `Listing` 没有 lat/lng），所以拿到
    /// 一条 ``Listing`` 时得单独问一次 `GET /map/locate`。右栏的小地图
    /// （``MapThumbnailStore``）本来就在做这件事，所以绝大多数情况下这里是
    /// 直接读缓存，一次网络都不发。
    enum Source {
        /// 地图那份数据里的房源，坐标就在手上。
        case mapListing(MapListing)
        /// 只有 id 和名字，坐标得去问。
        case needsLookup(id: Listing.ID, name: String)
    }

    /// 打开系统地图并**开始导航**。
    ///
    /// 用 `MKLaunchOptionsDirectionsModeDefault` 而不是写死 driving：
    /// 这是荷兰的租房场景，绝大多数人骑车或坐公交，硬塞一个驾车路线是错的。
    /// `Default` 用的是用户在地图 app 里自己的偏好。
    @discardableResult
    static func open(_ source: Source, thumbnails: MapThumbnailStore) async -> Bool {
        switch source {
        case .mapListing(let listing):
            present(coordinate: listing.displayCoordinate, name: listing.name)
            return true

        case .needsLookup(let id, let name):
            if let listing = await resolve(id: id, thumbnails: thumbnails) {
                present(coordinate: listing.displayCoordinate, name: name)
                return true
            }
            return false
        }
    }

    /// 先读小地图那份缓存，没有再问后端。
    private static func resolve(id: Listing.ID,
                                thumbnails: MapThumbnailStore) async -> MapListing? {
        if case .located(let listing) = thumbnails.entry(for: id) { return listing }
        // 缓存里没有（比如右栏正好没画小地图，或者还没加载完）：现问一次。
        // 走 `MapThumbnailStore.load` 而不是直接调 APIClient，这样结果会进缓存，
        // 小地图和这个按钮不会各问各的。
        await thumbnails.load(id: id)
        if case .located(let listing) = thumbnails.entry(for: id) { return listing }
        return nil
    }

    /// 用**显示坐标**而不是真实坐标。
    ///
    /// 同一栋楼的多套房源共用一个地址，服务端把它们摆成一圈
    /// （`spread_stacked_coords`），`displayCoordinate` 就是摆开之后的那个。
    /// 导航到哪一个都一样——它们本来就是同一个门牌——而用显示坐标能和 app 里
    /// 看到的针对得上，不会出现"地图上在这儿、导航却去了旁边"的错觉。
    private static func present(coordinate: CLLocationCoordinate2D, name: String) {
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude,
                                                  longitude: coordinate.longitude),
                             address: nil)
        item.name = name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault
        ])
    }
}
