import XCTest

@testable import NotchTriage

final class UpdatePresentationContextTests: XCTestCase {
    func testSettingsCheckStaysInSettings() {
        let context = UpdatePresentationContext.settings

        XCTAssertTrue(context.isManualCheck)
        XCTAssertFalse(context.presentsAvailableReleaseInPanel)
        XCTAssertFalse(context.presentsInstallProgressInPanel)
    }

    func testAutomaticCheckUsesDeferredPanelPresentation() {
        let context = UpdatePresentationContext.automatic

        XCTAssertFalse(context.isManualCheck)
        XCTAssertFalse(context.presentsAvailableReleaseInPanel)
        XCTAssertTrue(context.presentsInstallProgressInPanel)
    }

    func testPanelCheckAndInstallRemainInPanel() {
        let context = UpdatePresentationContext.panel

        XCTAssertTrue(context.isManualCheck)
        XCTAssertTrue(context.presentsAvailableReleaseInPanel)
        XCTAssertTrue(context.presentsInstallProgressInPanel)
    }
}
