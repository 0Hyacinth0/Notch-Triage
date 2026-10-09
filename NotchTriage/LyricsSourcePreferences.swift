import Foundation

enum LyricsSourceID: String, Codable, CaseIterable, Identifiable {
    case appleMusicLocal, appleMusicOnline, kugouLocal, kugouOnline, netease, qq, migu, kuwo, soda, amll, musixmatch, deezer, lyricFind, lrclib

    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleMusicLocal: return "Apple Music 本地歌词"
        case .appleMusicOnline: return "Apple Music 在线歌词"
        case .kugouLocal: return "酷狗音乐本地歌词"
        case .kugouOnline: return "酷狗音乐在线歌词"
        case .netease: return "网易云音乐"
        case .qq: return "QQ 音乐"
        case .migu: return "咪咕音乐"
        case .kuwo: return "酷我音乐"
        case .soda: return "汽水音乐"
        case .amll: return "AMLL 逐字词库"
        case .musixmatch: return "Musixmatch"
        case .deezer: return "Deezer"
        case .lyricFind: return "LyricFind"
        case .lrclib: return "LRCLIB"
        }
    }
    static func from(_ document: LyricsDocument) -> Self? {
        switch document.source {
        case "Apple Music": return .appleMusicLocal
        case "Apple Music 在线歌词": return .appleMusicOnline
        case "酷狗音乐": return .kugouLocal
        case "酷狗音乐在线歌词": return .kugouOnline
        case "网易云音乐": return .netease
        case "QQ 音乐": return .qq
        case "咪咕音乐": return .migu
        case "酷我音乐": return .kuwo
        case "汽水音乐": return .soda
        case "AMLL 逐字词库": return .amll
        case "Musixmatch": return .musixmatch
        case "Deezer": return .deezer
        case "LyricFind": return .lyricFind
        case "LRCLIB": return .lrclib
        default: return nil
        }
    }
}

enum LyricsSourceSelectionMode: String, Codable, CaseIterable {
    case bestMatch, priority
    var title: String { self == .bestMatch ? "自动选最佳版本" : "按来源顺序" }
}

struct LyricsSourcePreferences: Codable, Equatable {
    var enabled: Set<LyricsSourceID> = Set(LyricsSourceID.allCases)
    var order: [LyricsSourceID] = LyricsSourceID.allCases
    var mode: LyricsSourceSelectionMode = .bestMatch

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, order, mode }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedOrder = try values.decodeIfPresent([LyricsSourceID].self, forKey: .order) ?? []
        let added = LyricsSourceID.allCases.filter { !savedOrder.contains($0) }
        order = savedOrder + added
        enabled = (try values.decodeIfPresent(Set<LyricsSourceID>.self, forKey: .enabled)
                   ?? Set(LyricsSourceID.allCases)).union(added)
        mode = try values.decodeIfPresent(LyricsSourceSelectionMode.self, forKey: .mode) ?? .bestMatch
    }

    func orderedEnabledSources(for media: MediaSnapshot) -> [LyricsSourceID] {
        let normalized = order + LyricsSourceID.allCases.filter { !order.contains($0) }
        return normalized.filter { source in
            guard enabled.contains(source) else { return false }
            if source == .appleMusicLocal { return media.bundleIdentifier?.lowercased() == "com.apple.music" }
            if source == .kugouLocal { return media.bundleIdentifier?.lowercased().contains("kugou") == true }
            return true
        }
    }

    func prefers(_ candidate: LyricsDocument, to existing: LyricsDocument?) -> Bool {
        guard let existing else { return true }
        if candidate.source == "本地导入" { return true }
        if existing.source == "本地导入" { return false }
        if mode == .priority,
           let candidateSource = LyricsSourceID.from(candidate),
           let existingSource = LyricsSourceID.from(existing) {
            let ranked = order + LyricsSourceID.allCases.filter { !order.contains($0) }
            let candidateIndex = ranked.firstIndex(of: candidateSource) ?? Int.max
            let existingIndex = ranked.firstIndex(of: existingSource) ?? Int.max
            if candidateIndex != existingIndex { return candidateIndex < existingIndex }
        }
        return LyricsProvider.isBetter(candidate, than: existing)
    }
}
