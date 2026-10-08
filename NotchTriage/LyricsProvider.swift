import Foundation

struct LyricsProvider {
    private static func json(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("NotchTriage/1.0 (desktop lyrics)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 2_000_000 else { throw URLError(.badServerResponse) }
        let result = try JSONSerialization.jsonObject(with: data)
        if let dictionary = result as? [String: Any], let code = dictionary["code"] as? Int, code >= 400 { throw URLError(.badServerResponse) }
        return result
    }
    private static func url(_ base: String, _ params: [String: String]) -> URL {
        var parts = URLComponents(string: base)!
        parts.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).filter { $0.isLetter || $0.isNumber }
    }
    static func matches(title: String, artist: String, duration: Double, media: MediaSnapshot) -> Bool {
        guard normalized(title) == normalized(media.title) else { return false }
        let expected = normalized(media.artist), actual = normalized(artist)
        guard !expected.isEmpty, !actual.isEmpty, actual.contains(expected) || expected.contains(actual) else { return false }
        return media.duration <= 0 || duration <= 0 || abs(duration - media.duration) < 5
    }
    static func lrclib(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        let response = try await json(url("https://lrclib.net/api/search", ["track_name": media.title, "artist_name": media.artist]))
        guard let records = response as? [[String: Any]] else { return nil }
        for record in records where matches(title: record["trackName"] as? String ?? "", artist: record["artistName"] as? String ?? "", duration: record["duration"] as? Double ?? 0, media: media) {
            if let text = record["syncedLyrics"] as? String, let result = LyricsParser.parse(text, source: "LRCLIB", duration: media.duration) { return result }
        }
        return nil
    }
    static func netease(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        let response = try await json(url("https://music.163.com/api/search/get", ["s": "\(media.title) \(media.artist)", "type": "1", "limit": "8"]))
        guard let root = response as? [String: Any], let result = root["result"] as? [String: Any], let songs = result["songs"] as? [[String: Any]] else { return nil }
        for song in songs.prefix(3) {
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            guard matches(title: song["name"] as? String ?? "", artist: artists, duration: (song["duration"] as? Double ?? 0) / 1000, media: media), let id = song["id"] as? Int else { continue }
            let body = try await json(url("https://music.163.com/api/song/lyric/v1", ["id": String(id), "lv": "-1", "yv": "-1"]))
            guard let root = body as? [String: Any] else { continue }
            for field in ["yrc", "lrc"] {
                if let record = root[field] as? [String: Any], let raw = record["lyric"] as? String, let lyrics = LyricsParser.parse(raw, source: "网易云音乐", duration: media.duration) { return lyrics }
            }
        }
        return nil
    }
    private static func attempt(_ operation: () async throws -> LyricsDocument?) async -> (LyricsDocument?, Bool) {
        do { return (try await operation(), false) } catch { return (nil, true) }
    }
    static func lookup(_ media: MediaSnapshot) async -> (document: LyricsDocument?, unavailable: Bool) {
        async let cloud = attempt { try await netease(media) }
        async let library = attempt { try await lrclib(media) }
        let (a, b) = await (cloud, library)
        return (a.0?.hasWordTiming == true ? a.0 : b.0 ?? a.0, a.1 && b.1)
    }
}
