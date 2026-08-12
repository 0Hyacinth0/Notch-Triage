import XCTest

@testable import NotchTriage

final class LiquidGlassStyleTests: XCTestCase {
    func testRawValuesAndGlassMappingsRemainStable() {
        XCTAssertEqual(LiquidGlassStyle.clear.rawValue, "clear")
        XCTAssertEqual(LiquidGlassStyle.regular.rawValue, "regular")
        XCTAssertEqual(LiquidGlassStyle.clear.glass, .clear)
        XCTAssertEqual(LiquidGlassStyle.regular.glass, .regular)
    }

    func testMissingInvalidAndCurrentValuesRestoreExpectedStyle() {
        XCTAssertEqual(LiquidGlassStyle.default, .regular)
        XCTAssertEqual(LiquidGlassStyle.restored(from: nil), .regular)
        XCTAssertEqual(LiquidGlassStyle.restored(from: ""), .regular)
        XCTAssertEqual(LiquidGlassStyle.restored(from: "unsupported"), .regular)

        for style in LiquidGlassStyle.allCases {
            XCTAssertEqual(LiquidGlassStyle.restored(from: style.rawValue), style)
        }
    }

    @MainActor
    func testSettingPersistsRawValueAndNewModelRestoresIt() {
        let defaults = UserDefaults.standard
        let key = AppModel.PreferenceKey.liquidGlassStyle
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
        XCTAssertEqual(model.liquidGlassStyle, .regular)

        model.setLiquidGlassStyle(.clear)
        XCTAssertEqual(model.liquidGlassStyle, .clear)
        XCTAssertEqual(defaults.string(forKey: key), LiquidGlassStyle.clear.rawValue)
        XCTAssertEqual(AppModel().liquidGlassStyle, .clear)

        model.setLiquidGlassStyle(.regular)
        XCTAssertEqual(model.liquidGlassStyle, .regular)
        XCTAssertEqual(defaults.string(forKey: key), LiquidGlassStyle.regular.rawValue)
        XCTAssertEqual(AppModel().liquidGlassStyle, .regular)
    }

    @MainActor
    func testUnsupportedPersistedValueFallsBackWithoutOverwritingDefaults() {
        let defaults = UserDefaults.standard
        let key = AppModel.PreferenceKey.liquidGlassStyle
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set("unsupported", forKey: key)
        XCTAssertEqual(AppModel().liquidGlassStyle, .regular)
        XCTAssertEqual(defaults.string(forKey: key), "unsupported")
    }
}
