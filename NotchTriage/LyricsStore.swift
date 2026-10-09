import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum LyricsAnimation: String, Codable, CaseIterable {
    case sweep, wave, dock
    var title: String {
        switch self { case .sweep: return "从左到右渐进"; case .wave: return "逐字光波"; case .dock: return "程序坞放大" }
    }
}
enum LyricsLightPreset: String, Codable, CaseIterable {
    case aurora, moonlight, amber, clean, custom
    var title: String {
        switch self {
        case .aurora: return "极光"
        case .moonlight: return "月光"
        case .amber: return "暖金"
        case .clean: return "清晰"
        case .custom: return "自定义"
        }
    }
    var colors: (RingColor, RingColor) {
        switch self {
        case .aurora: return (RingColor(red: 0.25, green: 0.91, blue: 1), RingColor(red: 0.62, green: 0.57, blue: 1))
        case .moonlight: return (RingColor(red: 0.73, green: 0.85, blue: 1), RingColor(red: 0.87, green: 0.93, blue: 1))
        case .amber: return (RingColor(red: 1, green: 0.78, blue: 0.37), RingColor(red: 1, green: 0.51, blue: 0.39))
        case .clean, .custom: return (.white, .white)
        }
    }
}
enum LyricsVisualStyle: String, Codable, CaseIterable {
    case classic, elastic, flowing
    var title: String {
        switch self {
        case .classic: return "经典流光"
        case .elastic: return "弹性流光"
        case .flowing: return "流动亮芯"
        }
    }
    var detail: String {
        switch self {
        case .classic: return "逐字覆盖颜色与柔光，跟随所选动画跳动。"
        case .elastic: return "唱到的字明显放大、拉伸并回弹，扫光与辉光同步移动。"
        case .flowing: return "亮芯在字形内流动，柔光贴着笔画边缘。"
        }
    }
}
enum LyricsOrnamentStyle: String, Codable, CaseIterable {
    case spectrum, waveform, ripple
    var title: String { switch self { case .spectrum: return "柔光频谱"; case .waveform: return "流动波形"; case .ripple: return "水波纹" } }
}
struct LyricsAppearance: Codable, Equatable {
    var enabled = false
    var fontFamily = "System"
    var fontSize: Double = 28
    var highlight = LyricsLightPreset.aurora.colors.0
    var resting = RingColor(red: 0.87, green: 0.9, blue: 0.96, opacity: 0.65)
    var glow: Double = 0.55
    var lift: Double = 7
    var width: Double = 620
    var gap: Double = 4
    var offset: Double = 0
    var motion: LyricsAnimation = .dock
    var showNext = true
    // Optional storage preserves settings saved before Dock animation existed.
    var dockScale: Double? = nil
    var lightPreset: LyricsLightPreset? = .aurora
    // Optional so preferences written by earlier releases keep their look.
    var visualStyle: LyricsVisualStyle? = nil
    var glowEnd: RingColor? = LyricsLightPreset.aurora.colors.1
    var glowSpread: Double? = 0.55
    var breathing: Bool? = true
    var ornaments: Bool? = false
    var ornamentStyle: LyricsOrnamentStyle? = .spectrum
    var ornamentGap: Double? = 18
    var ornamentWidth: Double? = 64
    var ornamentHeight: Double? = 36
    var spectrumEnabled: Bool? = false
    var ornament: LyricsOrnamentStyle { ornamentStyle ?? .spectrum }
    var sideGap: Double { max(0, min(160, ornamentGap ?? 18)) }
    var sideWidth: Double { max(24, min(180, ornamentWidth ?? 64)) }
    var sideHeight: Double { max(8, min(120, ornamentHeight ?? 36)) }
    var capturesSpectrum: Bool { spectrumEnabled ?? false }
    var ornamentSpace: Double { hasOrnaments ? (sideWidth + sideGap) * 2 : 0 }
    var chineseVariant: LyricsChineseVariant? = .simplified
    var estimatedAnimation: Bool? = false
    var showTranslation: Bool? = false
    var showRomanization: Bool? = false
    var variant: LyricsChineseVariant { chineseVariant ?? .simplified }
    var usesEstimatedTiming: Bool { estimatedAnimation ?? false }
    var showsTranslation: Bool { showTranslation ?? false }
    var showsRomanization: Bool { showRomanization ?? false }
    var spread: Double { max(0, min(1, glowSpread ?? 0.45)) }
    var style: LyricsVisualStyle { visualStyle ?? .classic }
    var hasBreathing: Bool { breathing ?? false }
    var hasOrnaments: Bool { ornaments ?? false }
    var endColor: RingColor { glowEnd ?? highlight }
    var outerGlowRadius: Double { glow > 0 ? (4 + fontSize * (0.12 + spread * 0.3)) : 0 }
    mutating func apply(_ preset: LyricsLightPreset) {
        lightPreset = preset
        highlight = preset.colors.0; glowEnd = preset.colors.1
        resting = RingColor(red: 0.87, green: 0.9, blue: 0.96, opacity: preset == .clean ? 0.5 : 0.62)
        glow = preset == .clean ? 0 : preset == .aurora ? 0.65 : 0.4
        glowSpread = preset == .aurora ? 0.6 : 0.4
        breathing = preset != .clean
    }
    var dockAmount: Double { max(0.1, min(1.2, dockScale ?? 0.55)) }
    var font: NSFont {
        let size = max(8, min(120, fontSize))
        return fontFamily == "System" ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: fontFamily]), size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }
}

