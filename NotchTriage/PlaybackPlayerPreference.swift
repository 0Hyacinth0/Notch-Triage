import Foundation

enum PlaybackPlayerPreference: String, CaseIterable, Identifiable {
    case automatic, appleMusic, spotify, qqMusic, netease, kugou, safari, chrome, edge, brave, arc

    static let key = "lyrics.playbackPlayerPreference"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "自动选择"
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .qqMusic: "QQ 音乐"
        case .netease: "网易云音乐"
        case .kugou: "酷狗音乐"
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .arc: "Arc"
        }
    }
    var bundleIdentifier: String? {
        switch self {
        case .automatic: nil
        case .appleMusic: "com.apple.Music"
        case .spotify: "com.spotify.client"
        case .qqMusic: "com.tencent.QQMusicMac"
        case .netease: "com.netease.163music"
        case .kugou: "com.kugou.music"
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .arc: "company.thebrowser.Browser"
        }
    }
    func accepts(_ identifier: String?) -> Bool {
        guard self != .automatic else { return true }
        guard let identifier = identifier?.lowercased() else { return false }
        switch self {
        case .netease: return identifier.contains("netease") || identifier.contains("163music")
        case .kugou: return identifier.contains("kugou")
        default: return identifier == bundleIdentifier?.lowercased()
        }
    }
    static var selectedPlayers: Set<Self> {
        if let values = UserDefaults.standard.stringArray(forKey: key) {
            let parsed = Set(values.compactMap(Self.init(rawValue:)))
            if !parsed.isEmpty { return parsed }
        }
        if let old = UserDefaults.standard.string(forKey: key), let parsed = Self(rawValue: old) {
            return [parsed]
        }
        return [.automatic]
    }
    static var soleExplicit: Self? {
        let explicit = selectedPlayers.subtracting([.automatic])
        return selectedPlayers.contains(.automatic) ? nil : explicit.count == 1 ? explicit.first : nil
    }
    static func acceptsSelected(_ identifier: String?) -> Bool {
        let selected = selectedPlayers
        return selected.contains(.automatic) || selected.contains { $0.accepts(identifier) }
    }
    static func title(for bundleIdentifier: String) -> String {
        allCases.first(where: { $0 != .automatic && $0.accepts(bundleIdentifier) })?.title ?? "浏览器"
    }
}
