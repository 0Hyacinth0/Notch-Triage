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
            position = observed; pendingSeek = nil
        } else if !changedObservation {
            position = predicted
        } else if abs(delta) >= 5 {
            // A large jump is a seek or a replay of the same track.
            position = observed; pendingSeek = nil
        } else if nextRate == 0 {
            position = observed; pendingSeek = nil
        } else if abs(delta) >= 2.5 {
            // Some players report progress with roughly two seconds of jitter.
            // A moderate seek needs two independent, consistent observations;
            // a single late reading must not shift the lyrics.
            if let pendingSeek,
               now - pendingSeek.startedAt >= 0.5,
               now - pendingSeek.startedAt < 12,
               delta.sign == pendingSeek.difference.sign,
               abs(delta - pendingSeek.difference) < 0.75 {
                position = observed
                self.pendingSeek = nil
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
        rate = nextRate
        identity = key; uptime = now; duration = media.duration
        lastTimestamp = media.progressAnchorDate; lastObserved = media.elapsed
    }
    func elapsed(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        let value = max(0, position + max(0, now - uptime) * rate)
        return duration > 0 ? min(duration, value) : value
    }
}
