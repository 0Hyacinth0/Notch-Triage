import XCTest

@testable import NotchTriage

@MainActor
final class FileDropSessionTests: XCTestCase {
    func testStaleCompletionCannotClearReplacementSession() {
        let model = AppModel()
        let firstSession = UUID()
        let replacementSession = UUID()

        model.beginFileDropInFlight(sessionID: firstSession)
        XCTAssertTrue(model.isFileDropInFlight)
        XCTAssertEqual(model.fileDropInFlightSessionID, firstSession)

        model.beginFileDropInFlight(sessionID: replacementSession)
        model.finishFileDropInFlight(sessionID: firstSession)
        XCTAssertEqual(
            model.fileDropInFlightSessionID,
            replacementSession
        )

        model.finishFileDropInFlight(sessionID: replacementSession)
        XCTAssertFalse(model.isFileDropInFlight)
        XCTAssertNil(model.fileDropInFlightSessionID)
    }

    func testCancellationClearsAcceptedSession() {
        let model = AppModel()
        model.beginFileDropInFlight(sessionID: UUID())

        model.cancelFileDropInFlight()

        XCTAssertFalse(model.isFileDropInFlight)
        XCTAssertNil(model.fileDropInFlightSessionID)
    }
}
