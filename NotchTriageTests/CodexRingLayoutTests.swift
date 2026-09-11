import AppKit
import SwiftUI
import XCTest
@testable import NotchTriage

final class CodexRingLayoutTests: XCTestCase {
    func testUnknownAndMissingPreferencesKeepExistingLayout() {
        XCTAssertEqual(CodexRingLayout.restored(from: nil), .concentric)
        XCTAssertEqual(CodexRingLayout.restored(from: "future-layout"), .concentric)
    }

    @MainActor
    func testSelectionPersistsAcrossModelRecreation() {
        let key = AppModel.PreferenceKey.codexRingLayout
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        for layout in CodexRingLayout.allCases {
            let model = AppModel()
            model.codexRingLayout = layout
            XCTAssertEqual(AppModel().codexRingLayout, layout)
        }
    }

    @MainActor
    func testRenderQuotaBoundaryStates() throws {
        let model = AppModel()
        let content = VStack(alignment: .leading, spacing: 22) {
            Text("Codex · 5h / Weekly").font(.headline)
            ForEach(CodexRingLayout.allCases) { layout in
                HStack(spacing: 24) {
                    Text(layout.title).frame(width: 160, alignment: .leading)
                    ForEach([0.0, 0.01, 0.45, 0.75, 1.0], id: \.self) { value in
                        VStack(spacing: 10) {
                            CodexQuotaRings(layout: layout, fiveHour: value, weekly: value,
                                            style: model.ringAppearance.style(for: .codex))
                            Text("\(Int(value * 100))%").font(.caption)
                        }
                    }
                    CodexQuotaRings(layout: layout, fiveHour: 0.75, weekly: 0.45,
                                    style: model.ringAppearance.style(for: .codex), diameter: 20)
                }
            }
        }
        .padding(28).foregroundStyle(.white).background(.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/notch-triage-quota-layouts.png"))
    }
}
