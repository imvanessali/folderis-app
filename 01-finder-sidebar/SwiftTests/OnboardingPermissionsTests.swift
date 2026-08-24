import XCTest
@testable import FinderSidebarPanel

final class OnboardingPermissionsTests: XCTestCase {
    @MainActor
    func testBothPermissionsAreRequiredToFinishOnboarding() {
        XCTAssertTrue(Onboarding.permissionsReady(
            accessibilityGranted: true,
            automationGranted: true
        ))
        XCTAssertFalse(Onboarding.permissionsReady(
            accessibilityGranted: false,
            automationGranted: true
        ))
        XCTAssertFalse(Onboarding.permissionsReady(
            accessibilityGranted: true,
            automationGranted: false
        ))
        XCTAssertFalse(Onboarding.permissionsReady(
            accessibilityGranted: true,
            automationGranted: nil
        ))
    }
}
