import Foundation

private actor LyricsRequestLimiter {
    private let limit = 4
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }
}

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
    private static func qqRequest(_ base: String, _ params: [String: String] = [:]) -> URLRequest {
        var query = request(base, params)
        query.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        return query
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
    private static let versionMarkers = ["live", "现场", "remix", "混音", "instrumental", "伴奏", "纯音乐", "karaoke", "翻唱", "cover", "acoustic", "不插电", "demo", "试听", "spedup", "slowed"]
    private static func hasVersionMarker(_ marker: String, in title: String) -> Bool {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if marker.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII }) {
            let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: marker) + "(?![A-Za-z])"
            return folded.range(of: pattern, options: .regularExpression) != nil
        }
        return normalized(folded).contains(normalized(marker))
    }
    private static func sameVersion(_ title: String, _ playing: String) -> Bool {
        return versionMarkers.allSatisfy { marker in
            hasVersionMarker(marker, in: title) == hasVersionMarker(marker, in: playing)
        }
    }
    static func matches(title: String, artist: String, duration: Double, media: MediaSnapshot) -> Bool {
        let exactTitle = normalized(title) == normalized(media.title)
        let closeDuration = duration > 0 && media.duration > 0 && abs(duration - media.duration) < 4
        guard exactTitle || (closeDuration && !titleStem(title).isEmpty && titleStem(title) == titleStem(media.title)) else { return false }
        guard sameVersion(title, media.title) else { return false }
        let expected = normalized(media.artist), actual = normalized(artist)
        let sharedArtist = !artistParts(media.artist).isDisjoint(with: artistParts(artist))
        guard !expected.isEmpty, !actual.isEmpty, sharedArtist || actual.contains(expected) || expected.contains(actual) else { return false }
        return media.duration <= 0 || duration <= 0 || abs(duration - media.duration) < (exactTitle ? 8 : 4)
    }
    private static func score(title: String, artist: String, album: String, duration: Double, media: MediaSnapshot) -> Double {
        let albumMatch = !media.album.isEmpty && normalized(album) == normalized(media.album)
        let durationMatch = duration > 0 && media.duration > 0 ? max(0, 1 - abs(duration - media.duration) / 5) : 0
        let titleMatch = normalized(title) == normalized(media.title)
        let artistMatch = normalized(artist) == normalized(media.artist)
        return (titleMatch ? 4 : 2) + (artistMatch ? 3 : 1.5) + (albumMatch ? 2 : 0) + durationMatch
    }
    static func isBetter(_ candidate: LyricsDocument, than existing: LyricsDocument?) -> Bool {
        guard let existing else { return true }
        if candidate.source == "本地导入" { return true }
        if existing.source == "本地导入" { return false }
        // All online candidates have already passed track identity checks.
        // Prefer real word timestamps before comparing the quality of those matches.
        if candidate.hasWordTiming != existing.hasWordTiming { return candidate.hasWordTiming }
        if candidate.isNativeMatch == true, existing.isNativeMatch != true { return true }
        if existing.isNativeMatch == true, candidate.isNativeMatch != true { return false }
        let candidateScore = candidate.matchScore ?? 0
        let existingScore = existing.matchScore ?? 0
        if abs(candidateScore - existingScore) > 0.01 { return candidateScore > existingScore }
        if candidate.hasWordTiming, (candidate.parserRevision ?? 0) > (existing.parserRevision ?? 0) { return true }
        return false
    }
    static func best(_ documents: [LyricsDocument]) -> LyricsDocument? {
        documents.reduce(nil) { current, candidate in isBetter(candidate, than: current) ? candidate : current }
    }
    static func hasActualLyrics(_ document: LyricsDocument, duration: Double) -> Bool {
        let sung = document.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { text in
                guard !text.isEmpty else { return false }
                if text.range(of: #"^(作词|作曲|编曲|制作人|歌手名|歌曲名|lyrics by|composer|arranger)\s*[:： ]"#,
                              options: [.regularExpression, .caseInsensitive]) != nil { return false }
                if text.contains("没有填词的纯音乐") || text.contains("纯音乐，请欣赏") { return false }
                return true
            }
        guard !sung.isEmpty else { return false }
        guard duration >= 60, sung.count == 1 else { return true }
        if sung[0].count == 1 { return false }
        if let title = document.matchedTitle,
           normalized(sung[0]) == normalized(title) { return false }
        return true
    }
    static func lrclib(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        let response = try await json(request("https://lrclib.net/api/search", ["track_name": media.title, "artist_name": media.artist]))
        guard let records = response as? [[String: Any]] else { return nil }
        return best(records.compactMap { record in
            let duration = (record["duration"] as? NSNumber)?.doubleValue ?? 0
            guard matches(title: record["trackName"] as? String ?? "", artist: record["artistName"] as? String ?? "", duration: duration, media: media), let text = record["syncedLyrics"] as? String, var result = LyricsParser.parse(text, source: "LRCLIB", duration: media.duration) else { return nil }
            result.matchScore = score(title: record["trackName"] as? String ?? "", artist: record["artistName"] as? String ?? "", album: record["albumName"] as? String ?? "", duration: duration, media: media)
            result.matchedTitle = record["trackName"] as? String
            result.matchedArtist = record["artistName"] as? String
            result.matchedAlbum = record["albumName"] as? String
            result.matchedDuration = duration
            if let identifier = record["id"] as? NSNumber { result.trackIdentifier = "lrclib:\(identifier)" }
            return result
        })
    }
    static func netease(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        var nativeCandidate: LyricsDocument?
        if media.bundleIdentifier?.lowercased().contains("netease") == true,
           let local = await LocalPlayerTrackCatalog.shared.netease(media), let id = Int(local.identifier),
           let document = try? await neteaseDocument(id: id, title: local.title, artist: local.artist,
                                                     album: local.album, duration: local.duration, media: media, native: true) {
            if document.hasWordTiming { return document }
            nativeCandidate = document
        }
        let response: Any
        do {
            response = try await json(request("https://music.163.com/api/search/get", ["s": "\(media.title) \(media.artist)", "type": "1", "limit": "12"]))
        } catch {
            if let nativeCandidate { return nativeCandidate }
            throw error
        }
        guard let root = response as? [String: Any], let result = root["result"] as? [String: Any], let songs = result["songs"] as? [[String: Any]] else { return nativeCandidate }
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
        var found: [LyricsDocument] = nativeCandidate.map { [$0] } ?? []
        var fetchAttempts = 0, fetchFailures = 0
        for song in candidates.prefix(2) {
            try Task.checkCancellation()
            guard let id = song["id"] as? Int else { continue }
            let artist = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            fetchAttempts += 1
            do {
                if let document = try await neteaseDocument(id: id, title: song["name"] as? String ?? "", artist: artist,
                                                            album: (song["album"] as? [String: Any])?["name"] as? String ?? "",
                                                            duration: ((song["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                                                            media: media, native: false) { found.append(document) }
            } catch { fetchFailures += 1 }
        }
        if found.isEmpty, fetchAttempts > 0, fetchFailures == fetchAttempts { throw URLError(.cannotConnectToHost) }
        return best(found)
    }
    private static func neteaseDocument(id: Int, title: String, artist: String, album: String,
                                        duration: Double, media: MediaSnapshot, native: Bool) async throws -> LyricsDocument? {
        let eapi = try? await json(LyricsEAPI.request(id: id)) as? [String: Any]
        let hasEAPILyrics = ["yrc", "klyric", "lrc"].contains { field in
            ((eapi?[field] as? [String: Any])?["lyric"] as? String)?.isEmpty == false
        }
        try Task.checkCancellation()
        let body: [String: Any]
        if hasEAPILyrics, let eapi { body = eapi }
        else {
            guard let fallback = try await json(request("https://music.163.com/api/song/lyric/v1", [
                "id": String(id), "lv": "-1", "kv": "-1", "yv": "-1"
            ])) as? [String: Any] else { return nil }
            body = fallback
        }
        var found: [LyricsDocument] = []
        for field in ["yrc", "klyric", "lrc"] {
            guard let record = body[field] as? [String: Any], let raw = record["lyric"] as? String,
                  var lyrics = LyricsParser.parse(raw, source: "网易云音乐", duration: media.duration,
                                                   format: field == "klyric" ? .klyric : field == "yrc" ? .yrc : .lrc) else { continue }
            if let translation = (body["tlyric"] as? [String: Any])?["lyric"] as? String {
                LyricsParser.attach(translation, to: &lyrics, as: .translation)
            }
            if let romanization = (body["romalrc"] as? [String: Any])?["lyric"] as? String {
                LyricsParser.attach(romanization, to: &lyrics, as: .romanization)
            }
            lyrics.matchScore = score(title: title, artist: artist, album: album, duration: duration, media: media)
            lyrics.trackIdentifier = "netease:\(id)"
            lyrics.matchedTitle = title; lyrics.matchedArtist = artist
            lyrics.matchedAlbum = album; lyrics.matchedDuration = duration
            lyrics.isNativeMatch = native
            found.append(lyrics)
        }
        return best(found)
    }
    private static func scoreSong(_ song: [String: Any], _ media: MediaSnapshot) -> Double {
        score(title: song["name"] as? String ?? "", artist: (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / "), album: (song["album"] as? [String: Any])?["name"] as? String ?? "", duration: ((song["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000, media: media)
    }
    static func qq(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        var nativeCandidate: LyricsDocument?
        if media.bundleIdentifier?.lowercased().contains("qqmusic") == true,
           let local = await LocalPlayerTrackCatalog.shared.qq(media) {
            let detail = try? await json(qqRequest("https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg", ["format": "json", "platform": "yqq", "songmid": local.identifier])) as? [String: Any]
            let id = ((detail?["data"] as? [[String: Any]])?.first?["id"] as? NSNumber)?.intValue
            if let id, let document = try? await qqDocument(id: id, title: local.title, artist: local.artist,
                                                            album: local.album, duration: local.duration, media: media, native: true) {
                if document.hasWordTiming { return document }
                nativeCandidate = document
            }
            if let document = try? await qqLineDocument(mid: local.identifier, title: local.title,
                                                        artist: local.artist, album: local.album,
                                                        duration: local.duration, media: media, native: true) {
                if isBetter(document, than: nativeCandidate) { nativeCandidate = document }
            }
        }
        var songs: [[String: Any]] = []
        var searchAnswered = false
        // The newer desktop search service can return code 2001 with an empty
        // list even when the track exists. The legacy JSON search still exposes
        // the song ID needed by the QRC download endpoint.
        for query in ["\(media.title) \(media.artist)", media.title] {
            var search = request("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", ["format": "json", "p": "1", "n": "20", "w": query])
            search.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            if let root = try? await json(search) as? [String: Any] {
                searchAnswered = true
                if let data = root["data"] as? [String: Any],
                   let list = (data["song"] as? [String: Any])?["list"] as? [[String: Any]] {
                    songs.append(contentsOf: list)
                }
            }
        }
        if songs.isEmpty {
            var search = request("https://u.y.qq.com/cgi-bin/musicu.fcg")
            search.httpMethod = "POST"
            search.setValue("application/json", forHTTPHeaderField: "Content-Type")
            search.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            search.httpBody = try JSONSerialization.data(withJSONObject: ["req_1": ["module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicDesktop", "param": ["num_per_page": 20, "page_num": 1, "query": "\(media.title) \(media.artist)", "search_type": 0]]])
            if let root = try? await json(search) as? [String: Any] {
                searchAnswered = true
                if let result = root["req_1"] as? [String: Any],
                   let body = (result["data"] as? [String: Any])?["body"] as? [String: Any],
                   let list = (body["song"] as? [String: Any])?["list"] as? [[String: Any]] {
                    songs = list
                }
            }
        }
        if !searchAnswered {
            if let nativeCandidate { return nativeCandidate }
            throw URLError(.cannotConnectToHost)
        }
        func matching(_ songs: [[String: Any]]) -> [[String: Any]] { songs.filter { song in
            let artist = (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            return matches(title: song["title"] as? String ?? song["songname"] as? String ?? song["name"] as? String ?? "", artist: artist, duration: (song["interval"] as? NSNumber)?.doubleValue ?? 0, media: media)
        }.sorted { qqScore($0, media) > qqScore($1, media) } }
        let candidates = matching(songs)
        var found: [LyricsDocument] = nativeCandidate.map { [$0] } ?? []
        var visited = Set<Int>()
        var lyricFetchAttempts = 0
        var lyricFetchFailures = 0
        for song in candidates {
            try Task.checkCancellation()
            guard let id = song["id"] as? Int ?? song["songid"] as? Int, visited.insert(id).inserted else { continue }
            if visited.count > 3 { break }
            let artist = (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
            let title = song["title"] as? String ?? song["songname"] as? String ?? song["name"] as? String ?? ""
            let album = (song["album"] as? [String: Any])?["name"] as? String ?? song["albumname"] as? String ?? ""
            let duration = (song["interval"] as? NSNumber)?.doubleValue ?? 0
            lyricFetchAttempts += 1
            let qrc: LyricsDocument?
            do {
                qrc = try await qqDocument(id: id, title: title, artist: artist, album: album,
                                           duration: duration, media: media, native: false)
            } catch {
                lyricFetchFailures += 1
                qrc = nil
            }
            let mid = song["mid"] as? String ?? song["songmid"] as? String ?? ""
            let document: LyricsDocument?
            if let qrc { document = qrc }
            else if !mid.isEmpty {
                lyricFetchAttempts += 1
                do {
                    document = try await qqLineDocument(mid: mid, title: title, artist: artist,
                                                        album: album, duration: duration, media: media, native: false)
                } catch {
                    lyricFetchFailures += 1
                    document = nil
                }
            } else { document = nil }
            if let document {
                found.append(document)
            }
        }
        if found.isEmpty, lyricFetchAttempts > 0, lyricFetchFailures == lyricFetchAttempts {
            throw URLError(.cannotConnectToHost)
        }
        return best(found)
    }
    private static func qqDocument(id: Int, title: String, artist: String, album: String,
                                   duration: Double, media: MediaSnapshot, native: Bool) async throws -> LyricsDocument? {
        var query = request("https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg")
        query.httpMethod = "POST"
        query.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        query.setValue("https://c.y.qq.com/", forHTTPHeaderField: "Referer")
        query.httpBody = Data("musicid=\(id)&version=15&miniversion=82&lrctype=4".utf8)
        let raw = String(decoding: try await data(query), as: UTF8.self)
        guard var document = try decodeQQ(raw, duration: media.duration) else { return nil }
        document.matchScore = score(title: title, artist: artist, album: album, duration: duration, media: media)
        document.trackIdentifier = "qq:\(id)"
        document.matchedTitle = title; document.matchedArtist = artist
        document.matchedAlbum = album; document.matchedDuration = duration
        document.isNativeMatch = native
        return document
    }
    private static func qqLineDocument(mid: String, title: String, artist: String, album: String,
                                       duration: Double, media: MediaSnapshot, native: Bool) async throws -> LyricsDocument? {
        let response = String(decoding: try await data(qqRequest(
            "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
            ["format": "json", "nobase64": "1", "g_tk": "5381", "songmid": mid]
        )), as: UTF8.self)
        guard let begin = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), begin < end,
              let body = String(response[begin...end]).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              [0, -1901].contains((object["code"] as? NSNumber)?.intValue ?? 0),
              [0, -1901].contains((object["retcode"] as? NSNumber)?.intValue ?? 0),
              let raw = object["lyric"] as? String,
              var document = LyricsParser.parse(raw, source: "QQ 音乐", duration: media.duration) else { return nil }
        if let translation = object["trans"] as? String {
            LyricsParser.attach(translation, to: &document, as: .translation)
        }
        document.matchScore = score(title: title, artist: artist, album: album, duration: duration, media: media)
        document.trackIdentifier = "qqmid:\(mid)"
        document.matchedTitle = title; document.matchedArtist = artist
        document.matchedAlbum = album; document.matchedDuration = duration
        document.isNativeMatch = native
        return document
    }
    private static func qqScore(_ song: [String: Any], _ media: MediaSnapshot) -> Double {
        let album = (song["album"] as? [String: Any])?["name"] as? String ?? song["albumname"] as? String ?? ""
        let title = song["title"] as? String ?? song["songname"] as? String ?? song["name"] as? String ?? ""
        let artist = (song["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " / ")
        return score(title: title, artist: artist, album: album, duration: (song["interval"] as? NSNumber)?.doubleValue ?? 0, media: media)
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

    private static func sourceFile(_ rawURL: String, allowedDomain: String) async throws -> String? {
        let address = rawURL.hasPrefix("//") ? "https:" + rawURL : rawURL
        guard var parts = URLComponents(string: address),
              let host = parts.host?.lowercased(),
              host == allowedDomain || host.hasSuffix("." + allowedDomain) else { return nil }
        parts.scheme = "https"
        guard let url = parts.url else { return nil }
        var query = URLRequest(url: url, timeoutInterval: 8)
        query.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let bytes = try await data(query)
        return String(data: bytes, encoding: .utf8)
    }
    private static func removeMiguHeading(_ document: inout LyricsDocument) {
        document.lines.removeAll { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.range(of: #"^(歌曲名|歌手名)(\s|[:：]|$)|^@migu music@$"#,
                              options: .regularExpression) != nil
        }
    }
    static func migu(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        var search = request("https://pd.musicapp.migu.cn/MIGUM2.0/v1.0/content/search_all.do", [
            "text": "\(media.title) \(media.artist)", "pageNo": "1", "pageSize": "10",
            "searchSwitch": "{\"song\":1}", "isCorrect": "1"
        ])
        search.setValue("https://m.music.migu.cn/", forHTTPHeaderField: "Referer")
        search.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let root = try await json(search) as? [String: Any],
              (root["code"] as? String ?? "000000") == "000000",
              let items = (root["songResultData"] as? [String: Any])?["result"] as? [[String: Any]] else { return nil }
        var results: [LyricsDocument] = []
        var fetchAttempts = 0, fetchFailures = 0
        for item in items {
            try Task.checkCancellation()
            let title = item["name"] as? String ?? ""
            let artist = (item["singers"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }.joined(separator: " / ")
            let album = (item["albums"] as? [[String: Any]])?.first?["name"] as? String ?? ""
            guard matches(title: title, artist: artist, duration: 0, media: media) else { continue }
            if results.count >= 2 { break }
            fetchAttempts += 1
            var document: LyricsDocument?
            if let lyricURL = item["lyricUrl"] as? String, !lyricURL.isEmpty,
               let raw = try? await sourceFile(lyricURL, allowedDomain: "migu.cn") {
                document = LyricsParser.parse(raw, source: "咪咕音乐", duration: media.duration)
                if var parsed = document {
                    removeMiguHeading(&parsed)
                    document = parsed
                }
            }
            var translation: String?
            if let translationURL = item["trcUrl"] as? String,
               let raw = try? await sourceFile(translationURL, allowedDomain: "migu.cn") {
                translation = raw
            }
            if let mrcURL = item["mrcurl"] as? String,
               let mrc = try? await sourceFile(mrcURL, allowedDomain: "migu.cn"),
               let wordDocument = MiguMRC.parse(mrc, duration: media.duration),
               wordDocument.lines.count >= max(1, (document?.lines.count ?? 1) / 2) {
                document = wordDocument
            }
            guard var document, !document.lines.isEmpty else {
                continue
            }
            if let translation { LyricsParser.attach(translation, to: &document, as: .translation) }
            document.trackIdentifier = (item["copyrightId"] as? String).map { "migu:\($0)" }
            document.matchedTitle = title; document.matchedArtist = artist
            document.matchedAlbum = album
            document.matchScore = score(title: title, artist: artist, album: album, duration: 0, media: media)
            results.append(document)
        }
        if results.isEmpty, fetchAttempts > 0, fetchFailures == fetchAttempts { throw URLError(.cannotConnectToHost) }
        return best(results)
    }
    static func kuwo(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        var search = request("https://search.kuwo.cn/r.s", [
            "all": "\(media.title) \(media.artist)", "ft": "music", "itemset": "web_2013",
            "client": "kt", "pn": "0", "rn": "12", "rformat": "json",
            "encoding": "utf8", "pcjson": "1", "vipver": "1"
        ])
        search.setValue("https://www.kuwo.cn/", forHTTPHeaderField: "Referer")
        search.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let root = try await json(search) as? [String: Any],
              let items = root["abslist"] as? [[String: Any]] else { return nil }
        let matching = items.compactMap { item -> (String, String, String, Double, String, Double)? in
            let title = item["SONGNAME"] as? String ?? ""
            let artist = item["ARTIST"] as? String ?? ""
            let album = item["ALBUM"] as? String ?? ""
            let duration = Double(item["DURATION"] as? String ?? "") ?? 0
            let identifier = (item["MUSICRID"] as? String ?? "").split(separator: "_").last.map(String.init) ?? ""
            guard !identifier.isEmpty, matches(title: title, artist: artist, duration: duration, media: media) else { return nil }
            return (title, artist, album, duration, identifier,
                    score(title: title, artist: artist, album: album, duration: duration, media: media))
        }.sorted { $0.5 > $1.5 }
        var results: [LyricsDocument] = []
        var fetchAttempts = 0, fetchFailures = 0
        for (title, artist, album, duration, identifier, rank) in matching.prefix(3) {
            try Task.checkCancellation()
            fetchAttempts += 1
            var query = request("https://kuwo.cn/openapi/v1/www/lyric/getlyric", ["musicId": identifier])
            query.setValue("https://kuwo.cn/", forHTTPHeaderField: "Referer")
            query.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let root = try? await json(query) as? [String: Any]
            let lines = (root?["data"] as? [String: Any])?["lrclist"] as? [[String: Any]] ?? []
            let lrc = lines.compactMap { row -> String? in
                let time = Double(row["time"] as? String ?? "") ?? (row["time"] as? NSNumber)?.doubleValue
                guard let time, time >= 0, let body = row["lineLyric"] as? String,
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return String(format: "[%02d:%06.3f]", Int(time / 60), time.truncatingRemainder(dividingBy: 60)) + body
            }.joined(separator: "\n")
            var lineDocument = LyricsParser.parse(lrc, source: "酷我音乐", duration: media.duration)
            if lineDocument == nil {
                lineDocument = await KuwoLRCX.fetchLine(musicID: identifier, duration: media.duration)
            }
            guard var document = lineDocument else {
                if root == nil { fetchFailures += 1 }
                continue
            }
            if let timed = await KuwoLRCX.fetch(musicID: identifier, duration: media.duration),
               timed.lines.count >= max(1, document.lines.count / 2) {
                var upgraded = timed
                // The web LRC can include translation rows absent from the
                // client word track. Keep those only when the timestamps agree.
                for original in document.lines where original.translation != nil {
                    if let index = upgraded.lines.indices.min(by: {
                        abs(upgraded.lines[$0].start - original.start) < abs(upgraded.lines[$1].start - original.start)
                    }), abs(upgraded.lines[index].start - original.start) < 0.15 {
                        upgraded.lines[index].translation = original.translation
                    }
                }
                document = upgraded
            }
            document.trackIdentifier = "kuwo:\(identifier)"
            document.matchedTitle = title; document.matchedArtist = artist
            document.matchedAlbum = album; document.matchedDuration = duration
            document.matchScore = rank
            results.append(document)
        }
        if results.isEmpty, fetchAttempts > 0, fetchFailures == fetchAttempts { throw URLError(.cannotConnectToHost) }
        return best(results)
    }
    static func lookup(_ media: MediaSnapshot, preferences: LyricsSourcePreferences, onCandidate: @escaping @MainActor @Sendable (LyricsDocument) -> Void) async -> (document: LyricsDocument?, unavailable: Bool, sourceStatus: [LyricsSourceID: String]) {
        let limiter = LyricsRequestLimiter()
        return await withTaskGroup(of: (LyricsSourceID, LyricsDocument?, Bool, Bool, String?).self) { group in
            let sources = preferences.orderedEnabledSources(for: media)
            for provider in sources {
                group.addTask {
                    let isNetwork = provider != .appleMusicLocal && provider != .kugouLocal
                    if provider == .appleMusicOnline, AppleMusicCredential.read() == nil {
                        return (provider, nil, false, true, "尚未连接 Apple Music 账户")
                    }
                    if isNetwork, !(await LyricsSourceHealth.shared.allows(provider)) {
                        return (provider, nil, true, true, nil)
                    }
                    if isNetwork { await limiter.enter() }
                    defer {
                        if isNetwork { Task { await limiter.leave() } }
                    }
                    if Task.isCancelled { return (provider, nil, false, true, "查询已取消") }
                    do {
                        let document: LyricsDocument?
                        switch provider {
                        case .netease: document = try await netease(media)
                        case .qq: document = try await qq(media)
                        case .migu: document = try await migu(media)
                        case .kuwo: document = try await kuwo(media)
                        case .soda: document = try await SodaLyrics.lookup(media)
                        case .amll: document = try await AMLLLyrics.lookup(media)
                        case .musixmatch: document = try await MusixmatchLyrics.shared.lookup(media)
                        case .deezer: document = try await DeezerLyrics.shared.lookup(media)
                        case .lyricFind: document = try await LyricFindLyrics.lookup(media)
                        case .lrclib: document = try await lrclib(media)
                        case .appleMusicLocal: document = AppleMusicLocalLyrics.lookup(media)
                        case .appleMusicOnline: document = try await AppleMusicOnlineLyrics.shared.lookup(media)
                        case .kugouLocal: document = KugouLocalLyrics.lookup(media)
                        case .kugouOnline: document = try await KugouOnlineLyrics.lookup(media)
                        }
                        if isNetwork { await LyricsSourceHealth.shared.record(provider, failed: false) }
                        let usable = document.flatMap { hasActualLyrics($0, duration: media.duration) ? $0 : nil }
                        return (provider, usable, false, false, nil)
                    } catch {
                        if provider == .appleMusicOnline,
                           let problem = error as? AppleMusicOnlineLyrics.LookupError,
                           case .expired = problem {
                            await AppleMusicAccount.shared.authorizationExpired()
                        }
                        if isNetwork, !Task.isCancelled { await LyricsSourceHealth.shared.record(provider, failed: true) }
                        let detail: String? = (error as? AppleMusicOnlineLyrics.LookupError).map { problem in
                            switch problem {
                            case .expired: return "账户授权失效，请重新连接"
                            case .tokenUnavailable: return "Apple Music 连接暂不可用"
                            case .accountUnavailable: return "无法确认 Apple Music 账户地区"
                            }
                        }
                        return (provider, nil, true, false, detail)
                    }
                }
            }
            var documents: [LyricsDocument] = [], failures = 0
            var sourceStatus: [LyricsSourceID: String] = [:]
            for await (provider, document, failed, skipped, detail) in group {
                if Task.isCancelled { group.cancelAll(); break }
                if failed { failures += 1 }
                sourceStatus[provider] = detail ?? (skipped ? "连接暂缓，点击重新查找可重试"
                    : failed ? "连接失败"
                    : document == nil ? "未找到匹配歌词"
                    : (document?.hasWordTiming == true ? "已找到逐字歌词" : "已找到逐行歌词"))
                if let document { documents.append(document); await onCandidate(document) }
            }
            let selected = documents.reduce(nil as LyricsDocument?) { current, candidate in
                preferences.prefers(candidate, to: current) ? candidate : current
            }
            let networkCount = sources.filter { $0 != .appleMusicLocal && $0 != .kugouLocal }.count
            return (selected, networkCount > 0 && failures == networkCount, sourceStatus)
        }
    }
}
