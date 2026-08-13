import XCTest

@testable import NotchTriage

final class LiquidGlassStyleTests: XCTestCase {
    func testLevelClampsAndNonFiniteValuesUseDefault() {
        XCTAssertEqual(LiquidGlassAppearance(level: -1).level, 0)
        XCTAssertEqual(LiquidGlassAppearance(level: 0.4).level, 0.4)
        XCTAssertEqual(LiquidGlassAppearance(level: 2).level, 1)
        XCTAssertEqual(LiquidGlassAppearance(level: .nan).level, 1)
        XCTAssertEqual(LiquidGlassAppearance(level: .infinity).level, 1)
    }

    func testRegularOverlayProvidesContinuousStandardEndpoint() {
        let clear = LiquidGlassAppearance(level: 0)
        XCTAssertEqual(clear.regularLayerOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(clear.desktopBackdropOpacity, 0.14, accuracy: 0.0001)

        let middle = LiquidGlassAppearance(level: 0.5)
        XCTAssertGreaterThan(middle.regularLayerOpacity, 0)
        XCTAssertLessThan(middle.regularLayerOpacity, 1)
        XCTAssertGreaterThan(middle.desktopBackdropOpacity, clear.desktopBackdropOpacity)

        let regular = LiquidGlassAppearance(level: 1)
        XCTAssertEqual(regular.regularLayerOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(regular.desktopBackdropOpacity, 0.72, accuracy: 0.0001)
    }

    @MainActor
    func testSettingPersistsRawValueAndNewModelRestoresIt() {
        let defaults = UserDefaults.standard
        let key = AppModel.PreferenceKey.liquidGlassLevel
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let model = AppModel()
        XCTAssertEqual(model.liquidGlassLevel, 1)

        model.setLiquidGlassLevel(0.37)
        XCTAssertEqual(model.liquidGlassLevel, 0.37)
        XCTAssertEqual(defaults.double(forKey: key), 0.37)
        XCTAssertEqual(AppModel().liquidGlassLevel, 0.37)

        model.setLiquidGlassLevel(4)
        XCTAssertEqual(model.liquidGlassLevel, 1)
        XCTAssertEqual(defaults.double(forKey: key), 1)
    }

    @MainActor
    func testLegacyStyleMigratesWhenContinuousValueIsMissing() {
        let defaults = UserDefaults.standard
        let key = AppModel.PreferenceKey.liquidGlassLevel
        let legacyKey = AppModel.PreferenceKey.legacyLiquidGlassStyle
        let previousValue = defaults.object(forKey: key)
        let previousLegacyValue = defaults.object(forKey: legacyKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            if let previousLegacyValue {
                defaults.set(previousLegacyValue, forKey: legacyKey)
            } else {
                defaults.removeObject(forKey: legacyKey)
            }
        }

        defaults.removeObject(forKey: key)
        defaults.set("clear", forKey: legacyKey)
        XCTAssertEqual(AppModel().liquidGlassLevel, 0)

        defaults.set("regular", forKey: legacyKey)
        XCTAssertEqual(AppModel().liquidGlassLevel, 1)
    }
}
