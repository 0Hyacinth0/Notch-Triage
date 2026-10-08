import Foundation

/// Advance on a monotonic clock; polling jitter must not rewind the karaoke cursor.
struct LyricsPlaybackClock {
    private var position: Double = 0
    private var uptime: Double = ProcessInfo.processInfo.systemUptime
    private var rate: Double = 0
    private var reportedRate: Double = 0
    private var duration: Double = 0
    private var identity = ""
    private var lastTimestamp: Date?
    private var lastObserved: Double = 0
    mutating func update(_ media: MediaSnapshot, trackChanged: Bool = false, identity trackIdentity: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let key = trackIdentity ?? "\(media.title)|\(media.artist)"
        let observed = media.estimatedElapsed()
        let nextRate = media.isPlaying ? max(0, media.playbackRate ?? 1) : 0
        let predicted = elapsed(at: now)
        let delta = observed - predicted
        let changedObservation = media.progressAnchorDate != lastTimestamp || abs(media.elapsed - lastObserved) > 0.001
        if trackChanged || key != identity || nextRate != reportedRate || (changedObservation && abs(delta) >= 0.75) {
            // A changed playback anchor can move backwards on a seek. Apply a
            // real position jump immediately in either direction.
            position = observed; rate = nextRate
        } else if changedObservation {
            position = predicted + max(-0.12, min(0.12, delta * 0.25))
            rate = nextRate
        } else {
            // Repeated snapshots carry no new timing information.
            position = predicted; rate = nextRate
        }
        identity = key; uptime = now; reportedRate = nextRate; duration = media.duration
        lastTimestamp = media.progressAnchorDate; lastObserved = media.elapsed
    }
    func elapsed(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        let value = max(0, position + max(0, now - uptime) * rate)
        return duration > 0 ? min(duration, value) : value
    }
}