@MainActor final class LyricsStore: ObservableObject {
    @Published var sourcePreferences: LyricsSourcePreferences { didSet {
        if let data = try? JSONEncoder().encode(sourcePreferences) {
            UserDefaults.standard.set(data, forKey: "NotchTriage.Lyrics.sourcePreferences")
        }
        if running, appearance.enabled { receive(media, force: true) }
    } }
    @Published var appearance: LyricsAppearance { didSet {
        if let data = try? JSONEncoder().encode(appearance) { UserDefaults.standard.set(data, forKey: "NotchTriage.Lyrics.appearance") }
        updateSpectrum()
        updateClockRecovery()
        if oldValue.enabled != appearance.enabled {
            if appearance.enabled { receive(media, force: true) } else { request?.cancel(); upgradeTask?.cancel(); upgradeTask = nil; document = nil; status = "歌词显示已关闭" }
        }
    } }
    @Published private(set) var document: LyricsDocument?
    @Published private(set) var candidates: [LyricsDocument] = []
    @Published private(set) var sourceStatus: [LyricsSourceID: String] = [:]
    @Published private(set) var media = MediaSnapshot.idle
    @Published private(set) var status = "歌词显示已关闭"
    @Published private(set) var rematchFeedback: String?
    @Published private(set) var previewing = false
    let spectrum = LyricsSpectrum()
    private var request: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var generation = UUID()
    private var key = ""
    private var running = false
    private var suspended = false
    private var spectrumVisible = false
    private var clock = LyricsPlaybackClock()
    private var clockRecoveryTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    private var localCacheTask: Task<Void, Never>?
    private var upgradeAttempts = 0
    private var cachedTrackMedia: MediaSnapshot?
    private var cache: [String: LyricsDocument] = [:]
    private var pinnedSelections: [String: String] = [:]
    private let cacheURL: URL

