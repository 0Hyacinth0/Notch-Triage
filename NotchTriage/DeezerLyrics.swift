import Foundation

/// Deezer's anonymous web lyric path, with public search as a fallback.
actor DeezerLyrics {
    static let shared = DeezerLyrics()
    private var token: String?
    private var tokenExpiry: Date = .distantPast

    private func authorization() async throws -> String {
        if let token, tokenExpiry.timeIntervalSinceNow > 30 { return token }
        let url = URL(string: "https://auth.deezer.com/login/anonymous?jo=p&rto=c&i=c")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["jwt"] as? String, !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        self.token = token
        self.tokenExpiry = jwtExpiry(token) ?? Date().addingTimeInterval(300)
        return token
    }

    private func jwtExpiry(_ value: String) -> Date? {
        let parts = value.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = claims["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }

    private func query(_ operation: String, _ graphQL: String, variables: [String: Any],
                       language: String) async throws -> [String: Any] {
        let payload: [String: Any] = ["operationName": operation, "query": graphQL,
                                      "variables": variables]
        let body = try JSONSerialization.data(withJSONObject: payload)
        for attempt in 0..<2 {
            var request = URLRequest(url: URL(string: "https://pipe.deezer.com/api")!, timeoutInterval: 9)
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(try await authorization())", forHTTPHeaderField: "Authorization")
            request.setValue(language, forHTTPHeaderField: "Accept-Language")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode,
                  data.count < 4_000_000,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            if attempt == 0, status == 401
                || String(describing: root["errors"] ?? "").contains("JwtTokenExpiredError") {
                token = nil; continue
            }
            guard status == 200 else { throw URLError(.badServerResponse) }
            if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
                if errors.contains(where: { String(describing: $0).contains("LyricsNotFoundError") }) { return [:] }
                throw URLError(.badServerResponse)
            }
            return root["data"] as? [String: Any] ?? [:]
        }
        throw URLError(.userAuthenticationRequired)
    }

    func lookup(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        let searchQuery = """
        query SearchTracks($query: String!, $first: Int!) {
          search(query: $query) { results { tracks(first: $first) { edges { node {
            id title duration hasSynchronizedLyrics
            contributors(first: 1) { edges { node { ... on Artist { name } } } }
            album { displayTitle }
          } } } } }
        }
        """
        let language = media.title.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) ? "zh-CN" : "en-US"
        var rows: [[String: Any]] = []
        do {
            let search = try await query("SearchTracks", searchQuery,
                                         variables: ["query": "\(media.artist) \(media.title)", "first": 10],
                                         language: language)
            let node = search["search"] as? [String: Any] ?? [:]
            let results = node["results"] as? [String: Any] ?? [:]
            let tracks = results["tracks"] as? [String: Any] ?? [:]
            rows = (tracks["edges"] as? [[String: Any]] ?? []).compactMap { $0["node"] as? [String: Any] }
        } catch {
            var components = URLComponents(string: "https://api.deezer.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: "\(media.artist) \(media.title)"),
                                     URLQueryItem(name: "limit", value: "10")]
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw error }
            rows = root["data"] as? [[String: Any]] ?? []
        }
        let matches = rows.compactMap { row -> (String, String, String, String, Double)? in
            let id = (row["id"] as? NSNumber)?.stringValue ?? row["id"] as? String ?? ""
            let title = row["title"] as? String ?? ""
            let contributor = (row["contributors"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
            let artist = ((contributor.first?["node"] as? [String: Any])?["name"] as? String)
                ?? (row["artist"] as? [String: Any])?["name"] as? String ?? ""
            let album = (row["album"] as? [String: Any])?["displayTitle"] as? String
                ?? (row["album"] as? [String: Any])?["title"] as? String ?? ""
            let duration = (row["duration"] as? NSNumber)?.doubleValue ?? 0
            guard !id.isEmpty,
                  LyricsProvider.matches(title: title, artist: artist, duration: duration, media: media) else { return nil }
            return (id, title, artist, album, duration)
        }.sorted { left, right in
            let leftAlbum = LyricsProvider.normalized(left.3) == LyricsProvider.normalized(media.album)
            let rightAlbum = LyricsProvider.normalized(right.3) == LyricsProvider.normalized(media.album)
            if leftAlbum != rightAlbum { return leftAlbum }
            return abs(left.4 - media.duration) < abs(right.4 - media.duration)
        }
        let lyricsQuery = """
        query SynchronizedTrackLyrics($trackId: String!) {
          track(trackId: $trackId) { lyrics {
            synchronizedLines { lrcTimestamp milliseconds line lineTranslated }
            synchronizedWordByWordLines { start end words { start end word } }
          } }
        }
        """
        var found: [LyricsDocument] = []
        for (id, title, artist, album, duration) in matches.prefix(3) {
            try Task.checkCancellation()
            let answer = try await query("SynchronizedTrackLyrics", lyricsQuery,
                                         variables: ["trackId": id], language: "zh-CN")
            let track = answer["track"] as? [String: Any] ?? [:]
            let lyric = track["lyrics"] as? [String: Any] ?? [:]
            let lines = lyric["synchronizedLines"] as? [[String: Any]] ?? []
            let lrc = lines.compactMap { row -> String? in
                guard let time = row["lrcTimestamp"] as? String,
                      let line = row["line"] as? String, !line.isEmpty else { return nil }
                return time + line
            }.joined(separator: "\n")
            guard var document = LyricsParser.parse(lrc, source: "Deezer", duration: media.duration) else { continue }
            for row in lines {
                guard let milliseconds = row["milliseconds"] as? NSNumber,
                      let translation = row["lineTranslated"] as? String, !translation.isEmpty,
                      let index = document.lines.indices.min(by: {
                          abs(document.lines[$0].start - milliseconds.doubleValue / 1000)
                              < abs(document.lines[$1].start - milliseconds.doubleValue / 1000)
                      }), abs(document.lines[index].start - milliseconds.doubleValue / 1000) < 0.2 else { continue }
                document.lines[index].translation = translation
            }
            let wordRows = lyric["synchronizedWordByWordLines"] as? [[String: Any]] ?? []
            var timed: [LyricLine] = []
            for row in wordRows {
                let words = (row["words"] as? [[String: Any]] ?? []).compactMap { word -> LyricWord? in
                    guard let start = word["start"] as? NSNumber, let end = word["end"] as? NSNumber,
                          let value = word["word"] as? String, end.doubleValue > start.doubleValue else { return nil }
                    return LyricWord(text: value, start: start.doubleValue / 1000, end: end.doubleValue / 1000)
                }
                guard let first = words.first, let last = words.last else { continue }
                timed.append(LyricLine(start: first.start, end: last.end, text: words.map(\.text).joined(), words: words))
            }
            let aligned = timed.filter { wordLine in
                document.lines.contains { abs($0.start - wordLine.start) < 1.5
                    && LyricsProvider.normalized($0.text) == LyricsProvider.normalized(wordLine.text) }
            }
            if !timed.isEmpty, Double(aligned.count) / Double(timed.count) >= 0.8 {
                for wordLine in timed {
                    guard let index = document.lines.indices.min(by: {
                        abs(document.lines[$0].start - wordLine.start) < abs(document.lines[$1].start - wordLine.start)
                    }), abs(document.lines[index].start - wordLine.start) < 1.5,
                    LyricsProvider.normalized(document.lines[index].text) == LyricsProvider.normalized(wordLine.text) else { continue }
                    document.lines[index].words = wordLine.words
                }
            }
            document.trackIdentifier = "deezer:\(id)"
            document.matchedTitle = title; document.matchedArtist = artist
            document.matchedAlbum = album; document.matchedDuration = duration
            document.matchScore = 6 + (LyricsProvider.normalized(album) == LyricsProvider.normalized(media.album) ? 2 : 0)
            found.append(document)
        }
        return LyricsProvider.best(found)
    }
}
