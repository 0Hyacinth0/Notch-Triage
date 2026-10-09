import Foundation

/// Reads the LyricFind-labelled, timed lyric feed exposed by YouTube Music.
/// The label check matters: the same transport also serves Musixmatch lyrics.
enum LyricFindLyrics {
    private static func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private static func list(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    private static func string(_ value: Any?) -> String { value as? String ?? "" }

    private static func visit(_ node: Any, _ block: ([String: Any]) -> Void) {
        if let object = node as? [String: Any] {
            block(object)
            for child in object.values { visit(child, block) }
        } else if let array = node as? [Any] {
            for child in array { visit(child, block) }
        }
    }

    private static func context(mobile: Bool) -> [String: Any] {
        let client: [String: Any] = mobile
            ? ["clientName": "ANDROID_MUSIC", "clientVersion": "7.21.50"]
            : ["clientName": "WEB_REMIX", "clientVersion": "1.\(DateFormatter.youtubeVersion.string(from: Date())).01.00"]
        return ["context": ["client": client, "user": [:]]]
    }

    private static func post(_ endpoint: String, body: [String: Any]) async throws -> Any {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var lastError: Error = URLError(.cannotConnectToHost)
        for host in ["https://music.youtube.com", "https://youtubei.googleapis.com", "https://www.youtube.com"] {
            try Task.checkCancellation()
            guard let url = URL(string: "\(host)/youtubei/v1/\(endpoint)?prettyPrint=false&alt=json") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 6)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      !data.isEmpty, data.count < 4_000_000 else { throw URLError(.badServerResponse) }
                return try JSONSerialization.jsonObject(with: data)
            } catch { lastError = error }
        }
        throw lastError
    }

    private static func runs(_ value: Any?) -> String {
        list(object(value)["runs"]).map { string(object($0)["text"]) }.joined()
    }

    private static func duration(_ value: String) -> Double {
        let pieces = value.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == 2 || pieces.count == 3 else { return 0 }
        return pieces.reduce(0) { $0 * 60 + $1 }
    }

    private struct Hit {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }

    static func lookup(_ media: MediaSnapshot) async throws -> LyricsDocument? {
        var search = context(mobile: false)
        search["query"] = "\(media.artist) \(media.title)"
        search["params"] = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        let response = try await post("search", body: search)
        var hits: [Hit] = []
        visit(response) { node in
            guard let row = node["musicResponsiveListItemRenderer"] as? [String: Any] else { return }
            let columns = list(row["flexColumns"]).map { column in
                runs(object(object(column)["musicResponsiveListItemFlexColumnRenderer"])["text"])
            }
            guard columns.count >= 2 else { return }
            let title = columns[0]
            let parts = columns[1].components(separatedBy: " • ")
            guard parts.count >= 2 else { return }
            let artist = parts[0]
            let seconds = duration(parts.last ?? "")
            guard LyricsProvider.matches(title: title, artist: artist, duration: seconds, media: media) else { return }
            let overlay = object(row["overlay"])
            let thumbnail = object(overlay["musicItemThumbnailOverlayRenderer"])
            let content = object(thumbnail["content"])
            let button = object(content["musicPlayButtonRenderer"])
            let nav = object(button["playNavigationEndpoint"])
            let watch = object(nav["watchEndpoint"])
            let id = string(watch["videoId"])
            guard !id.isEmpty else { return }
            hits.append(Hit(id: id, title: title, artist: artist,
                            album: parts.dropFirst().dropLast().joined(separator: " • "), duration: seconds))
        }
        for hit in hits.prefix(2) {
            try Task.checkCancellation()
            var next = context(mobile: false)
            next["videoId"] = hit.id
            next["isAudioOnly"] = true
            let player = try await post("next", body: next)
            var browseID = ""
            visit(player) { node in
                guard browseID.isEmpty, let endpoint = node["browseEndpoint"] as? [String: Any] else { return }
                let config = object(object(endpoint["browseEndpointContextSupportedConfigs"])["browseEndpointContextMusicConfig"])
                if string(config["pageType"]) == "MUSIC_PAGE_TYPE_TRACK_LYRICS" {
                    browseID = string(endpoint["browseId"])
                }
            }
            guard !browseID.isEmpty else { continue }
            var browse = context(mobile: true)
            browse["browseId"] = browseID
            let lyrics = try await post("browse", body: browse)
            var timed: [[String: Any]] = []
            var source = ""
            visit(lyrics) { node in
                guard timed.isEmpty, let lines = node["timedLyricsData"] as? [[String: Any]],
                      !lines.isEmpty else { return }
                timed = lines
                source = string(node["sourceMessage"])
            }
            guard source.localizedCaseInsensitiveContains("LyricFind"), !timed.isEmpty else { continue }
            var lrc: [String] = []
            for row in timed {
                let cue = object(row["cueRange"])
                let millis = Double(string(cue["startTimeMilliseconds"]))
                    ?? (cue["startTimeMilliseconds"] as? NSNumber)?.doubleValue
                guard let millis, millis >= 0 else { continue }
                let seconds = millis / 1000
                lrc.append(String(format: "[%02d:%05.2f]%@", Int(seconds / 60), seconds.truncatingRemainder(dividingBy: 60), string(row["lyricLine"])))
            }
            guard var document = LyricsParser.parse(lrc.joined(separator: "\n"), source: "LyricFind", duration: media.duration) else { continue }
            document.trackIdentifier = "lyricfind:\(hit.id)"
            document.matchedTitle = hit.title
            document.matchedArtist = hit.artist
            document.matchedAlbum = hit.album
            document.matchedDuration = hit.duration
            document.matchScore = 6 + (LyricsProvider.normalized(hit.album) == LyricsProvider.normalized(media.album) ? 2 : 0)
            return document
        }
        return nil
    }
}

private extension DateFormatter {
    static let youtubeVersion: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