    init() {
        let data = UserDefaults.standard.data(forKey: "NotchTriage.Lyrics.appearance")
        appearance = data.flatMap { try? JSONDecoder().decode(LyricsAppearance.self, from: $0) } ?? LyricsAppearance()
        let sourceData = UserDefaults.standard.data(forKey: "NotchTriage.Lyrics.sourcePreferences")
        sourcePreferences = sourceData.flatMap { try? JSONDecoder().decode(LyricsSourcePreferences.self, from: $0) } ?? LyricsSourcePreferences()
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchTriage/lyrics.json")
        if let data = try? Data(contentsOf: cacheURL), data.count < 8_000_000 { cache = (try? JSONDecoder().decode([String: LyricsDocument].self, from: data)) ?? [:] }
        if let data = UserDefaults.standard.data(forKey: "NotchTriage.Lyrics.pinnedSelections") {
            pinnedSelections = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
    }
    func start() { running = true; updateSpectrum(); updateClockRecovery() }
    func resetForPlayerSwitch() {
        idleTask?.cancel(); idleTask = nil
        upgradeTask?.cancel(); upgradeTask = nil
        localCacheTask?.cancel(); localCacheTask = nil
        request?.cancel(); request = nil
        generation = UUID()
        media = .idle; document = nil; candidates = []; sourceStatus = [:]
        key = ""; cachedTrackMedia = nil
        clock.update(.idle, trackChanged: true)
        updateClockRecovery(); updateSpectrum()
        status = "等待正在播放的歌曲"
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        updateSpectrum()
        updateClockRecovery()
        if value { request?.cancel(); idleTask?.cancel(); idleTask = nil; upgradeTask?.cancel(); upgradeTask = nil; localCacheTask?.cancel(); localCacheTask = nil } else if appearance.enabled { receive(media, force: document?.hasWordTiming != true) }
    }
    func stop() { running = false; clockRecoveryTask?.cancel(); clockRecoveryTask = nil; upgradeTask?.cancel(); upgradeTask = nil; localCacheTask?.cancel(); localCacheTask = nil; idleTask?.cancel(); idleTask = nil; spectrum.stop(); request?.cancel(); previewTask?.cancel(); previewing = false }
    var canSynchronize: Bool { media.duration > 0 }
    var isPlaybackProgressing: Bool { clock.isAdvancing }
    var progressSourceLabel: String {
        switch media.positionSource {
        case .playerScript: return "播放器播放头"
        case .mediaRemote: return "系统媒体进度"
        case .metadataOnly: return "仅歌曲信息，等待进度"
        }
    }
    func elapsed(at date: Date) -> Double { clock.elapsed() + appearance.offset }
    func receive(_ snapshot: MediaSnapshot, force: Bool = false) {
        var snapshot = snapshot
        if snapshot.duration > 0, snapshot.progressAnchorDate == nil { snapshot.progressAnchorDate = Date() }
        if snapshot == .idle || snapshot.title.isEmpty || snapshot.artist.isEmpty {
            // Sources can briefly disappear during fallback selection. Keep the last
            // document for two seconds instead of clearing/reloading it immediately.
            if media != .idle, idleTask == nil {
                idleTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else { return }
                    self.idleTask = nil; self.upgradeTask?.cancel(); self.upgradeTask = nil; self.localCacheTask?.cancel(); self.localCacheTask = nil; self.request?.cancel(); self.generation = UUID()
                    self.media = .idle; self.document = nil; self.candidates = []; self.sourceStatus = [:]; self.key = ""; self.cachedTrackMedia = nil
                    self.clock.update(.idle, trackChanged: true); self.updateClockRecovery(); self.updateSpectrum()
                    self.status = "等待正在播放的歌曲"
                }
            }
            return
        }
        idleTask?.cancel(); idleTask = nil
        let sameSong = cachedTrackMedia.map {
            LyricsProvider.normalized($0.title) == LyricsProvider.normalized(snapshot.title)
                && LyricsProvider.normalized($0.artist) == LyricsProvider.normalized(snapshot.artist)
                && $0.bundleIdentifier?.lowercased() == snapshot.bundleIdentifier?.lowercased()
        } ?? false
        // Album names and duration can change when the media adapter enriches
        // the same playback session. They must not restart the lyric clock.
        let sameTrack = sameSong && (cachedTrackMedia.map {
            $0.duration <= 0 || snapshot.duration <= 0 || abs($0.duration - snapshot.duration) < 10
        } ?? false)
        if sameTrack, let previous = cachedTrackMedia {
            if snapshot.album.isEmpty { snapshot.album = previous.album }
            if snapshot.duration <= 0 { snapshot.duration = previous.duration }
            if previous.positionSource == .playerScript,
               snapshot.positionSource == .mediaRemote,
               let measuredAt = previous.progressAnchorDate,
               Date().timeIntervalSince(measuredAt) < 8 {
                let now = Date()
                let precisePosition = previous.estimatedElapsed(at: now)
                // A large disagreement can be an external seek. Let that new
                // reading through until the next player-owned probe confirms it.
                if abs(snapshot.estimatedElapsed(at: now) - precisePosition) < 2 {
                    snapshot.elapsed = precisePosition
                    snapshot.progressAnchorDate = now
                    snapshot.positionSource = .playerScript
                }
            }
        }
        media = snapshot
        clock.update(snapshot, trackChanged: !sameSong, identity: "\(snapshot.bundleIdentifier?.lowercased() ?? "")|\(LyricsProvider.normalized(snapshot.title))|\(LyricsProvider.normalized(snapshot.artist))")
        updateClockRecovery()
        if document != nil { updateStatus() }
        updateSpectrum()
        guard running, !suspended, appearance.enabled else { return }
        cachedTrackMedia = snapshot
        guard force || !sameTrack || key.isEmpty else { return }
        upgradeTask?.cancel(); upgradeTask = nil
        localCacheTask?.cancel(); localCacheTask = nil
        if !sameTrack { upgradeAttempts = 0 }
        let newKey = sameTrack && !key.isEmpty ? key : "\(LyricsProvider.normalized(snapshot.title))|\(LyricsProvider.normalized(snapshot.artist))|\(Int((snapshot.duration / 5).rounded()))|\(LyricsProvider.normalized(snapshot.album))"
        let previous = [sameTrack ? document : nil, cache[newKey], legacyCache(for: snapshot)]
            .compactMap { $0 }
            .map { adaptedToCurrentPlayer($0, media: snapshot) }
            .filter { candidate in
                (candidate.source == "本地导入" || LyricsProvider.hasActualLyrics(candidate, duration: snapshot.duration))
                    && (candidate.source == "本地导入" || LyricsSourceID.from(candidate).map {
                    sourcePreferences.orderedEnabledSources(for: snapshot).contains($0)
                } == true)
            }
            .reduce(nil as LyricsDocument?) { current, candidate in
                sourcePreferences.prefers(candidate, to: current) ? candidate : current
            }
        cachedTrackMedia = snapshot
        key = newKey
        if !sameTrack { candidates = []; sourceStatus = [:]; rematchFeedback = nil }
        generation = UUID(); let ticket = generation
        request?.cancel(); document = previous
        guard snapshot != .idle, !snapshot.title.isEmpty, !snapshot.artist.isEmpty else { status = "等待正在播放的歌曲"; return }
        if !force, let cached = cache[key],
           cached.source == "本地导入" || LyricsProvider.hasActualLyrics(cached, duration: snapshot.duration),
           cached.source == "本地导入" || LyricsSourceID.from(cached).map(sourcePreferences.orderedEnabledSources(for: snapshot).contains) == true {
            document = [adaptedToCurrentPlayer(cached, media: snapshot), document].compactMap { $0 }
                .reduce(nil as LyricsDocument?) { current, candidate in
                    sourcePreferences.prefers(candidate, to: current) ? candidate : current
                }
            updateStatus()
            if document?.source == "本地导入" { return }
        }
        status = "正在查找歌词…"
        let preferences = sourcePreferences
        request = Task { [weak self] in
            let result = await LyricsProvider.lookup(snapshot, preferences: preferences) { [weak self] candidate in
                guard !Task.isCancelled, let self, self.running, !self.suspended, self.appearance.enabled, self.generation == ticket else { return }
                self.recordCandidate(candidate)
                if self.shouldSelect(candidate) {
                    self.document = candidate; self.updateStatus()
                }
            }
            let found = result.document
            guard !Task.isCancelled, let self, self.running, !self.suspended, self.appearance.enabled, self.generation == ticket else { return }
            self.sourceStatus = result.sourceStatus
            let localSource: LyricsSourceID? = snapshot.bundleIdentifier?.lowercased() == "com.apple.music"
                ? .appleMusicLocal
                : snapshot.bundleIdentifier?.lowercased().contains("kugou") == true ? .kugouLocal : nil
            if let localSource, preferences.enabled.contains(localSource),
               result.sourceStatus[localSource] == "未找到匹配歌词" {
                self.retryLocalCache(localSource, for: snapshot, ticket: ticket)
            }
            if let found, self.shouldSelect(found) { self.document = found }
            if let selected = self.document { self.cache[self.key] = selected; self.saveCache() }
            self.updateStatus()
            if found == nil && previous == nil && result.unavailable { self.status = "歌词服务暂时不可用，可重试或导入歌词" }
            if self.document?.hasWordTiming != true, self.document?.source != "本地导入", self.upgradeAttempts < 2 {
                self.upgradeAttempts += 1
                let delay = self.upgradeAttempts == 1 ? 6 : 18
                self.upgradeTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self, self.running, !self.suspended, self.appearance.enabled, self.generation == ticket else { return }
                    self.upgradeTask = nil; self.receive(self.media, force: true)
                }
            }
        }
    }
    private func retryLocalCache(_ source: LyricsSourceID, for snapshot: MediaSnapshot, ticket: UUID) {
        localCacheTask?.cancel()
        localCacheTask = Task { [weak self] in
            for delay in [1, 2, 3] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let found = await Task.detached(priority: .utility) {
                    source == .appleMusicLocal
                        ? AppleMusicLocalLyrics.lookup(snapshot)
                        : KugouLocalLyrics.lookup(snapshot)
                }.value
                guard !Task.isCancelled, let self, self.running, !self.suspended,
                      self.generation == ticket else { return }
                if let found {
                    self.sourceStatus[source] = found.hasWordTiming ? "已找到逐字歌词" : "已找到逐行歌词"
                    self.recordCandidate(found)
                    if self.shouldSelect(found) {
                        self.document = found; self.cache[self.key] = found; self.saveCache(); self.updateStatus()
                    }
                    return
                }
            }
        }
    }
    private func updateStatus() {
        guard let document else { status = "未找到匹配歌词，可导入 LRC / YRC"; return }
        status = !canSynchronize ? "播放器未提供进度，暂时无法同步"
            : media.isPlaying && !isPlaybackProgressing ? "等待播放器进度…"
            : document.hasWordTiming ? "已连接 · 逐字时间轴" : "已连接 · 逐行时间轴（无逐字数据）"
    }
    var selectedCandidateID: String? { pinnedSelection(for: key) }
    func setSource(_ source: LyricsSourceID, enabled: Bool) {
        if enabled { sourcePreferences.enabled.insert(source) }
        else { sourcePreferences.enabled.remove(source) }
    }
    func moveSource(_ source: LyricsSourceID, by offset: Int) {
        guard let index = sourcePreferences.order.firstIndex(of: source),
              sourcePreferences.order.indices.contains(index + offset) else { return }
        sourcePreferences.order.swapAt(index, index + offset)
    }
    func selectCandidate(_ identifier: String?) {
        guard !key.isEmpty else { return }
        // An empty value explicitly disables an older compatible pin.
        pinnedSelections[key] = identifier ?? ""
        if let data = try? JSONEncoder().encode(pinnedSelections) {
            UserDefaults.standard.set(data, forKey: "NotchTriage.Lyrics.pinnedSelections")
        }
        if let identifier {
            guard let selected = candidates.first(where: { $0.selectionID == identifier }) else { return }
            document = selected
        } else if let selected = candidates.reduce(nil as LyricsDocument?, { sourcePreferences.prefers($1, to: $0) ? $1 : $0 }) {
            document = selected
        }
        if let document { cache[key] = document; saveCache() }
        updateStatus()
    }
    private func recordCandidate(_ candidate: LyricsDocument) {
        if let index = candidates.firstIndex(where: { $0.selectionID == candidate.selectionID }) {
            if LyricsProvider.isBetter(candidate, than: candidates[index]) { candidates[index] = candidate }
        } else {
            candidates.append(candidate)
        }
        candidates.sort { sourcePreferences.prefers($0, to: $1) }
        if candidates.count > 20 { candidates.removeLast(candidates.count - 20) }
    }
    private func shouldSelect(_ candidate: LyricsDocument) -> Bool {
        if let pinned = pinnedSelection(for: key) {
            if candidate.selectionID == pinned { return true }
            if document?.selectionID == pinned { return false }
        }
        return sourcePreferences.prefers(candidate, to: document)
    }
    private func pinnedSelection(for trackKey: String) -> String? {
        if let exact = pinnedSelections[trackKey] { return exact.isEmpty ? nil : exact }
        let current = trackKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard current.count == 4, let durationBucket = Int(current[2]) else { return nil }
        return pinnedSelections.compactMap { stored, selection -> (Int, String, String)? in
            let parts = stored.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let oldBucket = Int(parts[2]),
                  parts[0] == current[0], parts[1] == current[1],
                  abs(oldBucket - durationBucket) <= 1,
                  parts[3] == current[3] || parts[3].isEmpty || current[3].isEmpty else { return nil }
            let score = (parts[3] == current[3] ? 4 : 0) + (oldBucket == durationBucket ? 2 : 0)
            return (score, stored, selection)
        }.sorted { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 > right.0
        }.first?.2
    }
    private func adaptedToCurrentPlayer(_ candidate: LyricsDocument, media: MediaSnapshot) -> LyricsDocument {
        var result = candidate
        let player = media.bundleIdentifier?.lowercased() ?? ""
        let belongsToCurrentPlayer: Bool
        switch LyricsSourceID.from(candidate) {
        case .appleMusicLocal: belongsToCurrentPlayer = player == "com.apple.music"
        case .appleMusicOnline: belongsToCurrentPlayer = player == "com.apple.music"
        case .kugouLocal: belongsToCurrentPlayer = player.contains("kugou")
        case .kugouOnline: belongsToCurrentPlayer = false
        case .qq: belongsToCurrentPlayer = player.contains("qqmusic")
        case .netease: belongsToCurrentPlayer = player.contains("netease")
        case .migu, .kuwo, .soda, .amll, .musixmatch, .deezer, .lyricFind, .lrclib, .none: belongsToCurrentPlayer = false
        }
        if !belongsToCurrentPlayer { result.isNativeMatch = false }
        return result
    }
    private func legacyCache(for snapshot: MediaSnapshot) -> LyricsDocument? {
        let title = LyricsProvider.normalized(snapshot.title)
        let artist = LyricsProvider.normalized(snapshot.artist)
        let album = LyricsProvider.normalized(snapshot.album)
        return cache.compactMap { oldKey, document -> LyricsDocument? in
            let parts = oldKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4,
                  LyricsProvider.normalized(parts[0]) == title,
                  LyricsProvider.normalized(parts[1]) == artist,
                  let length = Double(parts[2]),
                  (snapshot.duration <= 0 || length <= 0 || abs(length - snapshot.duration) < 5),
                  (album.isEmpty || parts[3].isEmpty || LyricsProvider.normalized(parts[3]) == album) else { return nil }
            return document
        }.reduce(nil) { LyricsProvider.best([$0, $1].compactMap { $0 }) }
    }
    private func saveCache() {
        if cache.count > 60 {
            for oldKey in Array(cache.keys) where oldKey != key {
                cache.removeValue(forKey: oldKey)
                if cache.count <= 60 { break }
            }
        }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }
    private func updateSpectrum() {
        if !appearance.capturesSpectrum { spectrum.disable(); return }
        spectrum.setActive(spectrumVisible && running && !suspended && appearance.enabled && appearance.hasOrnaments && appearance.capturesSpectrum && isPlaybackProgressing)
    }
    private func updateClockRecovery() {
        guard running, !suspended, appearance.enabled, media.isPlaying,
              clock.remainingSeekHold() != nil else {
            clockRecoveryTask?.cancel()
            clockRecoveryTask = nil
            return
        }
        guard clockRecoveryTask == nil else { return }
        clockRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let remaining = self.clock.remainingSeekHold() else {
                    self?.clockRecoveryTask = nil
                    return
                }
                let delay = max(50, Int64(ceil(remaining * 1_000)))
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                if self.clock.resumeIfSeekHoldExpired(from: self.media) {
                    self.clockRecoveryTask = nil
                    self.objectWillChange.send()
                    if self.document != nil { self.updateStatus() }
                    self.updateSpectrum()
                    return
                }
            }
        }
    }
    func setSpectrumVisible(_ value: Bool) {
        guard spectrumVisible != value else { return }
        spectrumVisible = value; updateSpectrum()
    }
    func retrySpectrum() { spectrum.stop(); spectrum.resetFailure(); updateSpectrum() }
    func retry() {
        upgradeAttempts = 0
        Task { [weak self] in
            await LyricsSourceHealth.shared.reset()
            guard let self else { return }
            self.receive(self.media, force: true)
        }
    }
    func rematch() {
        guard running, !suspended, appearance.enabled, media != .idle, !key.isEmpty else { return }
        request?.cancel(); upgradeTask?.cancel(); upgradeTask = nil
        localCacheTask?.cancel(); localCacheTask = nil
        generation = UUID()
        let ticket = generation, snapshot = media, preferences = sourcePreferences
        let previous = document
        status = "正在重新匹配歌词…"
        rematchFeedback = nil
        candidates = []
        request = Task { [weak self] in
            await LyricsSourceHealth.shared.reset()
            let result = await LyricsProvider.lookup(snapshot, preferences: preferences) { [weak self] candidate in
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                self.recordCandidate(candidate)
            }
            guard !Task.isCancelled, let self, self.generation == ticket else { return }
            self.sourceStatus = result.sourceStatus
            if let winner = result.document {
                if previous?.hasWordTiming == true, !winner.hasWordTiming {
                    self.rematchFeedback = "找到候选，但保留当前逐字歌词，避免退回逐行"
                } else {
                    self.document = winner
                    self.cache[self.key] = winner; self.saveCache()
                    self.pinnedSelections[self.key] = ""
                    if let data = try? JSONEncoder().encode(self.pinnedSelections) {
                        UserDefaults.standard.set(data, forKey: "NotchTriage.Lyrics.pinnedSelections")
                    }
                    self.rematchFeedback = winner.selectionID == previous?.selectionID
                        ? "重新匹配完成，当前版本仍是最佳候选"
                        : "已切换到 \(winner.source) 的更合适版本"
                }
            } else {
                self.rematchFeedback = result.unavailable
                    ? "歌词来源暂时不可用，已保留当前版本"
                    : "未找到可用的新候选，已保留当前版本"
            }
            self.updateStatus()
        }
    }
    func importLyrics() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, UTType(filenameExtension: "yrc") ?? .plainText, UTType(filenameExtension: "qrc") ?? .plainText, UTType(filenameExtension: "krc") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000 else {
            status = "导入失败：文件无法读取或过大"; return
        }
        let parsed: LyricsDocument?
        if url.pathExtension.lowercased() == "krc", let text = LyricsKRC.decode(data) {
            parsed = LyricsKRC.parse(text, duration: media.duration)
        } else if let text = String(data: data, encoding: .utf8) {
            parsed = LyricsParser.parse(text, source: "本地导入", duration: media.duration,
                                        format: url.pathExtension.lowercased() == "qrc" ? .qrc : .automatic)
        } else { parsed = nil }
        guard var parsed else { status = "导入失败：需要带时间轴的 LRC / YRC / QRC / KRC"; return }
        parsed.source = "本地导入"
        if !appearance.enabled { appearance.enabled = true }
        request?.cancel(); upgradeTask?.cancel(); upgradeTask = nil; generation = UUID(); document = parsed
        if !key.isEmpty { cache[key] = parsed; saveCache() }
        updateStatus()
    }
    func togglePreview() {
        previewTask?.cancel()
        previewing.toggle()
        guard previewing else { return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { self?.previewing = false }
        }
    }
}
