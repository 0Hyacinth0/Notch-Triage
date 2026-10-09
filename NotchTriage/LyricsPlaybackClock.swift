import Foundation

/// Advance on a monotonic clock. A single late media reading must not rewind
/// the karaoke cursor during ordinary playback.
struct LyricsPlaybackClock {
    private var position: Double = 0
    private var uptime: Double = ProcessInfo.processInfo.systemUptime
    private var rate: Double = 0
    private var duration: Double = 0
    private var identity = ""
    private var lastTimestamp: Date?
    private var lastObserved: Double = 0
    private var pendingSeek: (difference: Double, startedAt: Double)?
    private var lastReportedRate: Double = 0
    // A player may report `playing` as soon as the user seeks, while audio is
    // still buffering. Do not extrapolate from that flag until its reported
    // position has actually advanced beyond the seek destination.
    private var awaitingProgressAfterSeek: (position: Double, startedAt: Double)?
    private static let maximumSeekHold: Double = 2
    var isAdvancing: Bool { rate > 0 }
    func remainingSeekHold(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double? {
        awaitingProgressAfterSeek.map { max(0, Self.maximumSeekHold - (now - $0.startedAt)) }
    }
    mutating func resumeIfSeekHoldExpired(
        from media: MediaSnapshot,
        now: Double = ProcessInfo.processInfo.systemUptime,
        observedAt: Date = Date()
    ) -> Bool {
        guard media.isPlaying, let waiting = awaitingProgressAfterSeek,
              now - waiting.startedAt >= Self.maximumSeekHold else { return false }
        // Some media sources never publish another raw elapsed value after a
        // seek. Resume from the player's reported timeline so the hold does
        // not make lyrics permanently late by its own duration.
        position = media.estimatedElapsed(at: observedAt)
        uptime = now
        rate = max(0, media.playbackRate ?? 1)
        awaitingProgressAfterSeek = nil
        return true
    }
    mutating func update(
        _ media: MediaSnapshot,
        trackChanged: Bool = false,
        identity trackIdentity: String? = nil,
        now: Double = ProcessInfo.processInfo.systemUptime,
        observedAt: Date = Date()
    ) {
        let key = trackIdentity ?? "\(media.title)|\(media.artist)"
        let observed = media.estimatedElapsed(at: observedAt)
        let nextRate = media.isPlaying ? max(0, media.playbackRate ?? 1) : 0
        let predicted = elapsed(at: now)
        let delta = observed - predicted
        let changedObservation = media.progressAnchorDate != lastTimestamp || abs(media.elapsed - lastObserved) > 0.001
        if trackChanged || key != identity {
            position = max(0, media.elapsed); pendingSeek = nil
            awaitingProgressAfterSeek = (media.elapsed, now)
        } else if let waiting = awaitingProgressAfterSeek {
            if lastReportedRate == 0, nextRate > 0 {
                // A real paused-to-playing transition is stronger evidence
                // that loading finished than an unchanged elapsed field.
                position = observed
                awaitingProgressAfterSeek = nil
            } else {
                let progress = media.elapsed - waiting.position
                let maximumPlausibleProgress = max(2, (now - waiting.startedAt) * max(1, nextRate) * 1.5 + 0.75)
                if progress < -0.5 || progress > maximumPlausibleProgress {
                    // Another seek happened before the previous destination loaded.
                    position = max(0, media.elapsed)
                    awaitingProgressAfterSeek = (media.elapsed, now)
                } else if nextRate > 0, changedObservation, progress > 0.12 {
                    position = observed
                    awaitingProgressAfterSeek = nil
                } else if nextRate == 0 {
                    position = max(0, media.elapsed)
                    awaitingProgressAfterSeek = (media.elapsed, now)
                } else {
                    position = max(0, waiting.position)
                }
            }
        } else if !changedObservation {
            position = predicted
        } else if abs(delta) >= 5 {
            // A large jump is a seek or a replay of the same track.
            position = max(0, media.elapsed); pendingSeek = nil
            awaitingProgressAfterSeek = (media.elapsed, now)
        } else if nextRate == 0 {
            position = observed; pendingSeek = nil
            if abs(media.elapsed - lastObserved) >= 0.5 {
                awaitingProgressAfterSeek = (media.elapsed, now)
            }
        } else if abs(delta) >= 2.5 {
            // Some players report progress with roughly two seconds of jitter.
            // A moderate seek needs two independent, consistent observations;
            // a single late reading must not shift the lyrics.
            if let pendingSeek,
               now - pendingSeek.startedAt >= 0.5,
               now - pendingSeek.startedAt < 12,
               delta.sign == pendingSeek.difference.sign,
               abs(delta - pendingSeek.difference) < 0.75 {
                position = max(0, media.elapsed)
                self.pendingSeek = nil
                awaitingProgressAfterSeek = (media.elapsed, now)
            } else {
                position = predicted
                pendingSeek = (delta, now)
            }
        } else {
            // Small discrepancies are source jitter. Speeding up or slowing
            // down to chase them can make karaoke words drift after a seek.
            position = predicted
            pendingSeek = nil
        }
        rate = awaitingProgressAfterSeek == nil ? nextRate : 0
        lastReportedRate = nextRate
        identity = key; uptime = now; duration = media.duration
        lastTimestamp = media.progressAnchorDate; lastObserved = media.elapsed
    }
    func elapsed(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        let value = max(0, position + max(0, now - uptime) * rate)
        return duration > 0 ? min(duration, value) : value
    }
}
