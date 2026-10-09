import Foundation

/// Optional account-connected Apple Music lyric source. All requests go from
/// the user's Mac directly to Apple; the account token stays in Keychain.
actor AppleMusicOnlineLyrics {
    static let shared = AppleMusicOnlineLyrics()
    enum LookupError: Error { case expired, tokenUnavailable, accountUnavailable }

    private var developerToken: String?
    private var developerTokenExpiresAt: Date?
    private var failedTokenFetchAt: Date?

    func lookup(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        guard let account = AppleMusicCredential.read() else { return nil }
        if let expiry = account.expiresAt, expiry <= Date() { throw LookupError.expired }
        guard let developerToken = await validDeveloperToken() else { throw LookupError.tokenUnavailable }
        let storefront: String
        if account.storefront.isEmpty {
            let (body, status) = try await api(path: "v1/me/storefront", developerToken: developerToken,
                                               userToken: account.token)
            if status == 401 || status == 403 {
                let (_, probeStatus) = try await api(path: "v1/catalog/us/search?types=songs&limit=1&term=a",
                                                     developerToken: developerToken)
                if probeStatus == 401 || probeStatus == 403 {
                    self.developerToken = nil
                    self.developerTokenExpiresAt = nil
                    throw LookupError.tokenUnavailable
                }
                throw LookupError.expired
            }
            guard status == 200,
                  let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let first = (root["data"] as? [[String: Any]])?.first,
                  let id = first["id"] as? String, !id.isEmpty else { throw LookupError.accountUnavailable }
            storefront = id
        } else { storefront = account.storefront }
        let escapedStorefront = storefront.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? storefront
        var items: [[String: Any]] = []
        var hasMatch = false
        var searchSucceeded = false
        let regions = [storefront] + ["us", "cn", "jp", "kr"].filter { $0 != storefront }
        for region in regions {
            for term in ["\(media.artist) \(media.title)", media.title] {
                try Task.checkCancellation()
                do {
                    let results = try await searchSongs(region: region, term: term, developerToken: developerToken)
                    searchSucceeded = true
                    items.append(contentsOf: results)
                } catch let problem as LookupError { throw problem }
                catch { continue }
                hasMatch = items.contains(where: { item in
                    let fields = item["attributes"] as? [String: Any] ?? [:]
                    return LyricsProvider.matches(
                        title: fields["name"] as? String ?? "",
                        artist: fields["artistName"] as? String ?? "",
                        duration: ((fields["durationInMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                        media: media)
                })
                if hasMatch { break }
            }
            if hasMatch { break }
        }
        guard searchSucceeded else { throw URLError(.cannotConnectToHost) }
        let matching = items.compactMap { item -> (String, String, String, String, Double, Bool, Double)? in
            guard let identifier = item["id"] as? String,
                  let fields = item["attributes"] as? [String: Any] else { return nil }
            let title = fields["name"] as? String ?? ""
            let artist = fields["artistName"] as? String ?? ""
            let album = fields["albumName"] as? String ?? ""
            let duration = ((fields["durationInMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
            guard LyricsProvider.matches(title: title, artist: artist, duration: duration, media: media),
                  fields["hasLyrics"] as? Bool != false else { return nil }
            let wordTiming = fields["hasTimeSyncedLyrics"] as? Bool ?? false
            let albumBonus = LyricsProvider.normalized(album) == LyricsProvider.normalized(media.album) ? 2.0 : 0
            let lengthBonus = duration > 0 && media.duration > 0 ? max(0, 1 - abs(duration - media.duration) / 5) : 0
            return (identifier, title, artist, album, duration, wordTiming, 7 + albumBonus + lengthBonus)
        }.sorted { ($0.5 ? 1 : 0, $0.6) > ($1.5 ? 1 : 0, $1.6) }
        var found: [LyricsDocument] = []
        for (identifier, title, artist, album, duration, _, rank) in matching.prefix(3) {
            try Task.checkCancellation()
            for kind in ["syllable-lyrics", "lyrics"] {
                let path = "v1/catalog/\(escapedStorefront)/songs/\(identifier)/\(kind)?extend=ttmlLocalizations"
                let (body, status) = try await api(path: path, developerToken: developerToken,
                                                   userToken: account.token)
                if status == 401 {
                    let (_, probeStatus) = try await api(path: "v1/catalog/us/search?types=songs&limit=1&term=a",
                                                         developerToken: developerToken)
                    if probeStatus == 401 || probeStatus == 403 {
                        self.developerToken = nil
                        self.developerTokenExpiresAt = nil
                        throw LookupError.tokenUnavailable
                    }
                    throw LookupError.expired
                }
                if status == 403 { throw LookupError.expired }
                if status == 404 { continue }
                guard status == 200 else { throw URLError(.badServerResponse) }
                guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let first = (root["data"] as? [[String: Any]])?.first,
                      let attributes = first["attributes"] as? [String: Any],
                      let ttml = attributes["ttmlLocalizations"] as? String ?? attributes["ttml"] as? String,
                      var document = AppleMusicLocalLyrics.parseTTML(ttml, duration: duration) else { continue }
                document.source = "Apple Music 在线歌词"
                document.trackIdentifier = "applemusic:\(identifier)"
                document.matchedTitle = title; document.matchedArtist = artist
                document.matchedAlbum = album; document.matchedDuration = duration
                document.matchScore = rank; document.parserRevision = 3
                // Catalog search verifies metadata, but Music.app has not
                // provided a matching catalog ID for this track.
                document.isNativeMatch = false
                found.append(document)
                break
            }
            if found.contains(where: \.hasWordTiming) { break }
        }
        return LyricsProvider.best(found)
    }

    private func searchSongs(region: String, term: String, developerToken: String) async throws -> [[String: Any]] {
        var search = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(region)/search")!
        search.queryItems = [
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "term", value: term)
        ]
        let (data, status) = try await api(url: search.url!, developerToken: developerToken)
        if status == 401 || status == 403 {
            self.developerToken = nil
            self.developerTokenExpiresAt = nil
            throw LookupError.tokenUnavailable
        }
        guard status == 200 else { throw URLError(.badServerResponse) }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let songs = (root?["results"] as? [String: Any])?["songs"] as? [String: Any]
        return songs?["data"] as? [[String: Any]] ?? []
    }

    private func api(path: String, developerToken: String, userToken: String? = nil) async throws -> (Data, Int) {
        try await api(url: URL(string: "https://amp-api.music.apple.com/" + path)!,
                      developerToken: developerToken, userToken: userToken)
    }

    private func api(url: URL, developerToken: String, userToken: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 9)
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let userToken { request.setValue(userToken, forHTTPHeaderField: "Media-User-Token") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, data.count < 8_000_000 else {
            throw URLError(.badServerResponse)
        }
        return (data, status)
    }

    private func validDeveloperToken() async -> String? {
        if let developerToken, let expiry = developerTokenExpiresAt,
           expiry.timeIntervalSinceNow > 86_400 { return developerToken }
        if let failedTokenFetchAt, Date().timeIntervalSince(failedTokenFetchAt) < 1_800 { return nil }
        guard let home = await webText(URL(string: "https://music.apple.com")!, limit: 2_000_000) else {
            failedTokenFetchAt = Date(); return nil
        }
        let pattern = try! NSRegularExpression(pattern: #"/assets/[A-Za-z0-9._~-]+\.js"#)
        let ns = home as NSString
        let matches = pattern.matches(in: home, range: NSRange(location: 0, length: ns.length))
        let assets = Array(Set(matches.map { ns.substring(with: $0.range) }))
            .sorted { ($0.contains("/index~") ? 0 : 1, $0) < ($1.contains("/index~") ? 0 : 1, $1) }
        let jwtPattern = try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{50,}\.[A-Za-z0-9_-]{20,}"#)
        var tried = Set<String>()
        for asset in assets.prefix(4) {
            guard let js = await webText(URL(string: "https://music.apple.com\(asset)")!, limit: 12_000_000) else { continue }
            let body = js as NSString
            for match in jwtPattern.matches(in: js, range: NSRange(location: 0, length: body.length)) {
                let token = body.substring(with: match.range)
                guard tried.insert(token).inserted,
                      let expiry = expiryOfJWT(token), expiry.timeIntervalSinceNow > 86_400 else { continue }
                let result = try? await api(path: "v1/catalog/us/search?types=songs&limit=1&term=a",
                                            developerToken: token)
                if result?.1 == 200 {
                    developerToken = token
                    developerTokenExpiresAt = expiry
                    failedTokenFetchAt = nil
                    return token
                }
            }
        }
        failedTokenFetchAt = Date()
        return nil
    }

    private func webText(_ url: URL, limit: Int) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < limit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func expiryOfJWT(_ token: String) -> Date? {
        let components = token.split(separator: ".")
        guard components.count == 3 else { return nil }
        let payload = String(components[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = object["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }
}
