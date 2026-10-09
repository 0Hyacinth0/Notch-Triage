import Foundation

/// Retrieves curated TTML by an identifier verified against the local player.
/// A name-only guess is never sent to the ID endpoint.
enum AMLLLyrics {
    static func lookup(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        let bundle = media.bundleIdentifier?.lowercased() ?? ""
        var direct: (String, String)?
        if bundle.contains("qqmusic"), let track = await LocalPlayerTrackCatalog.shared.qq(media) {
            direct = ("qqMusicId", track.identifier)
        } else if bundle.contains("netease"), let track = await LocalPlayerTrackCatalog.shared.netease(media) {
            direct = ("ncmMusicId", track.identifier)
        }
        if let direct,
           let document = try await get([URLQueryItem(name: direct.0, value: direct.1)],
                                        media: media, native: true) { return document }

        var search = URLComponents(string: "https://api.amll.dev/v1/lyrics/search")!
        search.queryItems = [URLQueryItem(name: "musicName", value: media.title),
                             URLQueryItem(name: "artistName", value: media.artist),
                             URLQueryItem(name: "pageSize", value: "20")]
        let (data, response) = try await URLSession.shared.data(from: search.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wrapper = root["data"] as? [String: Any],
              let rows = wrapper["items"] as? [[String: Any]] else { return nil }
        let matches = rows.compactMap { row -> (String, String, String, String)? in
            let title = (row["musicNames"] as? [String] ?? []).first(where: {
                LyricsProvider.normalized($0) == LyricsProvider.normalized(media.title)
            }) ?? ""
            let artist = (row["artistNames"] as? [String] ?? []).first(where: {
                LyricsProvider.normalized($0) == LyricsProvider.normalized(media.artist)
            }) ?? (row["artistNames"] as? [String] ?? []).joined(separator: " / ")
            let album = (row["albumNames"] as? [String] ?? []).first ?? ""
            let identifier = (row["id"] as? NSNumber)?.stringValue ?? ""
            guard !identifier.isEmpty,
                  LyricsProvider.matches(title: title, artist: artist, duration: 0, media: media) else { return nil }
            return (identifier, title, artist, album)
        }.sorted { left, right in
            LyricsProvider.normalized(left.3) == LyricsProvider.normalized(media.album)
                && LyricsProvider.normalized(right.3) != LyricsProvider.normalized(media.album)
        }
        var found: [LyricsDocument] = []
        for (id, _, _, _) in matches.prefix(3) {
            try Task.checkCancellation()
            if let document = try await get([URLQueryItem(name: "id", value: id)], media: media, native: false) {
                found.append(document)
            }
        }
        return LyricsProvider.best(found)
    }

    private static func get(_ parameters: [URLQueryItem], media: MediaSnapshot,
                            native: Bool) async throws -> LyricsDocument? {
        var components = URLComponents(string: "https://api.amll.dev/v1/lyrics/get")!
        components.queryItems = parameters
        var request = URLRequest(url: components.url!, timeoutInterval: 8)
        request.setValue("NotchTriage/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        if status == 404 { return nil }
        guard status == 200, data.count < 4_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any],
              let ttml = body["lyrics"] as? String,
              var document = AppleMusicLocalLyrics.parseTTML(ttml, duration: media.duration),
              document.hasWordTiming else { return nil }
        let titles = body["musicNames"] as? [String] ?? []
        let artists = body["artistNames"] as? [String] ?? []
        let title = titles.first(where: { LyricsProvider.normalized($0) == LyricsProvider.normalized(media.title) }) ?? titles.first ?? ""
        let artist = artists.first(where: { LyricsProvider.normalized($0) == LyricsProvider.normalized(media.artist) }) ?? artists.joined(separator: " / ")
        guard LyricsProvider.matches(title: title, artist: artist, duration: 0, media: media) else { return nil }
        document.source = "AMLL 逐字词库"
        document.trackIdentifier = "amll:\((body["id"] as? NSNumber)?.stringValue ?? UUID().uuidString)"
        document.matchedTitle = title; document.matchedArtist = artist
        document.matchedAlbum = (body["albumNames"] as? [String])?.first ?? ""
        document.matchedDuration = media.duration
        document.matchScore = 9 + (LyricsProvider.normalized(document.matchedAlbum ?? "") == LyricsProvider.normalized(media.album) ? 2 : 0)
        document.isNativeMatch = native
        document.parserRevision = 3
        return document
    }
}
