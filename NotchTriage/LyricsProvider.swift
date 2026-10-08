import Foundation

struct LyricsProvider {
    private static func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 2_000_000 else { throw URLError(.badServerResponse) }
        return data
    }
    private static func json(_ request: URLRequest) async throws -> Any {
        try JSONSerialization.jsonObject(with: await data(request))
    }
    private static func request(_ base: String, _ params: [String: String] = [:]) -> URLRequest {
        var parts = URLComponents(string: base)!
        if !params.isEmpty { parts.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: parts.url!, timeoutInterval: 10)
        request.setValue("NotchTriage/1.0 (desktop lyrics)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        return request
    }
    static func normalized(_ value: String) -> String {
        LyricsChineseVariant.simplified.convert(value).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).filter { $0.isLetter || $0.isNumber }
    }
    static func matches(title: String, artist: String, duration: Double, media: MediaSnapshot) -> Bool {
        guard normalized(title) == normalized(media.title) else { return false }
        let expected = normalized(media.artist), actual = normalized(artist)
        guard !expected.isEmpty, !actual.isEmpty, actual.contains(expected) || expected.contains(actual) else { return false }
        return media.duration <= 0 || duration <= 0 || abs(duration - media.duration) < 5
    }
    private static func score(album: String, duration: Double, media: MediaSnapshot) -> Double {
        let albumMatch = !media.album.isEmpty && normalized(album) == normalized(media.album)
        let durationMatch = duration > 0 && media.duration > 0 ? max(0, 1 - abs(duration - media.duration) / 5) : 0
        return (albumMatch ? 2 : 0) + durationMatch
    }
    static func isBetter(_ candidate: LyricsDocument, than existing: LyricsDocument?) -> Bool {
        guard let existing else { return true }
        if candidate.hasWordTiming != existing.hasWordTiming { return candidate.hasWordTiming }
        return (candidate.matchScore ?? 0) > (existing.matchScore ?? 0)
    }
    static func best(_ documents: [LyricsDocument]) -> LyricsDocument? {
        documents.reduce(nil) { current, candidate in isBetter(candidate, than: current) ? candidate : current }
    }
    static func lrclib(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        let response = try await json(request("https://lrclib.net/api/search", ["track_name": media.title, "artist_name": media.artist]))
        guard let records = response as? [[String: Any]] else { return nil }
        return best(records.compactMap { record in
            let duration = (record["duration"] as? NSNumber)?.doubleValue ?? 0
            guard matches(title: record["trackName"] as? String ?? "", artist: record["artistName"] as? String ?? "", duration: duration, media: media), let text = record["syncedLyrics"] as? String, var result = LyricsParser.parse(text, source: "LRCLIB", duration: media.duration) else { return nil }
            result.matchScore = score(album: record["albumName"] as? String ?? "", duration: duration, media: media)
            return result
        })
    }
    static func netease(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        let response = try await json(request("https://music.163.com/api/search/get", ["s": "\(media.title) \(media.artist)", "type": "1", "limit": "12"]))
        guard let root = response as? [String: Any], let result = root["result"] as? [String: Any], let songs = result["songs"] as? [[String: Any]] else { return nil }
        let candidates = songs.filter { song in
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            return matches(title: song["name"] as? String ?? "", artist: artists, duration: ((song["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000, media: media)
        }.sorted { scoreSong($0, media) > scoreSong($1, media) }
        var found: [LyricsDocument] = []
        for song in candidates.prefix(2) {
            try Task.checkCancellation()
            guard let id = song["id"] as? Int else { continue }
            let response: Any
            do { response = try await json(LyricsEAPI.request(id: id)) } catch {
                try Task.checkCancellation()
                response = try await json(request("https://music.163.com/api/song/lyric/v1", ["id": String(id), "lv": "-1", "kv": "-1", "yv": "-1"]))
            }
            guard let body = response as? [String: Any] else { continue }
            for field in ["yrc", "klyric", "lrc"] {
                if let record = body[field] as? [String: Any], let raw = record["lyric"] as? String, var lyrics = LyricsParser.parse(raw, source: "网易云音乐", duration: media.duration) {
                    lyrics.matchScore = scoreSong(song, media); lyrics.trackIdentifier = "netease:\(id)"
                    found.append(lyrics)
                }
            }
        }
        return best(found)
    }
    private static func scoreSong(_ song: [String: Any], _ media: MediaSnapshot) -> Double {
        score(album: (song["album"] as? [String: Any])?["name"] as? String ?? "", duration: ((song["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000, media: media)
    }
    static func qq(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        var search = request("https://u.y.qq.com/cgi-bin/musicu.fcg")
        search.httpMethod = "POST"
        search.setValue("application/json", forHTTPHeaderField: "Content-Type")
        search.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        search.httpBody = try JSONSerialization.data(withJSONObject: ["req_1": ["module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicDesktop", "param": ["num_per_page": 12, "page_num": 1, "query": "\(media.title) \(media.artist)", "search_type": 0]]])
        guard let root = try await json(search) as? [String: Any], let result = root["req_1"] as? [String: Any], let body = (result["data"] as? [String: Any])?["body"] as? [String: Any], let songs = (body["song"] as? [String: Any])?["list"] as? [[String: Any]] else { return nil }
        let candidates = songs.filter { song in
            let artist = (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            return matches(title: song["title"] as? String ?? song["name"] as? String ?? "", artist: artist, duration: (song["interval"] as? NSNumber)?.doubleValue ?? 0, media: media)
        }.sorted { qqScore($0, media) > qqScore($1, media) }
        var found: [LyricsDocument] = []
        for song in candidates.prefix(2) {
            try Task.checkCancellation()
            guard let id = song["id"] as? Int else { continue }
            var query = request("https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg")
            query.httpMethod = "POST"
            query.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            query.setValue("https://c.y.qq.com/", forHTTPHeaderField: "Referer")
            query.httpBody = Data("musicid=\(id)&version=15&miniversion=82&lrctype=4".utf8)
            let raw = String(decoding: try await data(query), as: UTF8.self)
            if var doc = try decodeQQ(raw, duration: media.duration) {
                doc.matchScore = qqScore(song, media); doc.trackIdentifier = "qq:\(id)"; found.append(doc)
            }
        }
        return best(found)
    }
    private static func qqScore(_ song: [String: Any], _ media: MediaSnapshot) -> Double {
        score(album: (song["album"] as? [String: Any])?["name"] as? String ?? "", duration: (song["interval"] as? NSNumber)?.doubleValue ?? 0, media: media)
    }
    private static func decodeQQ(_ response: String, duration: Double) throws -> LyricsDocument? {
        let outer = response.replacingOccurrences(of: "<!--", with: "").replacingOccurrences(of: "-->", with: "")
        // The service wraps valid lyric content in a legacy, malformed XML envelope
        // (for example <miniversion="1" />). Parse only the content element.
        guard let begin = outer.range(of: #"<content(?:\s[^>]*)?>"#, options: .regularExpression),
              let end = outer.range(of: "</content>", range: begin.upperBound..<outer.endIndex) else { return nil }
        let fragment = "<content>" + outer[begin.upperBound..<end.lowerBound] + "</content>"
        let xml = try XMLDocument(xmlString: fragment, options: [.nodeLoadExternalEntitiesNever])
        guard let content = xml.rootElement()?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
        let compact = content.filter { !$0.isWhitespace }
        let decoded = !compact.isEmpty && compact.allSatisfy({ $0.isASCII && $0.isHexDigit }) ? try LyricsQRCDecoder.decode(compact) : content
        let text: String
        if decoded.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            let inner = try XMLDocument(xmlString: decoded, options: [.nodeLoadExternalEntitiesNever])
            text = try inner.nodes(forXPath: "//@LyricContent").first?.stringValue ?? ""
        } else { text = decoded }
        let separated = text.replacingOccurrences(of: #"\s+(?=\[\d+,\d+\])"#, with: "\n", options: .regularExpression)
        return LyricsParser.parse(separated, source: "QQ 音乐", duration: duration)
    }
    static func lookup(_ media: MediaSnapshot, onCandidate: @escaping @MainActor @Sendable (LyricsDocument) -> Void) async -> (document: LyricsDocument?, unavailable: Bool) {
        await withTaskGroup(of: (LyricsDocument?, Bool).self) { group in
            for provider in 0..<3 {
                group.addTask {
                    do {
                        let document: LyricsDocument?
                        switch provider { case 0: document = try await netease(media); case 1: document = try await qq(media); default: document = try await lrclib(media) }
                        return (document, false)
                    } catch { return (nil, true) }
                }
            }
            var documents: [LyricsDocument] = [], failures = 0
            for await (document, failed) in group {
                if Task.isCancelled { group.cancelAll(); break }
                if failed { failures += 1 }
                if let document { documents.append(document); await onCandidate(document) }
            }
            return (best(documents), failures == 3)
        }
    }
}
