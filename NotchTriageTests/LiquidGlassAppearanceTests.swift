import XCTest

@testable import NotchTriage

final class LiquidGlassAppearanceTests: XCTestCase {
    func testIntensityClampsToSupportedRange() {
        XCTAssertEqual(LiquidGlassAppearance(intensity: -1).intensity, 0)
        XCTAssertEqual(LiquidGlassAppearance(intensity: 2).intensity, 1)
        XCTAssertEqual(
            LiquidGlassAppearance(intensity: .nan).intensity,
            LiquidGlassAppearance.defaultIntensity
        )
    }

    func testHigherIntensityStrengthensEdgeTreatment() {
        let clear = LiquidGlassAppearance(intensity: 0)
        let strong = LiquidGlassAppearance(intensity: 1)

        XCTAssertGreaterThan(
            strong.outerHighlightOpacity,
            clear.outerHighlightOpacity
        )
        XCTAssertGreaterThan(strong.dimmingOpacity, clear.dimmingOpacity)
        XCTAssertGreaterThan(
            strong.innerHighlightOpacity,
            clear.innerHighlightOpacity
        )
    }

    func testDefaultIntensityUsesBalancedPreset() {
        let appearance = LiquidGlassAppearance(
            intensity: LiquidGlassAppearance.defaultIntensity
        )

        XCTAssertEqual(appearance.intensity, 0.68)
        XCTAssertGreaterThan(appearance.dimmingOpacity, 0.45)
        XCTAssertLessThan(appearance.dimmingOpacity, 0.55)
    }
}
