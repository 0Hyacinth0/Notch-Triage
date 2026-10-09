import Foundation

/// Reads only recent lyric responses that Music.app has already cached for its
/// own playback. A miss is normal: the cache is undocumented and short lived.
enum AppleMusicLocalLyrics {
    static func lookup(_ media: MediaSnapshot) -> LyricsDocument? {
        guard media.bundleIdentifier?.lowercased() == "com.apple.music" else { return nil }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.apple.Music/fsCachedData")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let recent = files.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate,
                  Date().timeIntervalSince(date) < 172_800,
                  let bytes = values.fileSize, bytes > 0, bytes < 4_000_000 else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }.prefix(250)

        var best: LyricsDocument?
        var bytesRead = 0
        for (url, _) in recent {
            guard let data = try? Data(contentsOf: url),
                  bytesRead + data.count <= 32_000_000 else { continue }
            bytesRead += data.count
            guard data.range(of: Data("ttmlLocalizations".utf8)) != nil,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songs = root["data"] as? [[String: Any]] else { continue }
            for song in songs {
                guard let attributes = song["attributes"] as? [String: Any],
                      let title = attributes["name"] as? String,
                      let artist = attributes["artistName"] as? String else { continue }
                let album = attributes["albumName"] as? String ?? ""
                let duration = ((attributes["durationInMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
                guard LyricsProvider.matches(title: title, artist: artist, duration: duration, media: media),
                      let relationships = song["relationships"] as? [String: Any] else { continue }
                for kind in ["syllable-lyrics", "lyrics"] {
                    guard let relationship = relationships[kind] as? [String: Any],
                          let entries = relationship["data"] as? [[String: Any]] else { continue }
                    for entry in entries {
                        guard let body = entry["attributes"] as? [String: Any],
                              let ttml = body["ttmlLocalizations"] as? String,
                              var document = parseTTML(ttml, duration: duration) else { continue }
                        document.source = "Apple Music"
                        document.trackIdentifier = (song["id"] as? String).map { "applemusic:\($0)" }
                        document.matchedTitle = title
                        document.matchedArtist = artist
                        document.matchedAlbum = album
                        document.matchedDuration = duration
                        let albumAgrees = media.album.isEmpty || album.isEmpty
                            || LyricsProvider.normalized(album) == LyricsProvider.normalized(media.album)
                        let durationAgrees = media.duration <= 0 || duration <= 0
                            || abs(media.duration - duration) < 4
                        document.isNativeMatch = albumAgrees && durationAgrees
                        let albumBonus = !media.album.isEmpty && LyricsProvider.normalized(album) == LyricsProvider.normalized(media.album) ? 2.0 : 0
                        let durationBonus = duration > 0 && media.duration > 0 ? max(0, 1 - abs(duration - media.duration) / 5) : 0
                        document.matchScore = 7 + albumBonus + durationBonus
                        if LyricsProvider.isBetter(document, than: best) { best = document }
                    }
                }
            }
        }
        return best
    }

    static func parseTTML(_ text: String, duration: Double) -> LyricsDocument? {
        guard let xml = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever]),
              let paragraphs = try? xml.nodes(forXPath: "//*[local-name()='p']") else { return nil }
        func keyedText(_ path: String, requiredType: String?) -> [String: String] {
            var values: [String: String] = [:]
            for case let container as XMLElement in (try? xml.nodes(forXPath: path)) ?? [] {
                if let requiredType,
                   container.attribute(forName: "type")?.stringValue != requiredType { continue }
                for case let item as XMLElement in container.children ?? [] where item.localName == "text" || item.name == "text" {
                    guard let key = item.attribute(forName: "for")?.stringValue,
                          let value = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else { continue }
                    values[key] = value
                }
                if !values.isEmpty { break }
            }
            return values
        }
        let translations = keyedText("//*[local-name()='translation']", requiredType: "subtitle")
        let romanizations = keyedText("//*[local-name()='transliteration']", requiredType: nil)
        var lines: [LyricLine] = []
        for case let paragraph as XMLElement in paragraphs {
            guard let start = seconds(paragraph.attribute(forName: "begin")?.stringValue) else { continue }
            let end = seconds(paragraph.attribute(forName: "end")?.stringValue) ?? start
            var words: [LyricWord] = []
            var leadingText = ""
            for child in paragraph.children ?? [] {
                if let span = child as? XMLElement,
                   span.localName == "span" || child.name == "span",
                   let wordStart = seconds(span.attribute(forName: "begin")?.stringValue),
                   let wordEnd = seconds(span.attribute(forName: "end")?.stringValue),
                   let value = span.stringValue, !value.isEmpty {
                    words.append(LyricWord(text: leadingText + value, start: wordStart, end: wordEnd))
                    leadingText = ""
                } else if child.kind == .text, let value = child.stringValue {
                    if words.isEmpty { leadingText += value }
                    else { words[words.count - 1].text += value }
                }
            }
            let body = paragraph.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !body.isEmpty else { continue }
            if !words.isEmpty, !leadingText.isEmpty { words[words.count - 1].text += leadingText }
            let renderedText = words.isEmpty ? body : words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            var line = LyricLine(start: start, end: end, text: renderedText, words: words)
            line.speaker = paragraph.attribute(forName: "ttm:agent")?.stringValue
            if let key = paragraph.attribute(forName: "itunes:key")?.stringValue {
                line.translation = translations[key]
                line.romanization = romanizations[key]
            }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        lines.sort { $0.start < $1.start }
        for index in lines.indices where lines[index].end <= lines[index].start {
            lines[index].end = index + 1 < lines.count ? lines[index + 1].start : max(duration, lines[index].start + 5)
        }
        return LyricsDocument(lines: lines, source: "Apple Music", parserRevision: 2)
    }

    private static func seconds(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        let components = value.replacingOccurrences(of: "s", with: "").split(separator: ":")
        var result = 0.0
        for component in components {
            guard let part = Double(component) else { return nil }
            result = result * 60 + part
        }
        return result
    }
}
