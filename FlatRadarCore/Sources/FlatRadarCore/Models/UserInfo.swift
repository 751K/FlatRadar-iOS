import Foundation

/// From /auth/me -> user field (null for admin)
public nonisolated struct UserInfo: Decodable, Sendable {
    let id: String
    public let name: String
    public let enabled: Bool
    let notificationsEnabled: Bool
    public var listingFilter: ListingFilter   // var：filter 修改后本地同步替换

    public enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case notificationsEnabled = "notifications_enabled"
        case listingFilter = "listing_filter"
    }
}
