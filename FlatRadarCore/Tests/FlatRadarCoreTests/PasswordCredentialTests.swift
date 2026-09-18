import XCTest
@testable import FlatRadarCore

@MainActor
final class PasswordCredentialTests: XCTestCase {
    func testSuccessfulChangeInvalidatesStoredAndPendingCredentials() async {
        var invalidations = 0
        var submitted: [String] = []
        let store = AuthStore(changePasswordRequest: { current, new in
            submitted = [current, new]
        }, invalidateBiometricCredentials: { invalidations += 1 })
        store.role = .user
        store.pendingBiometricCredential = ("user", "old", "user")
        let changed = await store.changePassword(current: "old", new: "new")
        XCTAssertTrue(changed)
        XCTAssertEqual(submitted, ["old", "new"])
        XCTAssertEqual(invalidations, 1)
        XCTAssertNil(store.pendingBiometricCredential)
        XCTAssertFalse(store.isLoading)
    }

    func testFailedChangePreservesWorkingCredentials() async {
        var invalidations = 0
        let store = AuthStore(changePasswordRequest: { _, _ in
            throw URLError(.notConnectedToInternet)
        }, invalidateBiometricCredentials: { invalidations += 1 })
        store.role = .user
        store.pendingBiometricCredential = ("user", "old", "user")
        let changed = await store.changePassword(current: "old", new: "new")
        XCTAssertFalse(changed)
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(store.pendingBiometricCredential?.password, "old")
        XCTAssertNotNil(store.errorMessage)
    }
}
