import Foundation
import XCTest

@testable import NotchTriage

private actor TestQQMusicAccessibilityScanner: QQMusicAccessibilityScanning {
    private let metadata: QQMusicTrackMetadata?
    private let delayNanoseconds: UInt64
    private var invocationCount = 0

    init(
        metadata: QQMusicTrackMetadata?,
        delayNanoseconds: UInt64 = 50_000_000
    ) {
        self.metadata = metadata
        self.delayNanoseconds = delayNanoseconds
    }

    func trackMetadata(
        processIdentifier: pid_t,
        cancellation: QQMusicScanCancellation
    ) async -> QQMusicTrackMetadata? {
        invocationCount += 1
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return cancellation.isCancelled ? nil : metadata
    }

    func count() -> Int {
        invocationCount
    }
}

private actor SequencedQQMusicAccessibilityScanner: QQMusicAccessibilityScanning {
    struct Response: Sendable {
        let metadata: QQMusicTrackMetadata?
        let delayNanoseconds: UInt64
    }

    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func trackMetadata(
        processIdentifier: pid_t,
        cancellation: QQMusicScanCancellation
    ) async -> QQMusicTrackMetadata? {
        guard !responses.isEmpty else { return nil }
        let response = responses.removeFirst()
        try? await Task.sleep(nanoseconds: response.delayNanoseconds)
        return cancellation.isCancelled ? nil : response.metadata
    }
}

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

    func testCodexUsageParserReadsCreditsAndEstimatesUSD() {
        let message: [String: Any] = [
            "result": [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 42,
                        "windowDurationMins": 10_080
                    ],
                    "credits": [
                        "hasCredits": true,
                        "unlimited": false,
                        "balance": "2500.0"
                    ]
                ]
            ]
        ]

        let snapshot = CodexUsageParser.parseMessage(message)

        XCTAssertEqual(snapshot?.limits.first?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot?.credits?.credits, Decimal(2_500))
        XCTAssertEqual(snapshot?.credits?.estimatedUSD, Decimal(100))
    }

    func testCodexUsageParserKeepsCreditsAcrossSparseUpdate() {
        let previous = CodexCreditsBalance(
            hasCredits: true,
            unlimited: false,
            balance: "125.5"
        )
        let sparseUpdate: [String: Any] = [
            "method": "account/rateLimits/updated",
            "params": [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 10,
                        "windowDurationMins": 10_080
                    ]
                ]
            ]
        ]

        let snapshot = CodexUsageParser.parseMessage(
            sparseUpdate,
            previousCredits: previous
        )

        XCTAssertEqual(snapshot?.credits, previous)
    }

    func testCodexBalancePresentationCoversConnectionAndAccountStates() {
        let connecting = CodexBalancePresentation(
            credits: nil,
            healthMessage: "正在读取 Codex"
        )
        XCTAssertEqual(
            connecting.state,
            .connecting(message: "正在读取 Codex")
        )
        XCTAssertEqual(connecting.estimatedUSDLabel, "正在连接")
        XCTAssertEqual(connecting.creditsLabel, "正在读取 Codex")

        let unlimited = CodexBalancePresentation(
            credits: CodexCreditsBalance(
                hasCredits: true,
                unlimited: true,
                balance: nil
            ),
            healthMessage: "ready"
        )
        XCTAssertEqual(unlimited.state, .unlimited)
        XCTAssertEqual(unlimited.estimatedUSDLabel, "无限")
        XCTAssertEqual(unlimited.creditsLabel, "credits 无上限")

        let unavailable = CodexBalancePresentation(
            credits: CodexCreditsBalance(
                hasCredits: false,
                unlimited: false,
                balance: nil
            ),
            healthMessage: "ready"
        )
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unavailable.estimatedUSDLabel, "不可用")
        XCTAssertEqual(unavailable.creditsLabel, "账户未启用 credits")

        let unknown = CodexBalancePresentation(
            credits: CodexCreditsBalance(
                hasCredits: true,
                unlimited: false,
                balance: nil
            ),
            healthMessage: "ready"
        )
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertEqual(unknown.estimatedUSDLabel, "余额未知")
        XCTAssertEqual(unknown.creditsLabel, "credits 暂未返回")

        let available = CodexBalancePresentation(
            credits: CodexCreditsBalance(
                hasCredits: true,
                unlimited: false,
                balance: "2500"
            ),
            healthMessage: "ready"
        )
        XCTAssertEqual(
            available.state,
            .available(estimatedUSD: Decimal(100), credits: Decimal(2_500))
        )
        XCTAssertTrue(available.estimatedUSDLabel.hasPrefix("≈ "))
        XCTAssertTrue(available.creditsLabel.hasSuffix(" credits"))
        XCTAssertEqual(available.hint, "按 25 credits ≈ US$1")
    }

    func testWeeklyCodexLimitPrefersSevenDaysThenLargestWindow() {
        let short = makeBucket(id: "short", windowMinutes: 300)
        let weekly = makeBucket(id: "weekly", windowMinutes: 10_080)
        let long = makeBucket(id: "long", windowMinutes: 20_160)

        XCTAssertEqual(
            AppModel.weeklyCodexLimit(from: [short, long, weekly]),
            weekly
        )
        XCTAssertEqual(
            AppModel.weeklyCodexLimit(from: [short, long]),
            long
        )
    }

    func testMediaSnapshotProgressClampsUnknownNegativeAndExcess() {
        XCTAssertEqual(makeSnapshot(duration: 0, elapsed: 0).progress, 0)
        XCTAssertEqual(makeSnapshot(duration: 100, elapsed: 25).progress, 0.25)
        XCTAssertEqual(makeSnapshot(duration: 100, elapsed: -1).progress, 0)
        XCTAssertEqual(makeSnapshot(duration: 100, elapsed: 125).progress, 1)
    }

    func testQQMusicMetadataParserReadsTrackAndPlaybackAction() {
        XCTAssertEqual(
            QQMusicMetadataParser.track(
                from: "歌曲名：测试歌曲 - 歌手名：测试歌手",
                isPlaying: true
            ),
            QQMusicTrackMetadata(
                title: "测试歌曲",
                artist: "测试歌手",
                isPlaying: true
            )
        )
        XCTAssertEqual(QQMusicMetadataParser.isPlaying(from: ["播放"]), false)
        XCTAssertEqual(QQMusicMetadataParser.isPlaying(from: ["暂停"]), true)
        XCTAssertNil(QQMusicMetadataParser.isPlaying(from: ["播放列表"]))
    }

    func testQQMusicAXScanKeyIgnoresProgressButTracksMediaState() {
        let anchor = Date(timeIntervalSince1970: 1_000)
        let first = MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: "com.tencent.QQMusicMac",
            title: "Track",
            artist: "Artist",
            duration: 200,
            elapsed: 10,
            isPlaying: true,
            progressAnchorDate: anchor,
            playbackRate: 1
        )
        var progressed = first
        progressed.elapsed = 120
        progressed.progressAnchorDate = anchor.addingTimeInterval(110)

        XCTAssertEqual(
            QQMusicAXScanKey(processIdentifier: 42, snapshot: first),
            QQMusicAXScanKey(processIdentifier: 42, snapshot: progressed)
        )

        var paused = progressed
        paused.isPlaying = false
        XCTAssertNotEqual(
            QQMusicAXScanKey(processIdentifier: 42, snapshot: first),
            QQMusicAXScanKey(processIdentifier: 42, snapshot: paused)
        )

        var nextTrack = progressed
        nextTrack.title = "Next Track"
        XCTAssertNotEqual(
            QQMusicAXScanKey(processIdentifier: 42, snapshot: first),
            QQMusicAXScanKey(processIdentifier: 42, snapshot: nextTrack)
        )
    }

    func testQQMusicEnrichmentPreservesAdapterProgressAndPlaybackState() throws {
        let anchor = Date(timeIntervalSince1970: 1_000)
        let snapshot = MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: "com.tencent.QQMusicMac",
            title: "Track",
            artist: "",
            duration: 240,
            elapsed: 91,
            isPlaying: true,
            progressAnchorDate: anchor,
            playbackRate: 1.25
        )
        let metadata = QQMusicTrackMetadata(
            title: "Track",
            artist: "Artist from AX",
            isPlaying: false
        )

        let enriched = try XCTUnwrap(QQMusicSnapshotEnricher.merge(
            snapshot,
            metadata: metadata,
            bundleIdentifier: "com.tencent.QQMusicMac"
        ))

        XCTAssertEqual(enriched.artist, "Artist from AX")
        XCTAssertEqual(enriched.duration, 240)
        XCTAssertEqual(enriched.elapsed, 91)
        XCTAssertEqual(enriched.isPlaying, true)
        XCTAssertEqual(enriched.progressAnchorDate, anchor)
        XCTAssertEqual(enriched.playbackRate, 1.25)
    }

    @MainActor
    func testMediaServiceCoalescesHighFrequencyQQMusicAXScans() async {
        let scanner = TestQQMusicAccessibilityScanner(
            metadata: QQMusicTrackMetadata(
                title: "Track",
                artist: "Artist from AX",
                isPlaying: true
            ),
            delayNanoseconds: 100_000_000
        )
        var received: [MediaSnapshot] = []
        let service = MediaService(
            onSnapshot: { received.append($0) },
            onHealth: { _ in },
            qqMusicScanner: scanner,
            qqMusicProcessIdentifier: { 42 }
        )

        for elapsed in 0..<10 {
            service.receiveAdapterSnapshot(MediaSnapshot(
                sourceName: "QQ 音乐",
                bundleIdentifier: "com.tencent.QQMusicMac",
                title: "Track",
                artist: "",
                duration: 200,
                elapsed: TimeInterval(elapsed),
                isPlaying: true,
                progressAnchorDate: Date(timeIntervalSince1970: TimeInterval(1_000 + elapsed)),
                playbackRate: 1
            ))
        }

        try? await Task.sleep(nanoseconds: 250_000_000)

        let scannerInvocationCount = await scanner.count()
        XCTAssertEqual(scannerInvocationCount, 1)
        XCTAssertEqual(received.last?.artist, "Artist from AX")
        XCTAssertEqual(received.last?.elapsed, 9)
        XCTAssertEqual(received.last?.isPlaying, true)
        service.stop()
    }

    @MainActor
    func testMediaServiceSkipsAXForCompleteQQMusicAdapterSnapshot() async {
        let scanner = TestQQMusicAccessibilityScanner(
            metadata: QQMusicTrackMetadata(
                title: "Track",
                artist: "Unexpected AX Artist",
                isPlaying: false
            )
        )
        var received: [MediaSnapshot] = []
        let service = MediaService(
            onSnapshot: { received.append($0) },
            onHealth: { _ in },
            qqMusicScanner: scanner,
            qqMusicProcessIdentifier: { 42 }
        )

        service.receiveAdapterSnapshot(MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: "com.tencent.QQMusicMac",
            title: "Track",
            artist: "Adapter Artist",
            duration: 200,
            elapsed: 10,
            isPlaying: true
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let scannerInvocationCount = await scanner.count()
        XCTAssertEqual(scannerInvocationCount, 0)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last?.artist, "Adapter Artist")
        XCTAssertEqual(received.last?.isPlaying, true)
        service.stop()
    }

    @MainActor
    func testMediaServiceDropsQQMusicAXResultAfterStop() async {
        let scanner = TestQQMusicAccessibilityScanner(
            metadata: QQMusicTrackMetadata(
                title: "Track",
                artist: "Late AX Artist",
                isPlaying: true
            ),
            delayNanoseconds: 100_000_000
        )
        var received: [MediaSnapshot] = []
        let service = MediaService(
            onSnapshot: { received.append($0) },
            onHealth: { _ in },
            qqMusicScanner: scanner,
            qqMusicProcessIdentifier: { 42 }
        )

        service.receiveAdapterSnapshot(MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: "com.tencent.QQMusicMac",
            title: "Track",
            artist: "",
            duration: 200,
            elapsed: 10,
            isPlaying: true
        ))
        service.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last?.artist, "")
    }

    @MainActor
    func testMediaServiceDropsStaleQQMusicAXResultAfterTrackChange() async {
        let scanner = SequencedQQMusicAccessibilityScanner(responses: [
            .init(
                metadata: QQMusicTrackMetadata(
                    title: "Old Track",
                    artist: "Old AX Artist",
                    isPlaying: true
                ),
                delayNanoseconds: 80_000_000
            ),
            .init(
                metadata: QQMusicTrackMetadata(
                    title: "New Track",
                    artist: "New AX Artist",
                    isPlaying: true
                ),
                delayNanoseconds: 10_000_000
            )
        ])
        var received: [MediaSnapshot] = []
        let service = MediaService(
            onSnapshot: { received.append($0) },
            onHealth: { _ in },
            qqMusicScanner: scanner,
            qqMusicProcessIdentifier: { 42 }
        )

        service.receiveAdapterSnapshot(MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: "com.tencent.QQMusicMac",
            title: "Old Track",
            artist: "",
            duration: 200,
            elapsed: 10,
            isPlaying: true
        ))
        service.receiveAdapterSnapshot(MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: "com.tencent.QQMusicMac",
            title: "New Track",
            artist: "",
            duration: 240,
            elapsed: 2,
            isPlaying: true
        ))
        let newTrackStart = received.count - 1

        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(received[newTrackStart...].allSatisfy { $0.title == "New Track" })
        XCTAssertEqual(received.last?.artist, "New AX Artist")
        XCTAssertEqual(received.last?.elapsed, 2)
        service.stop()
    }

    func testMediaSnapshotProgressUsesElapsedSecondsFromMediaRemote() {
        let snapshot = makeSnapshot(duration: 232, elapsed: 58)

        XCTAssertEqual(snapshot.elapsed, 58)
        XCTAssertEqual(snapshot.duration, 232)
        XCTAssertEqual(snapshot.progress, 0.25, accuracy: 0.0001)
    }

    func testMediaSnapshotEstimatedElapsedUsesTimestampAndPlaybackRate() {
        let anchor = Date(timeIntervalSince1970: 1_000)
        let snapshot = MediaSnapshot(
            sourceName: "Test",
            bundleIdentifier: nil,
            title: "Track",
            artist: "Artist",
            duration: 200,
            elapsed: 40,
            isPlaying: true,
            progressAnchorDate: anchor,
            playbackRate: 1.5
        )

        XCTAssertEqual(snapshot.estimatedElapsed(at: anchor.addingTimeInterval(4)), 46)
        XCTAssertEqual(
            snapshot.progress(at: anchor.addingTimeInterval(4)),
            0.23,
            accuracy: 0.0001
        )
    }

    func testMediaSnapshotEstimatedElapsedPausedMissingFutureAndClamped() {
        let anchor = Date(timeIntervalSince1970: 1_000)
        let paused = MediaSnapshot(
            sourceName: "Test",
            bundleIdentifier: nil,
            title: "Track",
            artist: "Artist",
            duration: 200,
            elapsed: 40,
            isPlaying: false,
            progressAnchorDate: anchor,
            playbackRate: 2
        )
        XCTAssertEqual(paused.estimatedElapsed(at: anchor.addingTimeInterval(100)), 40)

        let missingAnchor = MediaSnapshot(
            sourceName: "Test",
            bundleIdentifier: nil,
            title: "Track",
            artist: "Artist",
            duration: 200,
            elapsed: 40,
            isPlaying: true,
            progressAnchorDate: nil,
            playbackRate: 2
        )
        XCTAssertEqual(missingAnchor.estimatedElapsed(at: anchor.addingTimeInterval(100)), 40)

        let future = MediaSnapshot(
            sourceName: "Test",
            bundleIdentifier: nil,
            title: "Track",
            artist: "Artist",
            duration: 200,
            elapsed: 40,
            isPlaying: true,
            progressAnchorDate: anchor.addingTimeInterval(20),
            playbackRate: 2
        )
        XCTAssertEqual(future.estimatedElapsed(at: anchor), 40)

        let clamped = MediaSnapshot(
            sourceName: "Test",
            bundleIdentifier: nil,
            title: "Track",
            artist: "Artist",
            duration: 200,
            elapsed: 40,
            isPlaying: true,
            progressAnchorDate: anchor,
            playbackRate: 2
        )
        XCTAssertEqual(clamped.estimatedElapsed(at: anchor.addingTimeInterval(100)), 200)
        XCTAssertEqual(clamped.progress(at: anchor.addingTimeInterval(100)), 1)
    }

    func testMediaRemoteAdapterParserReadsSnapshotAndIdleNull() {
        let line = """
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.spotify.client","playing":true,"title":"Track","artist":"Artist","duration":240,"elapsedTime":20,"timestamp":"2026-08-04T12:00:00.000Z","playbackRate":1.5}}
        """
        let snapshot = MediaRemoteAdapterParser.parse(line: line)

        XCTAssertEqual(snapshot?.bundleIdentifier, "com.spotify.client")
        XCTAssertEqual(snapshot?.title, "Track")
        XCTAssertEqual(snapshot?.artist, "Artist")
        XCTAssertEqual(snapshot?.duration, 240)
        XCTAssertEqual(snapshot?.elapsed, 20)
        XCTAssertEqual(snapshot?.playbackRate, 1.5)
        XCTAssertEqual(snapshot?.isPlaying, true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            snapshot?.progressAnchorDate,
            formatter.date(from: "2026-08-04T12:00:00.000Z")
        )
        XCTAssertTrue(
            MediaRemoteAdapterParser.isEmptyPayload(
                line: #"{"type":"data","diff":false,"payload":{}}"#
            )
        )
        XCTAssertEqual(MediaRemoteAdapterParser.parse(line: "null"), .idle)
        XCTAssertNil(MediaRemoteAdapterParser.parse(line: "not json"))
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

    func testNotificationSourceDetectionRecognizesWeChatByBundleIdentifier() {
        let source = NotificationSourceDetection.detect(
            in: ["com.tencent.xinWeChat"],
            candidates: []
        )

        XCTAssertEqual(
            source,
            NotificationSourceCandidate(
                name: "微信",
                bundleIdentifier: "com.tencent.xinWeChat"
            )
        )
    }

    func testNotificationSourceDetectionUsesKnownAppNameAndGenericFallback() {
        XCTAssertEqual(
            NotificationSourceDetection.detect(
                in: ["微信", "新消息"],
                candidates: []
            ),
            NotificationSourceCandidate(
                name: "微信",
                bundleIdentifier: "com.tencent.xinWeChat"
            )
        )
        XCTAssertEqual(
            NotificationSourceDetection.detect(
                in: ["通知内容"],
                candidates: []
            ),
            NotificationSourceCandidate(name: "系统通知", bundleIdentifier: nil)
        )
        XCTAssertNil(
            NotificationSourceDetection.detect(
                in: ["电池", "80% 已充电"],
                candidates: []
            )
        )
    }

    func testNotificationPromptOptionsExposeStableSymbolsAndValues() {
        XCTAssertEqual(
            NotificationPromptIcon.allCases.map(\.symbol),
            ["sparkle", "sparkles", "bell.badge", "wand.and.stars", "leaf.fill", "heart.fill", "sun.max.fill"]
        )
        XCTAssertEqual(
            Set(NotificationPromptColor.allCases.map(\.id)).count,
            NotificationPromptColor.allCases.count
        )
        XCTAssertEqual(
            Set(NotificationPromptAnimation.allCases.map(\.id)).count,
            NotificationPromptAnimation.allCases.count
        )
    }

    func testNotificationSourceDetectionIgnoresWidgetExtensions() {
        let widgetCandidate = NotificationSourceCandidate(
            name: "CalendarWidgetExtension",
            bundleIdentifier: "com.apple.calendar.widget"
        )

        XCTAssertTrue(NotificationSourceDetection.isWidgetOrExtension(widgetCandidate))
        XCTAssertNil(
            NotificationSourceDetection.detect(
                in: ["CalendarWidgetExtension"],
                candidates: [widgetCandidate]
            )
        )
        XCTAssertNil(
            NotificationSourceDetection.detect(
                in: ["widget-local:weather", "WeatherWidget"],
                candidates: []
            )
        )
        XCTAssertTrue(
            NotificationSourceDetection.isWidgetOrExtension(
                "widget-local:com.apple.iCal:CalendarWidgetExtension"
            )
        )
    }

    private func makeBucket(
        id: String = "test",
        usedPercent: Double = 0,
        windowMinutes: Int = 60
    ) -> CodexLimitBucket {
        CodexLimitBucket(
            id: id,
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
