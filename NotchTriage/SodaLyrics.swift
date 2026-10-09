import Foundation

/// Searches Soda Music's web catalogue and reads its timed SEO lyric payload.
enum SodaLyrics {
    private static func json(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return root
    }

    static func lookup(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        var search = URLComponents(string: "https://api.qishui.com/luna/search/track")!
        search.queryItems = [
            URLQueryItem(name: "q", value: "\(media.artist) \(media.title)"),
            URLQueryItem(name: "cursor", value: "0"),
            URLQueryItem(name: "count", value: "20"),
            URLQueryItem(name: "aid", value: "386088")
        ]
        let root = try await json(search.url!)
        let groups = root["result_groups"] as? [[String: Any]] ?? []
        let tracks = groups.flatMap { ($0["data"] as? [[String: Any]] ?? []) }
            .compactMap { ($0["entity"] as? [String: Any])?["track"] as? [String: Any] }
        let candidates = tracks.compactMap { track -> (String, String, String, String, Double)? in
            let identifier = track["id"] as? String ?? ""
            let title = track["name"] as? String ?? ""
            let artists = (track["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let artist = artists.joined(separator: " / ")
            let album = (track["album"] as? [String: Any])?["name"] as? String ?? ""
            let duration = ((track["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
            guard !identifier.isEmpty,
                  LyricsProvider.matches(title: title, artist: artist, duration: duration, media: media) else { return nil }
            return (identifier, title, artist, album, duration)
        }.sorted { left, right in
            let leftAlbum = LyricsProvider.normalized(left.3) == LyricsProvider.normalized(media.album)
            let rightAlbum = LyricsProvider.normalized(right.3) == LyricsProvider.normalized(media.album)
            if leftAlbum != rightAlbum { return leftAlbum }
            return abs(left.4 - media.duration) < abs(right.4 - media.duration)
        }
        var found: [LyricsDocument] = []
        var attempts = 0, failures = 0
        for (identifier, title, artist, album, duration) in candidates.prefix(3) {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://beta-luna.douyin.com/luna/h5/seo_track")!
            url.queryItems = [URLQueryItem(name: "track_id", value: identifier),
                              URLQueryItem(name: "device_platform", value: "web")]
            attempts += 1
            let response: [String: Any]
            do { response = try await json(url.url!) }
            catch { failures += 1; continue }
            let seo = response["seo_track"] as? [String: Any] ?? [:]
            let authoritative = seo["track"] as? [String: Any] ?? [:]
            guard authoritative["id"] as? String == identifier else { continue }
            let verifiedTitle = authoritative["name"] as? String ?? title
            let verifiedArtist = (authoritative["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }.joined(separator: " / ")
            let verifiedDuration = ((authoritative["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
            guard LyricsProvider.matches(title: verifiedTitle, artist: verifiedArtist,
                                         duration: verifiedDuration, media: media) else { continue }
            let lyric = response["lyric"] as? [String: Any] ?? seo["lyric"] as? [String: Any] ?? [:]
            guard let raw = lyric["content"] as? String else { continue }
            guard var document = LyricsKRC.parse(raw, duration: media.duration)
                ?? LyricsParser.parse(raw, source: "汽水音乐", duration: media.duration) else { continue }
            document.source = "汽水音乐"
            if let translations = lyric["translations"] as? [String: String],
               let translated = translations["cn"] {
                LyricsParser.attach(translated, to: &document, as: .translation)
            }
            document.trackIdentifier = "soda:\(identifier)"
            document.matchedTitle = title; document.matchedArtist = artist
            document.matchedAlbum = album; document.matchedDuration = duration
            document.matchScore = 7 + (LyricsProvider.normalized(album) == LyricsProvider.normalized(media.album) ? 2 : 0)
            found.append(document)
        }
        if found.isEmpty, attempts > 0, failures == attempts { throw URLError(.cannotConnectToHost) }
        return LyricsProvider.best(found)
    }
}
