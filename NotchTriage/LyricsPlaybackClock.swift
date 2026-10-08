import Foundation

/// Anchor once against the media timestamp, then advance on the monotonic
/// clock. Display frames must not accumulate polling or wall-clock drift.
struct LyricsPlaybackClock {
    private var position: Double = 0
    private var uptime: Double = ProcessInfo.processInfo.systemUptime
    private var rate: Double = 0
    private var duration: Double = 0
    private var identity = ""
    mutating func update(_ media: MediaSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        let observed = media.estimatedElapsed()
        let key = "\(media.title)|\(media.artist)|\(media.album)"
        let nextRate = media.isPlaying ? max(0, media.playbackRate ?? 1) : 0
        let predicted = elapsed(at: now)
        // Small timestamp jitter is smoothed; seeking, pausing and switching
        // tracks always replace the anchor immediately.
        position = key == identity && nextRate == rate && abs(predicted - observed) < 0.12 ? predicted * 0.7 + observed * 0.3 : observed
        identity = key; uptime = now; rate = nextRate; duration = media.duration
    }
    func elapsed(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        let value = max(0, position + max(0, now - uptime) * rate)
        return duration > 0 ? min(duration, value) : value
    }
}
