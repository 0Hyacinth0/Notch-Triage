import Foundation

/// Advance on a monotonic clock. A single late media reading must not rewind
/// the karaoke cursor during ordinary playback.
struct LyricsPlaybackClock {
    private enum SourceTier { case precise, clean, quantized }
    private var position: Double = 0
    private var uptime: Double = ProcessInfo.processInfo.systemUptime
    private var rate: Double = 0
    private var duration: Double = 0
    private var identity = ""
    private var lastObserved: Double = 0
    private var pendingSeek: (difference: Double, startedAt: Double)?
    private var driftAverage: Double = 0
    private var driftSamples = 0
    private var sourceTier: SourceTier = .clean
    // A player may report `playing` as soon as the user seeks, while audio is
    // still buffering. Do not extrapolate from that flag until its reported
    // position has actually advanced beyond the seek destination.
    private var awaitingProgressAfterSeek: (position: Double, startedAt: Double)?
    private static let maximumSeekHold: Double = 2
    var isAdvancing: Bool { rate > 0 }
    func remainingSeekHold(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double? {
        // Player-owned and quantized clocks can supply a fresh reading after
        // the seek. A timer is no proof that their buffering has finished.
        if sourceTier != .clean { return nil }
        return awaitingProgressAfterSeek.map { max(0, Self.maximumSeekHold - (now - $0.startedAt)) }
    }
    mutating func resumeIfSeekHoldExpired(
        from media: MediaSnapshot,
        now: Double = ProcessInfo.processInfo.systemUptime,
        observedAt: Date = Date()
    ) -> Bool {
        guard sourceTier == .clean, media.isPlaying, let waiting = awaitingProgressAfterSeek,
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
        let isQQOrNetEase = media.bundleIdentifier?.lowercased().contains("qqmusic") == true
            || media.bundleIdentifier?.lowercased().contains("netease") == true
        let precise = media.positionSource == .playerScript
        sourceTier = precise ? .precise
            : (isQQOrNetEase || media.positionSource == .metadataOnly) ? .quantized : .clean
        let seekThreshold = precise ? 0.85 : isQQOrNetEase ? 2.5 : 1.5
        let correctionThreshold = precise ? 0.18 : isQQOrNetEase ? 0.95 : 0.45
        // A refreshed timestamp with an unchanged raw position is not a new
        // playback reading. Treating it as one made a stale value look like a
        // seek backwards after the local clock had advanced for a few seconds.
        let changedObservation = abs(media.elapsed - lastObserved) > 0.015
        if trackChanged || key != identity {
            position = max(0, media.elapsed); pendingSeek = nil
            awaitingProgressAfterSeek = (media.elapsed, now)
            driftAverage = 0; driftSamples = 0
        } else if let waiting = awaitingProgressAfterSeek {
                let progress = media.elapsed - waiting.position
                let maximumPlausibleProgress = max(2, (now - waiting.startedAt) * max(1, nextRate) * 1.5 + 0.75)
                if progress < -0.5 || progress > maximumPlausibleProgress {
                    // Another seek happened before the previous destination loaded.
                    position = max(0, media.elapsed)
                    awaitingProgressAfterSeek = (media.elapsed, now)
                } else if nextRate > 0, changedObservation, progress > (precise ? 0.03 : 0.12) {
                    position = observed
                    awaitingProgressAfterSeek = nil
                } else if nextRate == 0 {
                    position = max(0, media.elapsed)
                    awaitingProgressAfterSeek = (media.elapsed, now)
                } else {
                    position = max(0, waiting.position)
                }
        } else if nextRate > 0, rate == 0, !changedObservation {
            // The transport can announce playing before the audio has landed.
            position = max(0, media.elapsed)
            awaitingProgressAfterSeek = (media.elapsed, now)
        } else if !changedObservation {
            position = predicted
        } else if abs(delta) >= 5 {
            // A large jump is a seek or a replay of the same track.
            position = max(0, media.elapsed); pendingSeek = nil
            awaitingProgressAfterSeek = (media.elapsed, now)
            driftAverage = 0; driftSamples = 0
        } else if nextRate == 0 {
            position = observed; pendingSeek = nil
            driftAverage = 0; driftSamples = 0
            if abs(media.elapsed - lastObserved) >= 0.5 {
                awaitingProgressAfterSeek = (media.elapsed, now)
            }
        } else if abs(delta) >= seekThreshold {
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
                driftAverage = 0; driftSamples = 0
            } else {
                position = predicted
                pendingSeek = (delta, now)
            }
        } else {
            if sourceTier == .quantized, delta > 0.05, delta < 1.5 {
                // A floored clock can lag the real player, but a fresh reading
                // ahead of our estimate proves the estimate is behind.
                position = observed
                driftAverage = 0; driftSamples = 0; pendingSeek = nil
                rate = nextRate
                identity = key; uptime = now; duration = media.duration
                lastObserved = media.elapsed
                return
            }
            // A single remote reading may be noisy; a persistent same-sign
            // difference is a real clock bias. Correct only after repeated
            // observations, using a tighter threshold for player-owned clocks.
            driftAverage = driftAverage * 0.7 + delta * 0.3
            driftSamples += 1
            if driftSamples >= 2, abs(driftAverage) >= correctionThreshold {
                let maximumStep = precise ? 0.16 : isQQOrNetEase ? 0.10 : 0.12
                position = max(0, predicted + min(maximumStep, max(-maximumStep, driftAverage * 0.3)))
            } else {
                position = predicted
            }
            pendingSeek = nil
        }
        rate = awaitingProgressAfterSeek == nil ? nextRate : 0
        identity = key; uptime = now; duration = media.duration
        lastObserved = media.elapsed
    }
    func elapsed(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        let value = max(0, position + max(0, now - uptime) * rate)
        return duration > 0 ? min(duration, value) : value
    }
}
