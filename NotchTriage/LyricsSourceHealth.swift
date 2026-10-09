import Foundation

/// Prevents a broken service from extending every track lookup by its timeout.
/// Successful responses, including a genuine empty result, clear its failures.
actor LyricsSourceHealth {
    static let shared = LyricsSourceHealth()
    private struct State {
        var consecutiveFailures = 0
        var retryAfter = Date.distantPast
    }
    private var states: [LyricsSourceID: State] = [:]

    func allows(_ source: LyricsSourceID) -> Bool {
        Date() >= (states[source]?.retryAfter ?? .distantPast)
    }

    func record(_ source: LyricsSourceID, failed: Bool) {
        guard failed else { states[source] = nil; return }
        var state = states[source] ?? State()
        state.consecutiveFailures += 1
        if state.consecutiveFailures >= 3 {
            let seconds = min(300, 30 * (1 << min(3, state.consecutiveFailures - 3)))
            state.retryAfter = Date().addingTimeInterval(TimeInterval(seconds))
        }
        states[source] = state
    }

    func reset() { states.removeAll() }
}
