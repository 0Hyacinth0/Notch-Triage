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
    private static func titleStem(_ title: String) -> String {
        let stem = title.replacingOccurrences(of: #"\s*[\(\[（【][^\)\]）】]*[\)\]）】]\s*$"#, with: "", options: .regularExpression)
        return normalized(stem)
    }
    private static func artistParts(_ artist: String) -> Set<String> {
        let separated = artist.replacingOccurrences(of: #"(?i)\b(?:feat\.?|ft\.?)\b"#, with: "/", options: .regularExpression)
        return Set(separated.components(separatedBy: CharacterSet(charactersIn: "/&、,，;；+"))
            .map(normalized).filter { !$0.isEmpty })
    }
    static func matches(title: String, artist: String, duration: Double, media: MediaSnapshot) -> Bool {
        let exactTitle = normalized(title) == normalized(media.title)
        let closeDuration = duration > 0 && media.duration > 0 && abs(duration - media.duration) < 4
        guard exactTitle || (closeDuration && !titleStem(title).isEmpty && titleStem(title) == titleStem(media.title)) else { return false }
        let expected = normalized(media.artist), actual = normalized(artist)
        let sharedArtist = !artistParts(media.artist).isDisjoint(with: artistParts(artist))
        guard !expected.isEmpty, !actual.isEmpty, sharedArtist || actual.contains(expected) || expected.contains(actual) else { return false }
        return media.duration <= 0 || duration <= 0 || abs(duration - media.duration) < (exactTitle ? 8 : 4)
    }
    private static func score(album: String, duration: Double, media: MediaSnapshot) -> Double {
        let albumMatch = !media.album.isEmpty && normalized(album) == normalized(media.album)
        let durationMatch = duration > 0 && media.duration > 0 ? max(0, 1 - abs(duration - media.duration) / 5) : 0
        return (albumMatch ? 2 : 0) + durationMatch
    }
    static func isBetter(_ candidate: LyricsDocument, than existing: LyricsDocument?) -> Bool {
        guard let existing else { return true }
        if candidate.hasWordTiming != existing.hasWordTiming { return candidate.hasWordTiming }
        if candidate.hasWordTiming, (candidate.parserRevision ?? 0) > (existing.parserRevision ?? 0) { return true }
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
        func matching(_ songs: [[String: Any]]) -> [[String: Any]] { songs.filter { song in
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            return matches(title: song["name"] as? String ?? "", artist: artists, duration: ((song["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000, media: media)
        }.sorted { scoreSong($0, media) > scoreSong($1, media) } }
        var candidates = matching(songs)
        if candidates.isEmpty,
           let fallback = try? await json(request("https://music.163.com/api/search/get", ["s": media.title, "type": "1", "limit": "20"])) as? [String: Any],
           let results = fallback["result"] as? [String: Any], let songs = results["songs"] as? [[String: Any]] {
            candidates = matching(songs)
        }
        var found: [LyricsDocument] = []
        for song in candidates.prefix(2) {
            try Task.checkCancellation()
            guard let id = song["id"] as? Int else { continue }
            let response: Any
            do {
                do { response = try await json(LyricsEAPI.request(id: id)) } catch {
                    try Task.checkCancellation()
                    response = try await json(request("https://music.163.com/api/song/lyric/v1", ["id": String(id), "lv": "-1", "kv": "-1", "yv": "-1"]))
                }
            } catch { try Task.checkCancellation(); continue }
            guard let body = response as? [String: Any] else { continue }
            for field in ["yrc", "klyric", "lrc"] {
                if let record = body[field] as? [String: Any], let raw = record["lyric"] as? String, var lyrics = LyricsParser.parse(raw, source: "网易云音乐", duration: media.duration, format: field == "klyric" ? .klyric : field == "yrc" ? .yrc : .lrc) {
                    lyrics.matchScore = scoreSong(song, media); lyrics.trackIdentifier = "netease:\(id)"
                    found.append(lyrics)
                }
            }
            if let timed = best(found), timed.hasWordTiming { return timed }
        }
        return best(found)
    }
    private static func scoreSong(_ song: [String: Any], _ media: MediaSnapshot) -> Double {
        score(album: (song["album"] as? [String: Any])?["name"] as? String ?? "", duration: ((song["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000, media: media)
    }
    static func qq(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        var songs: [[String: Any]] = []
        // The newer desktop search service can return code 2001 with an empty
        // list even when the track exists. The legacy JSON search still exposes
        // the song ID needed by the QRC download endpoint.
        for query in ["\(media.title) \(media.artist)", media.title] {
            var search = request("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", ["format": "json", "p": "1", "n": "20", "w": query])
            search.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            if let root = try? await json(search) as? [String: Any],
               let data = root["data"] as? [String: Any],
               let list = (data["song"] as? [String: Any])?["list"] as? [[String: Any]] {
                songs.append(contentsOf: list)
            }
        }
        if songs.isEmpty {
            var search = request("https://u.y.qq.com/cgi-bin/musicu.fcg")
            search.httpMethod = "POST"
            search.setValue("application/json", forHTTPHeaderField: "Content-Type")
            search.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            search.httpBody = try JSONSerialization.data(withJSONObject: ["req_1": ["module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicDesktop", "param": ["num_per_page": 20, "page_num": 1, "query": "\(media.title) \(media.artist)", "search_type": 0]]])
            if let root = try? await json(search) as? [String: Any],
               let result = root["req_1"] as? [String: Any],
               let body = (result["data"] as? [String: Any])?["body"] as? [String: Any],
               let list = (body["song"] as? [String: Any])?["list"] as? [[String: Any]] {
                songs = list
            }
        }
        func matching(_ songs: [[String: Any]]) -> [[String: Any]] { songs.filter { song in
            let artist = (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            return matches(title: song["title"] as? String ?? song["songname"] as? String ?? song["name"] as? String ?? "", artist: artist, duration: (song["interval"] as? NSNumber)?.doubleValue ?? 0, media: media)
        }.sorted { qqScore($0, media) > qqScore($1, media) } }
        let candidates = matching(songs)
        var found: [LyricsDocument] = []
        var visited = Set<Int>()
        for song in candidates {
            try Task.checkCancellation()
            guard let id = song["id"] as? Int ?? song["songid"] as? Int, visited.insert(id).inserted else { continue }
            if visited.count > 3 { break }
            var query = request("https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg")
            query.httpMethod = "POST"
            query.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            query.setValue("https://c.y.qq.com/", forHTTPHeaderField: "Referer")
            query.httpBody = Data("musicid=\(id)&version=15&miniversion=82&lrctype=4".utf8)
            do {
                let raw = String(decoding: try await data(query), as: UTF8.self)
                if var doc = try decodeQQ(raw, duration: media.duration) {
                    doc.matchScore = qqScore(song, media); doc.trackIdentifier = "qq:\(id)"; found.append(doc)
                }
            } catch { try Task.checkCancellation(); continue }
            if let timed = best(found), timed.hasWordTiming { return timed }
        }
        return best(found)
    }
    private static func qqScore(_ song: [String: Any], _ media: MediaSnapshot) -> Double {
        let album = (song["album"] as? [String: Any])?["name"] as? String ?? song["albumname"] as? String ?? ""
        let title = song["title"] as? String ?? song["songname"] as? String ?? song["name"] as? String ?? ""
        return score(album: album, duration: (song["interval"] as? NSNumber)?.doubleValue ?? 0, media: media)
            + (normalized(title) == normalized(media.title) ? 4 : 0)
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
            // Some valid QQ QRC payloads contain a bare '&' inside LyricContent.
            // Their XML envelope cannot be parsed strictly, so read the attribute
            // directly and leave literal ampersands in the lyric text intact.
            guard let begin = decoded.range(of: "LyricContent=\"") else { return nil }
            let remainder = decoded[begin.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { return nil }
            text = String(remainder[..<end])
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
        } else { text = decoded }
        let separated = text.replacingOccurrences(of: #"\s+(?=\[\d+,\d+\])"#, with: "\n", options: .regularExpression)
        return LyricsParser.parse(separated, source: "QQ 音乐", duration: duration, format: .qrc)
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
