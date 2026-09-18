import Foundation
import CoreLocation

/// 视野裁剪使用的地理矩形。经度按日期变更线环绕，缓冲区减少拖动时图钉进出。
public nonisolated struct MapViewport: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(latitude: Double, longitude: Double, latitudeDelta: Double,
                longitudeDelta: Double, padding: Double = 1.5) {
        self.latitude = latitude
        self.longitude = longitude
        self.latitudeDelta = min(180, max(0, latitudeDelta * padding))
        self.longitudeDelta = min(360, max(0, longitudeDelta * padding))
    }

    public func contains(latitude: Double, longitude: Double) -> Bool {
        abs(latitude - self.latitude) <= latitudeDelta / 2
            && (longitudeDelta >= 360 || longitudeDistance(longitude) <= longitudeDelta / 2)
    }

    public func contains(_ other: MapViewport) -> Bool {
        abs(other.latitude - latitude) + other.latitudeDelta / 2 <= latitudeDelta / 2
            && (longitudeDelta >= 360
                || longitudeDistance(other.longitude) + other.longitudeDelta / 2 <= longitudeDelta / 2)
    }

    public func listings(from listings: [MapListing], preservingID: String? = nil) -> [MapListing] {
        listings.filter {
            let point = $0.displayCoordinate
            return $0.id == preservingID || contains(latitude: point.latitude, longitude: point.longitude)
        }
    }

    private func longitudeDistance(_ value: Double) -> Double {
        let distance = abs(value - longitude).truncatingRemainder(dividingBy: 360)
        return min(distance, 360 - distance)
    }
}
