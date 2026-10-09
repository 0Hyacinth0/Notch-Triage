import Foundation

/// Uses lyrics already downloaded by Kugou for the currently playing track.
/// A cache miss is expected and lets the other enabled sources continue.
enum KugouLocalLyrics {
    static func lookup(_ media: MediaSnapshot) -> LyricsDocument? {
        guard media.bundleIdentifier?.lowercased().contains("kugou") == true else { return nil }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.kugou.mac.Music/Data/Library/Application Support/com.kugou.mac.Music/Caches/kgLyric")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let recent = files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension.lowercased() == "krc",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate,
                  Date().timeIntervalSince(modified) < 172_800,
                  let size = values.fileSize, size > 4, size < 1_000_000 else { return nil }
            return (url, modified)
        }.sorted { $0.1 > $1.1 }.prefix(160)
        var best: LyricsDocument?
        for (url, modified) in recent {
            guard let data = try? Data(contentsOf: url),
                  let text = LyricsKRC.decode(data) else { continue }
            let meta = LyricsKRC.metadata(text)
            // Files without these tags are often generated speech subtitles.
            guard !meta.title.isEmpty, !meta.artist.isEmpty,
                  LyricsProvider.matches(title: meta.title, artist: meta.artist,
                                         duration: 0, media: media),
                  var document = LyricsKRC.parse(text, duration: media.duration) else { continue }
            let albumAgrees = media.album.isEmpty || meta.album.isEmpty
                || LyricsProvider.normalized(media.album) == LyricsProvider.normalized(meta.album)
            document.isNativeMatch = albumAgrees && Date().timeIntervalSince(modified) < 300
            document.trackIdentifier = !meta.hash.isEmpty ? "kugou:\(meta.hash)" : "kugoufile:\(url.lastPathComponent)"
            document.matchedTitle = meta.title; document.matchedArtist = meta.artist
            document.matchedAlbum = meta.album
            document.matchScore = 7 + (albumAgrees && !meta.album.isEmpty ? 2 : 0)
            if LyricsProvider.isBetter(document, than: best) { best = document }
        }
        return best
    }
}
