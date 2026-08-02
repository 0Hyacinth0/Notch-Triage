import AppKit
import Foundation

@MainActor
final class BackgroundRefreshScheduler {
    enum JobID: String, CaseIterable {
        case notifications
        case media
        case power
        case trash
        case codex
        case brightness
        case updates
    }

    struct Job {
        let id: JobID
        let compactInterval: TimeInterval
        let interactiveInterval: TimeInterval
        let refreshOnResume: Bool
        let action: @MainActor () -> Void

        init(
            id: JobID,
            compactInterval: TimeInterval,
            interactiveInterval: TimeInterval,
            refreshOnResume: Bool = true,
            action: @escaping @MainActor () -> Void
        ) {
            self.id = id
            self.compactInterval = compactInterval
            self.interactiveInterval = interactiveInterval
            self.refreshOnResume = refreshOnResume
            self.action = action
        }
    }

    private struct ScheduledJob {
        let job: Job
        var nextFireUptime: TimeInterval
    }

    private var jobs: [ScheduledJob]
    private var timer: Timer?
    private(set) var isSuspended = false
    private(set) var isInteractive = false
    private var isStarted = false

    init(jobs: [Job]) {
        let now = ProcessInfo.processInfo.systemUptime
        self.jobs = jobs.map {
            ScheduledJob(
                job: $0,
                nextFireUptime: now + $0.compactInterval
            )
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        scheduleNextTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isStarted = false
    }

    func setInteractive(_ interactive: Bool) {
        guard isInteractive != interactive else { return }
        isInteractive = interactive

        let now = ProcessInfo.processInfo.systemUptime
        for index in jobs.indices {
            jobs[index].nextFireUptime = min(
                jobs[index].nextFireUptime,
                now + interval(for: jobs[index].job)
            )
        }
        scheduleNextTimer()
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        timer?.invalidate()
        timer = nil

        guard !suspended else { return }
        refreshAfterResume()
    }

    func refreshAll() {
        guard !isSuspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for index in jobs.indices {
            jobs[index].job.action()
            jobs[index].nextFireUptime = now + interval(for: jobs[index].job)
        }
        scheduleNextTimer()
    }

    func reschedule(_ id: JobID, after delay: TimeInterval) {
        guard let index = jobs.firstIndex(where: { $0.job.id == id }) else { return }
        let requestedFire = ProcessInfo.processInfo.systemUptime + max(1, delay)
        jobs[index].nextFireUptime = min(
            jobs[index].nextFireUptime,
            requestedFire
        )
        scheduleNextTimer()
    }

    private func refreshAfterResume() {
        let now = ProcessInfo.processInfo.systemUptime
        for index in jobs.indices {
            if jobs[index].job.refreshOnResume {
                jobs[index].job.action()
            }
            jobs[index].nextFireUptime = now + interval(for: jobs[index].job)
        }
        scheduleNextTimer()
    }

    private func fireDueJobs() {
        guard isStarted, !isSuspended else { return }
        let now = ProcessInfo.processInfo.systemUptime

        for index in jobs.indices where jobs[index].nextFireUptime <= now + 0.05 {
            jobs[index].job.action()
            jobs[index].nextFireUptime = now + interval(for: jobs[index].job)
        }
        scheduleNextTimer()
    }

    private func scheduleNextTimer() {
        timer?.invalidate()
        timer = nil
        guard isStarted, !isSuspended,
              let nextFire = jobs.map(\.nextFireUptime).min() else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0.1, nextFire - now)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fireDueJobs()
            }
        }
        timer.tolerance = min(0.75, max(0.15, delay * 0.2))
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func interval(for job: Job) -> TimeInterval {
        isInteractive ? job.interactiveInterval : job.compactInterval
    }
}

@MainActor
final class AppActivityMonitor {
    enum SuspensionReason: Hashable {
        case sessionInactive
        case screenAsleep
        case systemAsleep
    }

    private let onSuspensionChanged: @MainActor (Bool, String) -> Void
    private var observers: [NSObjectProtocol] = []
    private var reasons = Set<SuspensionReason>()

    init(onSuspensionChanged: @escaping @MainActor (Bool, String) -> Void) {
        self.onSuspensionChanged = onSuspensionChanged
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, reason: .systemAsleep, suspended: true, center: center)
        observe(NSWorkspace.didWakeNotification, reason: .systemAsleep, suspended: false, center: center)
        observe(NSWorkspace.screensDidSleepNotification, reason: .screenAsleep, suspended: true, center: center)
        observe(NSWorkspace.screensDidWakeNotification, reason: .screenAsleep, suspended: false, center: center)
        observe(NSWorkspace.sessionDidResignActiveNotification, reason: .sessionInactive, suspended: true, center: center)
        observe(NSWorkspace.sessionDidBecomeActiveNotification, reason: .sessionInactive, suspended: false, center: center)
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        reasons.removeAll()
    }

    private func observe(
        _ name: NSNotification.Name,
        reason: SuspensionReason,
        suspended: Bool,
        center: NotificationCenter
    ) {
        observers.append(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.set(reason, active: suspended)
                }
            }
        )
    }

    private func set(_ reason: SuspensionReason, active: Bool) {
        let wasSuspended = !reasons.isEmpty
        if active {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        let isSuspended = !reasons.isEmpty
        guard wasSuspended != isSuspended else { return }
        onSuspensionChanged(
            isSuspended,
            isSuspended ? "屏幕锁定或系统休眠" : "会话恢复"
        )
    }
}
