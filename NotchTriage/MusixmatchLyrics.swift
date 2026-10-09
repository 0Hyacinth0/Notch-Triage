import Foundation

/// Anonymous Musixmatch catalogue and timed lyric lookup.
actor MusixmatchLyrics {
    static let shared = MusixmatchLyrics()
    private var token: String?
    private var tokenFetchedAt: Date = .distantPast

    private func request(_ action: String, parameters: [String: String] = [:],
                         needsToken: Bool = true) async throws -> [String: Any] {
        var query = parameters
        query["app_id"] = "mac-ios-v2.0"
        query["t"] = String(Int(Date().timeIntervalSince1970))
        if needsToken { query["usertoken"] = try await credential() }
        var lastError: Error = URLError(.cannotConnectToHost)
        for host in ["apic-appmobile.musixmatch.com", "apic.musixmatch.com"] {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://\(host)/ws/1.1/\(action)")!
            url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: url.url!, timeoutInterval: 8)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = root["message"] as? [String: Any],
                      let header = message["header"] as? [String: Any],
                      let code = (header["status_code"] as? NSNumber)?.intValue else {
                    throw URLError(.badServerResponse)
                }
                if code == 401 { throw URLError(.userAuthenticationRequired) }
                if code == 404 { return [:] }
                guard code == 200 else { throw URLError(.badServerResponse) }
                return message["body"] as? [String: Any] ?? [:]
            } catch { lastError = error }
        }
        throw lastError
    }

    private func credential() async throws -> String {
        if let token, Date().timeIntervalSince(tokenFetchedAt) < 3_600 { return token }
        let answer = try await request("token.get", parameters: ["user_language": "en"], needsToken: false)
        guard let token = (answer["user_token"] as? String), !token.isEmpty,
              !token.hasPrefix("UpgradeOnly") else { throw URLError(.userAuthenticationRequired) }
        self.token = token; tokenFetchedAt = Date()
        return token
    }

    func lookup(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        let answer = try await request("track.search", parameters: [
            "q_artist": media.artist, "q_track": media.title,
            "s_track_rating": "desc", "page_size": "8", "page": "1"
        ])
        let candidates = (answer["track_list"] as? [[String: Any]] ?? [])
            .compactMap { $0["track"] as? [String: Any] }
            .compactMap { row -> (String, String, String, String, Double, Bool)? in
                let id = (row["track_id"] as? NSNumber)?.stringValue ?? ""
                let title = row["track_name"] as? String ?? ""
                let artist = row["artist_name"] as? String ?? ""
                let album = row["album_name"] as? String ?? ""
                let duration = (row["track_length"] as? NSNumber)?.doubleValue ?? 0
                guard !id.isEmpty, (row["has_subtitles"] as? NSNumber)?.intValue == 1,
                      LyricsProvider.matches(title: title, artist: artist, duration: duration, media: media) else { return nil }
                let richsync = (row["has_richsync"] as? NSNumber)?.intValue == 1
                return (id, title, artist, album, duration, richsync)
            }.sorted { left, right in
                let leftAlbum = LyricsProvider.normalized(left.3) == LyricsProvider.normalized(media.album)
                let rightAlbum = LyricsProvider.normalized(right.3) == LyricsProvider.normalized(media.album)
                if leftAlbum != rightAlbum { return leftAlbum }
                return abs(left.4 - media.duration) < abs(right.4 - media.duration)
            }
        var found: [LyricsDocument] = []
        for (id, title, artist, album, duration, hasRichsync) in candidates.prefix(3) {
            try Task.checkCancellation()
            let response = try await request("track.subtitle.get", parameters: [
                "track_id": id, "subtitle_format": "lrc"
            ])
            guard let lyric = response["subtitle"] as? [String: Any],
                  let lrc = lyric["subtitle_body"] as? String,
                  var document = LyricsParser.parse(lrc, source: "Musixmatch", duration: media.duration) else { continue }
            if hasRichsync,
               let rich = try? await request("track.richsync.get", parameters: ["track_id": id]),
               let body = rich["richsync"] as? [String: Any],
               let raw = body["richsync_body"] as? String,
               let bytes = raw.data(using: .utf8),
               let rows = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] {
                var timed: [LyricLine] = []
                for row in rows {
                    guard let start = row["ts"] as? NSNumber,
                          let end = row["te"] as? NSNumber,
                          end.doubleValue > start.doubleValue else { continue }
                    let items = row["l"] as? [[String: Any]] ?? []
                    var words: [LyricWord] = []
                    for item in items {
                        guard let offset = item["o"] as? NSNumber,
                              let value = item["c"] as? String else { continue }
                        let wordStart = start.doubleValue + offset.doubleValue
                        if value.trimmingCharacters(in: .whitespaces).isEmpty {
                            if !words.isEmpty { words[words.count - 1].text += value }
                        } else { words.append(LyricWord(text: value, start: wordStart, end: end.doubleValue)) }
                    }
                    for index in words.indices.dropLast() {
                        words[index].end = max(words[index].start, words[index + 1].start)
                    }
                    if words.count == 1, words[0].text.count >= 4 { continue }
                    if !words.isEmpty {
                        timed.append(LyricLine(start: start.doubleValue, end: end.doubleValue,
                                               text: words.map(\.text).joined(), words: words))
                    }
                }
                for wordLine in timed {
                    guard let index = document.lines.indices.min(by: {
                        abs(document.lines[$0].start - wordLine.start) < abs(document.lines[$1].start - wordLine.start)
                    }), abs(document.lines[index].start - wordLine.start) < 0.7,
                    LyricsProvider.normalized(document.lines[index].text) == LyricsProvider.normalized(wordLine.text) else { continue }
                    document.lines[index].words = wordLine.words
                }
            }
            document.trackIdentifier = "musixmatch:\(id)"
            document.matchedTitle = title; document.matchedArtist = artist
            document.matchedAlbum = album; document.matchedDuration = duration
            document.matchScore = 6 + (LyricsProvider.normalized(album) == LyricsProvider.normalized(media.album) ? 2 : 0)
            found.append(document)
        }
        return LyricsProvider.best(found)
    }
}
