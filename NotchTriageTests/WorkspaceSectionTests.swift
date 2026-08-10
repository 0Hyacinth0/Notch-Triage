import XCTest

@testable import NotchTriage

final class WorkspaceSectionTests: XCTestCase {
    func testMissingAndInvalidPersistedValuesFallBackToPower() {
        XCTAssertEqual(WorkspaceSection.restored(from: nil), .power)
        XCTAssertEqual(WorkspaceSection.restored(from: ""), .power)
        XCTAssertEqual(WorkspaceSection.restored(from: "unknown"), .power)
    }

    func testLegacyTriageValueMigratesToNotifications() {
        XCTAssertEqual(
            WorkspaceSection.restored(from: "triage"),
            .notifications
        )
    }

    func testEveryCurrentSectionRoundTripsThroughPersistence() {
        for section in WorkspaceSection.allCases {
            XCTAssertEqual(
                WorkspaceSection.restored(from: section.rawValue),
                section
            )
        }
    }
}
