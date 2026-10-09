import Foundation

/// Search, identify and download a Kugou lyric candidate. KRC is preferred;
/// the line LRC remains a fallback when that file is unavailable.
enum KugouOnlineLyrics {
    private static func json(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 7)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return object
    }

    private static func variants(_ components: URLComponents) -> [URL] {
        guard let host = components.host else { return [] }
        let hosts: [String]
        switch host {
        case "krcs.kugou.com", "lyrics.kugou.com": hosts = ["krcs.kugou.com", "lyrics.kugou.com"]
        default: hosts = [host]
        }
        return hosts.flatMap { host -> [URL] in
            ["https", "http"].compactMap { scheme in
                var item = components
                item.scheme = scheme; item.host = host
                return item.url
            }
        }
    }

    private static func load(_ components: URLComponents) async throws -> [String: Any] {
        var lastError: Error = URLError(.cannotConnectToHost)
        for url in variants(components) {
            try Task.checkCancellation()
            do { return try await json(url) }
            catch { lastError = error }
        }
        throw lastError
    }

    static func lookup(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        var search = URLComponents(string: "https://songsearch.kugou.com/song_search_v2")!
        search.queryItems = [
            URLQueryItem(name: "keyword", value: "\(media.artist) \(media.title)"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "20"),
            URLQueryItem(name: "platform", value: "WebFilter"),
            URLQueryItem(name: "tag", value: "em"),
            URLQueryItem(name: "iscorrection", value: "1")
        ]
        let result = try await json(search.url!)
        let rows = (result["data"] as? [String: Any])?["lists"] as? [[String: Any]] ?? []
        let matching = rows.compactMap { row -> (String, String, String, String, Double)? in
            let title = (row["SongName"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let artist = (row["SingerName"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let album = row["AlbumName"] as? String ?? ""
            let hash = row["FileHash"] as? String ?? ""
            let duration = (row["Duration"] as? NSNumber)?.doubleValue ?? 0
            guard !hash.isEmpty, LyricsProvider.matches(title: title, artist: artist,
                                                         duration: duration, media: media) else { return nil }
            return (title, artist, album, hash, duration)
        }.sorted { left, right in
            let leftAlbum = LyricsProvider.normalized(left.2) == LyricsProvider.normalized(media.album)
            let rightAlbum = LyricsProvider.normalized(right.2) == LyricsProvider.normalized(media.album)
            if leftAlbum != rightAlbum { return leftAlbum }
            return abs(left.4 - media.duration) < abs(right.4 - media.duration)
        }
        var found: [LyricsDocument] = []
        var failures = 0, attempts = 0
        for (title, artist, album, hash, duration) in matching.prefix(3) {
            try Task.checkCancellation()
            var candidates = URLComponents(string: "https://krcs.kugou.com/search")!
            candidates.queryItems = [
                URLQueryItem(name: "ver", value: "1"),
                URLQueryItem(name: "man", value: "yes"),
                URLQueryItem(name: "client", value: "mobi"),
                URLQueryItem(name: "keyword", value: "\(artist) - \(title)"),
                URLQueryItem(name: "duration", value: String(Int(duration * 1000))),
                URLQueryItem(name: "hash", value: hash)
            ]
            attempts += 1
            let root: [String: Any]
            do { root = try await load(candidates) }
            catch { failures += 1; continue }
            guard let list = root["candidates"] as? [[String: Any]] else { continue }
            for entry in list.prefix(3) {
                let id = (entry["id"] as? NSNumber)?.stringValue ?? entry["id"] as? String ?? ""
                let accessKey = entry["accesskey"] as? String ?? ""
                let candidateTitle = entry["song"] as? String ?? title
                let candidateArtist = entry["singer"] as? String ?? artist
                let candidateDuration = Double((entry["duration"] as? NSNumber)?.intValue ?? 0) / 1000
                guard !id.isEmpty, !accessKey.isEmpty,
                      LyricsProvider.matches(title: candidateTitle, artist: candidateArtist,
                                             duration: candidateDuration, media: media) else { continue }
                var lyric: LyricsDocument?
                for format in ["krc", "lrc"] {
                    var download = URLComponents(string: "https://lyrics.kugou.com/download")!
                    download.queryItems = [
                        URLQueryItem(name: "ver", value: "1"),
                        URLQueryItem(name: "client", value: "pc"),
                        URLQueryItem(name: "id", value: id),
                        URLQueryItem(name: "accesskey", value: accessKey),
                        URLQueryItem(name: "fmt", value: format),
                        URLQueryItem(name: "charset", value: "utf8")
                    ]
                    attempts += 1
                    let file: [String: Any]
                    do { file = try await load(download) }
                    catch { failures += 1; continue }
                    guard let base64 = file["content"] as? String,
                          let bytes = Data(base64Encoded: base64) else { continue }
                    if format == "krc", let plain = LyricsKRC.decode(bytes) {
                        lyric = LyricsKRC.parse(plain, duration: media.duration)
                    } else if format == "lrc", let plain = String(data: bytes, encoding: .utf8) {
                        lyric = LyricsParser.parse(plain, source: "酷狗音乐在线歌词", duration: media.duration)
                    }
                    if lyric != nil { break }
                }
                guard var lyric else { continue }
                lyric.source = "酷狗音乐在线歌词"
                lyric.trackIdentifier = "kugou:\(hash):\(id)"
                lyric.matchedTitle = candidateTitle; lyric.matchedArtist = candidateArtist
                lyric.matchedAlbum = album; lyric.matchedDuration = duration
                lyric.matchScore = 7 + (LyricsProvider.normalized(album) == LyricsProvider.normalized(media.album) ? 2 : 0)
                found.append(lyric)
            }
        }
        if found.isEmpty, attempts > 0, failures == attempts { throw URLError(.cannotConnectToHost) }
        return LyricsProvider.best(found)
    }
}
