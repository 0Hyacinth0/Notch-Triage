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
    private var pendingSeek: Double?
    mutating func update(_ media: MediaSnapshot, trackChanged: Bool = false, identity trackIdentity: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let key = trackIdentity ?? "\(media.title)|\(media.artist)"
        if !trackChanged, key == identity, let timestamp = media.progressAnchorDate, let lastTimestamp, timestamp < lastTimestamp { return }
        let observed = media.estimatedElapsed()
        let nextRate = media.isPlaying ? max(0, media.playbackRate ?? 1) : 0
        let predicted = elapsed(at: now)
        let delta = observed - predicted
        if trackChanged || key != identity || nextRate != reportedRate {
            position = observed; pendingSeek = nil; rate = nextRate
        } else if abs(delta) <= 1.25 {
            // Correct small, often rounded source offsets by changing speed slightly,
            // rather than jumping backwards across words at every poll.
            position = predicted; rate = nextRate == 0 ? 0 : nextRate * (1 + max(-0.08, min(0.08, delta * 0.12)))
            pendingSeek = nil
        } else if let pendingSeek, abs(delta - pendingSeek) < 0.75, nextRate == 0 || abs(observed - lastObserved) > 0.02 {
            // A seek needs a second advancing observation. A repeated stale position
            // or one delayed fallback snapshot cannot make the display jump back.
            position = observed; self.pendingSeek = nil; rate = nextRate
        } else {
            position = predicted; pendingSeek = delta; rate = nextRate
        }
        identity = key; uptime = now; reportedRate = nextRate; duration = media.duration
        lastTimestamp = media.progressAnchorDate; lastObserved = observed
    }
    func elapsed(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        let value = max(0, position + max(0, now - uptime) * rate)
        return duration > 0 ? min(duration, value) : value
    }
}
