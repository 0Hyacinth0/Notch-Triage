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
        if oldValue.enabled != appearance.enabled {
            if appearance.enabled { receive(media, force: true) } else { request?.cancel(); document = nil; status = "歌词显示已关闭" }
        }
    } }
    @Published private(set) var document: LyricsDocument?
    @Published private(set) var media = MediaSnapshot.idle
    @Published private(set) var status = "歌词显示已关闭"
    @Published private(set) var previewing = false
    private var request: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var generation = UUID()
    private var key = ""
    private var running = false
    private var suspended = false
    private var cache: [String: LyricsDocument] = [:]
    private let cacheURL: URL

    init() {
        let data = UserDefaults.standard.data(forKey: "NotchTriage.Lyrics.appearance")
        appearance = data.flatMap { try? JSONDecoder().decode(LyricsAppearance.self, from: $0) } ?? LyricsAppearance()
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchTriage/lyrics.json")
        if let data = try? Data(contentsOf: cacheURL), data.count < 8_000_000 { cache = (try? JSONDecoder().decode([String: LyricsDocument].self, from: data)) ?? [:] }
    }
    func start() { running = true }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value { request?.cancel() } else if appearance.enabled { receive(media, force: document == nil) }
    }
    func stop() { running = false; request?.cancel(); previewTask?.cancel(); previewing = false }
    var canSynchronize: Bool { media.duration > 0 }
    func elapsed(at date: Date) -> Double { media.estimatedElapsed(at: date) + appearance.offset }
    func receive(_ snapshot: MediaSnapshot, force: Bool = false) {
        var snapshot = snapshot
        if snapshot.duration > 0, snapshot.progressAnchorDate == nil { snapshot.progressAnchorDate = Date() }
        media = snapshot
        guard running, !suspended, appearance.enabled else { return }
        let newKey = "\(snapshot.title)|\(snapshot.artist)|\(Int(snapshot.duration.rounded()))"
        guard force || key != newKey else { return }
        let previous = newKey == key ? document ?? cache[newKey] : nil
        key = newKey
        generation = UUID(); let ticket = generation
        request?.cancel(); document = previous
        guard snapshot != .idle, !snapshot.title.isEmpty, !snapshot.artist.isEmpty else { status = "等待正在播放的歌曲"; return }
        if !force, let cached = cache[key] { document = cached; updateStatus(); return }
        status = "正在查找歌词…"
        request = Task { [weak self] in
            let result = await LyricsProvider.lookup(snapshot)
            let found = result.document
            guard !Task.isCancelled, let self, self.running, !self.suspended, self.appearance.enabled, self.generation == ticket else { return }
            self.document = found ?? previous
            if let found { self.cache[self.key] = found; self.saveCache() }
            self.updateStatus()
            if found == nil && previous == nil && result.unavailable { self.status = "歌词服务暂时不可用，可重试或导入歌词" }
        }
    }
    private func updateStatus() {
        guard let document else { status = "未找到匹配歌词，可导入 LRC / YRC"; return }
        status = !canSynchronize ? "播放器未提供进度，暂时无法同步" : document.hasWordTiming ? "已连接 · 逐字时间轴" : "已连接 · 逐行时间轴"
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
    func retry() { receive(media, force: true) }
    func importLyrics() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, UTType(filenameExtension: "yrc") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000, let text = String(data: data, encoding: .utf8), let parsed = LyricsParser.parse(text, source: "本地导入", duration: media.duration) else { status = "导入失败：需要 UTF-8 编码的带时间轴歌词"; return }
        if !appearance.enabled { appearance.enabled = true }
        request?.cancel(); generation = UUID(); document = parsed
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
