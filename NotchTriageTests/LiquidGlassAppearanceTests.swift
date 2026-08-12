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

    func testHigherIntensityAddsFrostWithoutDarkeningTheGlass() {
        let clear = LiquidGlassAppearance(intensity: 0)
        let strong = LiquidGlassAppearance(intensity: 1)

        XCTAssertEqual(clear.frostOpacity, 0, accuracy: 0.000_001)
        XCTAssertEqual(strong.frostOpacity, 0.86, accuracy: 0.000_001)
        XCTAssertEqual(clear.desktopBackdropOpacity, 0, accuracy: 0.000_001)
        XCTAssertEqual(strong.desktopBackdropOpacity, 0.72, accuracy: 0.000_001)
        XCTAssertGreaterThan(
            strong.outerHighlightOpacity,
            clear.outerHighlightOpacity
        )
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
        XCTAssertGreaterThan(appearance.frostOpacity, 0.50)
        XCTAssertLessThan(appearance.frostOpacity, 0.52)
    }

    func testFrostProgressionIsNonlinearAndMonotonic() {
        let clear = LiquidGlassAppearance(intensity: 0)
        let balanced = LiquidGlassAppearance(intensity: 0.5)
        let strong = LiquidGlassAppearance(intensity: 1)

        XCTAssertLessThan(clear.frostOpacity, balanced.frostOpacity)
        XCTAssertLessThan(balanced.frostOpacity, strong.frostOpacity)
        XCTAssertLessThan(balanced.frostOpacity, 0.43)
    }
}
