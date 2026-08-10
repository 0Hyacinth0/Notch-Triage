import XCTest

@testable import NotchTriage

final class ExpandHintPolicyTests: XCTestCase {
    func testInitialPolicyShowsHintBeforeAnyValidHover() {
        let policy = ExpandHintPolicy()

        XCTAssertEqual(policy.impressionCount, 0)
        XCTAssertFalse(policy.didExpandPanel)
        XCTAssertTrue(policy.hasExpanded == false)
        XCTAssertTrue(policy.shouldShowHint)
    }

    func testFirstThreeValidHoversReturnHintEligibility() {
        var policy = ExpandHintPolicy()

        XCTAssertTrue(policy.recordValidHover())
        XCTAssertEqual(policy.impressionCount, 1)
        XCTAssertTrue(policy.shouldShowHint)

        XCTAssertTrue(policy.recordValidHover())
        XCTAssertEqual(policy.impressionCount, 2)
        XCTAssertTrue(policy.shouldShowHint)

        XCTAssertTrue(policy.recordValidHover())
        XCTAssertEqual(policy.impressionCount, 3)
        XCTAssertFalse(policy.shouldShowHint)
    }

    func testFourthAndLaterValidHoversDoNotShowHintOrOverflow() {
        var policy = ExpandHintPolicy()
        _ = policy.recordValidHover()
        _ = policy.recordValidHover()
        _ = policy.recordValidHover()

        XCTAssertFalse(policy.recordValidHover())
        XCTAssertFalse(policy.recordValidHover())
        XCTAssertEqual(policy.impressionCount, ExpandHintPolicy.maxHintImpressions)
        XCTAssertFalse(policy.shouldShowHint)
    }

    func testSuccessfulExpansionPermanentlyHidesHintUntilReset() {
        var policy = ExpandHintPolicy()

        policy.markExpanded()

        XCTAssertTrue(policy.didExpandPanel)
        XCTAssertTrue(policy.hasExpanded)
        XCTAssertFalse(policy.shouldShowHint)
        XCTAssertFalse(policy.recordValidHover())
        XCTAssertEqual(policy.impressionCount, 0)
    }

    func testResetRestoresInitialPolicy() {
        var policy = ExpandHintPolicy(impressionCount: 2, didExpandPanel: true)

        policy.reset()

        XCTAssertEqual(policy, ExpandHintPolicy())
        XCTAssertEqual(policy.impressionCount, 0)
        XCTAssertFalse(policy.didExpandPanel)
        XCTAssertTrue(policy.shouldShowHint)
    }

    func testPersistedNegativeCountNormalizesToZero() {
        let policy = ExpandHintPolicy(
            persistedImpressionCount: Int.min,
            didExpandPanel: false
        )

        XCTAssertEqual(policy.impressionCount, 0)
        XCTAssertTrue(policy.shouldShowHint)
    }

    func testPersistedOversizedCountNormalizesToSaturatedMaximum() {
        let policy = ExpandHintPolicy(
            persistedImpressionCount: Int.max,
            didExpandPanel: false
        )

        XCTAssertEqual(policy.impressionCount, ExpandHintPolicy.maxHintImpressions)
        XCTAssertFalse(policy.shouldShowHint)
    }

    func testPersistedExpandedFlagHidesHintRegardlessOfCount() {
        let policy = ExpandHintPolicy(
            persistedImpressionCount: 0,
            didExpandPanel: true
        )

        XCTAssertTrue(policy.didExpandPanel)
        XCTAssertFalse(policy.shouldShowHint)
    }
}
