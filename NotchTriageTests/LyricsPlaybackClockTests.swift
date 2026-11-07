import Foundation
import XCTest
@testable import NotchTriage

final class LyricsPlaybackClockTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    private func feed(_ clock: inout LyricsPlaybackClock, at time: Double,
                      position: Double, playing: Bool = true) {
        let date = origin.addingTimeInterval(time)
        clock.update(MediaSnapshot(
            sourceName: "QQ 音乐", bundleIdentifier: "com.tencent.QQMusicMac",
            title: "Song", artist: "Artist", duration: 300, elapsed: position,
            isPlaying: playing, progressAnchorDate: date
        ), now: time, observedAt: date)
    }

    private func runningClock() -> LyricsPlaybackClock {
        var clock = LyricsPlaybackClock()
        feed(&clock, at: 0, position: 10)
        feed(&clock, at: 0.2, position: 10.2)
        return clock
    }

    func testSingleEarlySampleDoesNotPermanentlyAdvanceClock() {
        var clock = runningClock()
        feed(&clock, at: 1, position: 11.8)
        XCTAssertEqual(clock.elapsed(at: 1), 11, accuracy: 0.001)
        for time in 2...60 { feed(&clock, at: Double(time), position: 10 + Double(time)) }
        XCTAssertEqual(clock.elapsed(at: 60), 70, accuracy: 0.001)
    }

    func testAlternatingJitterDoesNotRatchetForward() {
        var clock = runningClock()
        for time in 1...60 {
            let error = time.isMultiple(of: 2) ? -0.8 : 0.8
            feed(&clock, at: Double(time), position: 10 + Double(time) + error)
            XCTAssertEqual(clock.elapsed(at: Double(time)), 10 + Double(time), accuracy: 0.001)
        }
    }

    func testPersistentSubsecondBiasConvergesInBothDirections() {
        for bias in [-0.8, 0.8] {
            var clock = runningClock()
            for time in 1...30 {
                let before = clock.elapsed(at: Double(time))
                feed(&clock, at: Double(time), position: 10 + Double(time) + bias)
                XCTAssertLessThanOrEqual(abs(clock.elapsed(at: Double(time)) - before), 0.101)
            }
            XCTAssertEqual(clock.elapsed(at: 30), 40 + bias, accuracy: 0.26)
        }
    }

    func testFrequentCorrectionsDoNotRewindCursor() {
        var clock = runningClock()
        var previous = clock.elapsed(at: 0.2)
        for tick in 1...100 {
            let time = 0.2 + Double(tick) * 0.05
            feed(&clock, at: time, position: 10 + time - 0.8)
            let current = clock.elapsed(at: time)
            XCTAssertGreaterThanOrEqual(current, previous)
            previous = current
        }
    }

    func testLargeSeekWaitsForProgressThenUsesNewTimeline() {
        var clock = runningClock()
        feed(&clock, at: 1, position: 80)
        XCTAssertFalse(clock.isAdvancing)
        feed(&clock, at: 1.5, position: 80.5)
        XCTAssertTrue(clock.isAdvancing)
        XCTAssertEqual(clock.elapsed(at: 2), 81, accuracy: 0.001)
    }

    func testPauseAndResumeWaitsForFreshProgress() {
        var clock = runningClock()
        feed(&clock, at: 1, position: 11, playing: false)
        XCTAssertFalse(clock.isAdvancing)
        XCTAssertEqual(clock.elapsed(at: 3), 11, accuracy: 0.001)
        feed(&clock, at: 3, position: 11)
        XCTAssertFalse(clock.isAdvancing)
        feed(&clock, at: 3.5, position: 11.5)
        XCTAssertTrue(clock.isAdvancing)
        XCTAssertEqual(clock.elapsed(at: 4), 12, accuracy: 0.001)
    }
}
