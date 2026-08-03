import Foundation
import XCTest

@testable import NotchTriage

final class NotchTriageModelTests: XCTestCase {
    func testAppUpdateDownloadProgressFractionClampsUnknownNegativeAndExcess() {
        XCTAssertEqual(
            AppUpdateDownloadProgress(receivedBytes: 25, totalBytes: 100).fraction,
            0.25
        )
        XCTAssertEqual(
            AppUpdateDownloadProgress(receivedBytes: 25, totalBytes: 0).fraction,
            0
        )
        XCTAssertEqual(
            AppUpdateDownloadProgress(receivedBytes: 25, totalBytes: -1).fraction,
            0
        )
        XCTAssertEqual(
            AppUpdateDownloadProgress(receivedBytes: -1, totalBytes: 100).fraction,
            0
        )
        XCTAssertEqual(
            AppUpdateDownloadProgress(receivedBytes: 125, totalBytes: 100).fraction,
            1
        )
    }

    func testCodexLimitBucketRemainingPercentClampsToBounds() {
        XCTAssertEqual(makeBucket(usedPercent: -10).remainingPercent, 100)
        XCTAssertEqual(makeBucket(usedPercent: 25).remainingPercent, 75)
        XCTAssertEqual(makeBucket(usedPercent: 150).remainingPercent, 0)
        XCTAssertEqual(makeBucket(usedPercent: 25).remainingFraction, 0.75)
    }

    func testCodexLimitBucketWindowLabelUsesMinutesHoursAndDays() {
        XCTAssertEqual(makeBucket(windowMinutes: 45).windowLabel, "45 分钟")
        XCTAssertEqual(makeBucket(windowMinutes: 120).windowLabel, "2 小时")
        XCTAssertEqual(makeBucket(windowMinutes: 2_880).windowLabel, "2 天")
        XCTAssertEqual(makeBucket(windowMinutes: 90).windowLabel, "90 分钟")
    }

    func testMediaSnapshotProgressClampsUnknownNegativeAndExcess() {
        XCTAssertEqual(makeSnapshot(duration: 0, elapsed: 0).progress, 0)
        XCTAssertEqual(makeSnapshot(duration: 100, elapsed: 25).progress, 0.25)
        XCTAssertEqual(makeSnapshot(duration: 100, elapsed: -1).progress, 0)
        XCTAssertEqual(makeSnapshot(duration: 100, elapsed: 125).progress, 1)
    }

    func testRingAppearanceDefaultFollowsSelectedTheme() {
        var settings = RingAppearanceSettings.default
        XCTAssertFalse(settings.codex.isEnabled)
        XCTAssertEqual(
            settings.style(for: .codex),
            RingTheme.system.style(for: .codex)
        )

        settings.theme = .ocean
        XCTAssertEqual(settings.style(for: .codex), RingTheme.ocean.style(for: .codex))
    }

    func testRingAppearanceEnabledOverrideTakesEffect() throws {
        var settings = RingAppearanceSettings.default
        let customStyle = RingStyle(
            start: RingColor(red: 0.1, green: 0.2, blue: 0.3),
            end: RingColor(red: 0.4, green: 0.5, blue: 0.6),
            track: RingColor(red: 0.7, green: 0.8, blue: 0.9, opacity: 0.5),
            gradientMode: .solid
        )
        settings.battery = RingStyleOverride(style: customStyle)

        XCTAssertFalse(settings.battery.isEnabled)
        XCTAssertEqual(settings.style(for: .battery), RingTheme.system.style(for: .battery))

        settings.battery.isEnabled = true
        XCTAssertEqual(settings.style(for: .battery), customStyle)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(RingAppearanceSettings.self, from: encoded)
        XCTAssertEqual(decoded, settings)
    }

    func testAppUpdateStatusBusyAndActiveVersion() {
        let cases: [(AppUpdateStatus, Bool, String?)] = [
            (.idle, false, nil),
            (.checking, true, nil),
            (.available("1.2.3"), false, nil),
            (.downloading("1.2.3"), true, "1.2.3"),
            (.installing("2.0.0"), true, "2.0.0"),
            (.upToDate("1.0.0"), false, nil),
            (.failed("网络错误"), false, nil)
        ]

        for (status, expectedBusy, expectedVersion) in cases {
            XCTAssertEqual(status.isBusy, expectedBusy, "Unexpected busy state for \(status)")
            XCTAssertEqual(
                status.activeUpdateVersion,
                expectedVersion,
                "Unexpected active version for \(status)"
            )
        }
    }

    private func makeBucket(
        usedPercent: Double = 0,
        windowMinutes: Int = 60
    ) -> CodexLimitBucket {
        CodexLimitBucket(
            id: "test",
            name: "Test",
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: nil
        )
    }

    private func makeSnapshot(duration: TimeInterval, elapsed: TimeInterval) -> MediaSnapshot {
        MediaSnapshot(
            sourceName: "Test",
            bundleIdentifier: nil,
            title: "Track",
            artist: "Artist",
            duration: duration,
            elapsed: elapsed,
            isPlaying: false
        )
    }
}
