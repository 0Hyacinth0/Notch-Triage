import Foundation

/// Main-actor coordinator for opt-in Clipboard History polling.
///
/// The monitor does not own history and never clears the system pasteboard.
/// It only establishes change-count baselines, asks ``PasteboardAccess`` for a
/// normalized payload after a change, and forwards that payload to its owner.
@MainActor
final class ClipboardMonitor {
    typealias PayloadHandler = @MainActor (ClipboardPayload, Int) -> Void
    typealias Sleeper = @Sendable (Duration) async -> Void

    private enum Lifecycle {
        case stopped
        case running
        case suspended
    }

    private let access: any PasteboardAccess
    private let pollInterval: Duration
    private let sleeper: Sleeper
    private let onPayload: PayloadHandler

    private var lifecycle: Lifecycle = .stopped
    private var baselineChangeCount: Int?
    private var pollingTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var selfWriteChangeCounts: Set<Int> = []

    nonisolated private static let defaultSleeper: Sleeper = { duration in
        try? await Task.sleep(for: duration)
    }

    init(
        access: any PasteboardAccess,
        pollInterval: Duration = .milliseconds(500),
        onPayload: @escaping PayloadHandler,
        sleeper: @escaping Sleeper = ClipboardMonitor.defaultSleeper
    ) {
        self.access = access
        self.pollInterval = pollInterval
        self.sleeper = sleeper
        self.onPayload = onPayload
    }

    /// Exact public surface used by production call sites.  The sleeper-aware
    /// overload above remains available to deterministic tests without making
    /// callers know about the implementation hook.
    convenience init(
        access: any PasteboardAccess,
        pollInterval: Duration = .milliseconds(500),
        onPayload: @escaping PayloadHandler
    ) {
        self.init(
            access: access,
            pollInterval: pollInterval,
            onPayload: onPayload,
            sleeper: ClipboardMonitor.defaultSleeper
        )
    }

    /// Starts monitoring after taking a baseline.  The baseline read is the
    /// only pasteboard access performed synchronously by this method; payload
    /// contents are not read until a later change-count transition.
    func start() {
        guard lifecycle != .running else { return }

        pollingTask?.cancel()
        pollingTask = nil
        generation &+= 1
        let taskGeneration = generation

        lifecycle = .running
        baselineChangeCount = access.changeCount
        // A new baseline means a write registered before enabling is already
        // represented by the baseline and should not suppress a future event.
        selfWriteChangeCounts.removeAll(keepingCapacity: true)

        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.runPolling(generation: taskGeneration)
        }
    }

    /// Stops polling and invalidates every previously-created generation.
    /// Cancelling the task alone is insufficient when an injected test sleeper
    /// ignores cancellation, so all callbacks also verify ``generation``.
    func stop() {
        generation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        lifecycle = .stopped
        baselineChangeCount = nil
        selfWriteChangeCounts.removeAll(keepingCapacity: false)
    }

    /// Pauses without reading the pasteboard.  Content copied while suspended
    /// is intentionally not replayed after resume.
    func suspend() {
        guard lifecycle == .running else { return }

        generation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        lifecycle = .suspended
        baselineChangeCount = nil
        selfWriteChangeCounts.removeAll(keepingCapacity: false)
    }

    /// Resumes with a fresh baseline.  Existing content at the time of resume
    /// is considered already observed, so no payload is emitted for it.
    func resume() {
        guard lifecycle == .suspended else { return }

        generation &+= 1
        let taskGeneration = generation
        lifecycle = .running
        baselineChangeCount = access.changeCount
        selfWriteChangeCounts.removeAll(keepingCapacity: true)

        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.runPolling(generation: taskGeneration)
        }
    }

    /// Registers the change count produced by an explicit user-triggered
    /// write.  The matching change is consumed once and never forwarded as
    /// history; later, distinct changes continue to be observed normally.
    func registerSelfWrite(changeCount: Int) {
        selfWriteChangeCounts.insert(changeCount)
    }

    /// Useful for lifecycle tests and diagnostics without exposing the task or
    /// pasteboard itself.  This intentionally does not read ``changeCount``.
    var isRunning: Bool {
        lifecycle == .running
    }

    private func runPolling(generation taskGeneration: UInt64) async {
        while !Task.isCancelled {
            await sleeper(pollInterval)
            guard !Task.isCancelled else { return }
            pollOnce(generation: taskGeneration)
        }
    }

    private func pollOnce(generation taskGeneration: UInt64) {
        guard taskGeneration == generation, lifecycle == .running else {
            return
        }

        let currentChangeCount = access.changeCount
        guard let baselineChangeCount,
              currentChangeCount != baselineChangeCount else {
            return
        }

        // Advance the baseline before reading.  A malformed or unsupported
        // payload is still an observed change and should not be retried every
        // half second.
        self.baselineChangeCount = currentChangeCount

        if selfWriteChangeCounts.remove(currentChangeCount) != nil {
            return
        }

        guard taskGeneration == generation, lifecycle == .running,
              let payload = access.readPayload() else {
            return
        }
        guard taskGeneration == generation, lifecycle == .running else {
            return
        }
        onPayload(payload, currentChangeCount)
    }

}
