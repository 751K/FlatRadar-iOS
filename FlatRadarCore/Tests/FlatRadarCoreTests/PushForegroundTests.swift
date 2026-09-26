import XCTest
import UserNotifications
@testable import FlatRadarCore

private actor PermissionSource: NotificationAuthorizing {
    var status: UNAuthorizationStatus = .denied
    var prompts = 0
    func setStatus(_ value: UNAuthorizationStatus) { status = value }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        prompts += 1
        return true
    }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
}

/// A MainActor-isolated mock for the platform bridge used by PushStore.
/// Keep this at file scope: nesting it in the XCTestCase's @MainActor context
/// makes Swift 6.2 infer conflicting isolation for its synthesized initializer.
@MainActor
private final class PushForegroundBridgeMock: PushPlatformBridge {
    var onDeviceToken: ((Data) -> Void)?
    var onRegistrationError: ((any Error) -> Void)?
    var registrations = 0

    init() {}

    func flushPendingToken() {}
    func registerForRemoteNotifications() { registrations += 1 }
}

@MainActor
final class PushForegroundTests: XCTestCase {
    func testSettingsPermissionChangesRefreshAndRegisterWithoutPrompting() async {
        let source = PermissionSource()
        let name = "PushForegroundTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PushStore(defaults: defaults, notifications: source)
        let bridge = PushForegroundBridgeMock()
        store.setup(bridge: bridge)
        await store.refreshPermissionAndRegistration { true }
        XCTAssertEqual(store.permissionStatus, .denied)
        XCTAssertEqual(bridge.registrations, 0)
        await source.setStatus(.authorized)
        await store.refreshPermissionAndRegistration { true }
        XCTAssertEqual(store.permissionStatus, .authorized)
        XCTAssertEqual(bridge.registrations, 1)
        await source.setStatus(.denied)
        await store.refreshPermissionAndRegistration { true }
        XCTAssertEqual(store.permissionStatus, .denied)
        XCTAssertEqual(bridge.registrations, 1)
        let prompts = await source.prompts
        XCTAssertEqual(prompts, 0)
    }

    func testGuestOrOptOutDoesNotRegisterButStillRefreshesPermission() async {
        let source = PermissionSource()
        await source.setStatus(.authorized)
        let name = "PushForegroundTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PushStore(defaults: defaults, notifications: source)
        let bridge = PushForegroundBridgeMock()
        store.setup(bridge: bridge)
        await store.refreshPermissionAndRegistration { false }
        XCTAssertEqual(store.permissionStatus, .authorized)
        XCTAssertEqual(bridge.registrations, 0)
        await store.setEnabled(false)
        await store.refreshPermissionAndRegistration { true }
        XCTAssertEqual(bridge.registrations, 0)
        let prompts = await source.prompts
        XCTAssertEqual(prompts, 0)
    }
}
