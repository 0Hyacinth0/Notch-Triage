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
    var variant: LyricsChineseVariant { chineseVariant ?? .simplified }
    var usesEstimatedTiming: Bool { estimatedAnimation ?? false }
    var spread: Double { max(0, min(1, glowSpread ?? 0.45)) }
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
    @Published var appearance: LyricsAppearance { didSet {
        if let data = try? JSONEncoder().encode(appearance) { UserDefaults.standard.set(data, forKey: "NotchTriage.Lyrics.appearance") }
        updateSpectrum()
        if oldValue.enabled != appearance.enabled {
            if appearance.enabled { receive(media, force: true) } else { request?.cancel(); upgradeTask?.cancel(); upgradeTask = nil; document = nil; status = "歌词显示已关闭" }
        }
    } }
    @Published private(set) var document: LyricsDocument?
    @Published private(set) var media = MediaSnapshot.idle
    @Published private(set) var status = "歌词显示已关闭"
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
    private var idleTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    private var upgradeAttempts = 0
    private var cachedTrackMedia: MediaSnapshot?
    private var cache: [String: LyricsDocument] = [:]
    private let cacheURL: URL

    init() {
        let data = UserDefaults.standard.data(forKey: "NotchTriage.Lyrics.appearance")
        appearance = data.flatMap { try? JSONDecoder().decode(LyricsAppearance.self, from: $0) } ?? LyricsAppearance()
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchTriage/lyrics.json")
        if let data = try? Data(contentsOf: cacheURL), data.count < 8_000_000 { cache = (try? JSONDecoder().decode([String: LyricsDocument].self, from: data)) ?? [:] }
    }
    func start() { running = true; updateSpectrum() }
    func setSuspended(_ value: Bool) {
        suspended = value
        updateSpectrum()
        if value { request?.cancel(); idleTask?.cancel(); idleTask = nil; upgradeTask?.cancel(); upgradeTask = nil } else if appearance.enabled { receive(media, force: document?.hasWordTiming != true) }
    }
    func stop() { running = false; upgradeTask?.cancel(); upgradeTask = nil; idleTask?.cancel(); idleTask = nil; spectrum.stop(); request?.cancel(); previewTask?.cancel(); previewing = false }
    var canSynchronize: Bool { media.duration > 0 }
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
                    self.idleTask = nil; self.upgradeTask?.cancel(); self.upgradeTask = nil; self.request?.cancel(); self.generation = UUID()
                    self.media = .idle; self.document = nil; self.key = ""; self.cachedTrackMedia = nil
                    self.clock.update(.idle, trackChanged: true); self.updateSpectrum()
                    self.status = "等待正在播放的歌曲"
                }
            }
            return
        }
        idleTask?.cancel(); idleTask = nil
        let sameSong = cachedTrackMedia.map {
            LyricsProvider.normalized($0.title) == LyricsProvider.normalized(snapshot.title)
                && LyricsProvider.normalized($0.artist) == LyricsProvider.normalized(snapshot.artist)
        } ?? false
        // Album names and duration can change when the media adapter enriches
        // the same playback session. They must not restart the lyric clock.
        let sameTrack = sameSong && (cachedTrackMedia.map {
            $0.duration <= 0 || snapshot.duration <= 0 || abs($0.duration - snapshot.duration) < 10
        } ?? false)
        if sameTrack, let previous = cachedTrackMedia {
            if snapshot.album.isEmpty { snapshot.album = previous.album }
            if snapshot.duration <= 0 { snapshot.duration = previous.duration }
        }
        media = snapshot
        clock.update(snapshot, trackChanged: !sameSong, identity: "\(LyricsProvider.normalized(snapshot.title))|\(LyricsProvider.normalized(snapshot.artist))")
        updateSpectrum()
        guard running, !suspended, appearance.enabled else { return }
        cachedTrackMedia = snapshot
        guard force || !sameTrack || key.isEmpty else { return }
        upgradeTask?.cancel(); upgradeTask = nil
        if !sameTrack { upgradeAttempts = 0 }
        let newKey = sameTrack && !key.isEmpty ? key : "\(LyricsProvider.normalized(snapshot.title))|\(LyricsProvider.normalized(snapshot.artist))|\(Int((snapshot.duration / 5).rounded()))|\(LyricsProvider.normalized(snapshot.album))"
        let previous = LyricsProvider.best([sameTrack ? document : nil, cache[newKey], legacyCache(for: snapshot)].compactMap { $0 })
        cachedTrackMedia = snapshot
        key = newKey
        generation = UUID(); let ticket = generation
        request?.cancel(); document = previous
        let replaceTimed = (force || (previous?.source != "本地导入" && (previous?.parserRevision ?? 0) < 2)) && previous?.hasWordTiming == true
        guard snapshot != .idle, !snapshot.title.isEmpty, !snapshot.artist.isEmpty else { status = "等待正在播放的歌曲"; return }
        if !force, let cached = cache[key] {
            document = LyricsProvider.best([cached, document].compactMap { $0 })
            updateStatus()
            if let document, document.hasWordTiming && (document.parserRevision ?? 0) >= 2 { return }
            if document?.source == "本地导入" { return }
        }
        status = "正在查找歌词…"
        request = Task { [weak self] in
            let result = await LyricsProvider.lookup(snapshot) { [weak self] candidate in
                guard !Task.isCancelled, let self, self.running, !self.suspended, self.appearance.enabled, self.generation == ticket else { return }
                if (self.document?.hasWordTiming != true || (self.document?.source != "本地导入" && (self.document?.parserRevision ?? 0) < 2 && (candidate.parserRevision ?? 0) >= 2)), LyricsProvider.isBetter(candidate, than: self.document) {
                    self.document = candidate; self.updateStatus()
                }
            }
            let found = result.document
            guard !Task.isCancelled, let self, self.running, !self.suspended, self.appearance.enabled, self.generation == ticket else { return }
            if replaceTimed || self.document?.hasWordTiming != true {
                self.document = LyricsProvider.best([found, self.document, previous].compactMap { $0 })
            }
            if let selected = self.document { self.cache[self.key] = selected; self.saveCache() }
            self.updateStatus()
            if found == nil && previous == nil && result.unavailable { self.status = "歌词服务暂时不可用，可重试或导入歌词" }
            if (self.document?.hasWordTiming != true || (self.document?.source != "本地导入" && (self.document?.parserRevision ?? 0) < 2)), self.upgradeAttempts < 2 {
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
    private func updateStatus() {
        guard let document else { status = "未找到匹配歌词，可导入 LRC / YRC"; return }
        status = !canSynchronize ? "播放器未提供进度，暂时无法同步" : document.hasWordTiming ? "已连接 · 逐字时间轴" : "已连接 · 逐行时间轴（无逐字数据）"
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
        spectrum.setActive(spectrumVisible && running && !suspended && appearance.enabled && appearance.hasOrnaments && appearance.capturesSpectrum && media.isPlaying)
    }
    func setSpectrumVisible(_ value: Bool) {
        guard spectrumVisible != value else { return }
        spectrumVisible = value; updateSpectrum()
    }
    func retrySpectrum() { spectrum.stop(); spectrum.resetFailure(); updateSpectrum() }
    func retry() { upgradeAttempts = 0; receive(media, force: true) }
    func importLyrics() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, UTType(filenameExtension: "yrc") ?? .plainText, UTType(filenameExtension: "qrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000, let text = String(data: data, encoding: .utf8), let parsed = LyricsParser.parse(text, source: "本地导入", duration: media.duration, format: url.pathExtension.lowercased() == "qrc" ? .qrc : .automatic) else { status = "导入失败：需要 UTF-8 编码的带时间轴歌词"; return }
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
