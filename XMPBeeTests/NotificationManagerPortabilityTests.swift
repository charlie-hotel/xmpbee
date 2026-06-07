import XCTest
@testable import XMPBee

final class NotificationManagerPortabilityTests: XCTestCase {
    @MainActor
    func testPreferencesDefaultsAreStable() {
        let mgr = NotificationManager.shared
        XCTAssertTrue(mgr.notifyOnMessage)
        XCTAssertTrue(mgr.notifyOnDirectMessage)
        XCTAssertTrue(mgr.playSound)
        XCTAssertFalse(mgr.notifyOnJoinPart)
    }

    func testAvailableSystemSoundsNonNil() {
        _ = NotificationManager.availableSystemSounds
    }
}
