import Foundation
import SQLite3

/// A read-only hint from a player's own catalog. It identifies the recording;
/// lyric text is still fetched from that player's service.
actor LocalPlayerTrackCatalog {
    static let shared = LocalPlayerTrackCatalog()

    struct Track: Sendable {
        let identifier: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }

    private struct Entry {
        let modified: Date?
        let walModified: Date?
        let loadedAt: Date
        let tracks: [Track]
    }
    private var entries: [String: Entry] = [:]

    private func tracks(at url: URL, query: String, read: (OpaquePointer) -> Track?) -> [Track] {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let walModified = try? walURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let entry = entries[url.path], entry.modified == modified,
           entry.walModified == walModified, Date().timeIntervalSince(entry.loadedAt) < 60 {
            return entry.tracks
        }
        let loaded = Self.database(at: url, query: query, read: read)
        entries[url.path] = Entry(modified: modified, walModified: walModified,
                                  loadedAt: Date(), tracks: loaded)
        return loaded
    }

    private static func database<T>(at url: URL, query: String, read: (OpaquePointer) -> T?) -> [T] {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else { if database != nil { sqlite3_close(database) }; return [] }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { if statement != nil { sqlite3_finalize(statement) }; return [] }
        defer { sqlite3_finalize(statement) }
        var records: [T] = []
        while records.count < 20_000, sqlite3_step(statement) == SQLITE_ROW {
            if let record = read(statement) { records.append(record) }
        }
        return records
    }

    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }

    func qq(_ media: MediaSnapshot) -> Track? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/qqmusic.sqlite")
        let records = tracks(at: url, query: "SELECT K_SONG_RESERVE1, name, singer, album, K_SONG_RESERVE12 FROM SONGS WHERE K_SONG_RESERVE1 <> '' AND name <> '' LIMIT 20000") { row in
            let mid = Self.string(row, 0)
            guard !mid.isEmpty else { return nil }
            let rawDuration = sqlite3_column_double(row, 4)
            return Track(identifier: mid, title: Self.string(row, 1), artist: Self.string(row, 2),
                         album: Self.string(row, 3), duration: rawDuration > 1000 ? rawDuration / 1000 : rawDuration)
        }
        return Self.preferred(records, for: media)
    }

    func netease(_ media: MediaSnapshot) -> Track? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.netease.163music/Data/Documents/storage/sqlite_storage.sqlite3")
        let records = tracks(at: url, query: "SELECT jsonStr FROM dbTrack WHERE jsonStr <> '' LIMIT 20000") { row in
            guard let data = Self.string(row, 0).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["name"] as? String else { return nil }
            let id = (object["id"] as? String) ?? (object["id"] as? NSNumber)?.stringValue ?? ""
            guard !id.isEmpty else { return nil }
            let artists = (object["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }.joined(separator: " / ")
            let album = (object["album"] as? [String: Any])?["name"] as? String ?? ""
            let duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
            return Track(identifier: id, title: title, artist: artists, album: album,
                         duration: duration > 1000 ? duration / 1000 : duration)
        }
        return Self.preferred(records, for: media)
    }

    private static func preferred(_ records: [Track], for media: MediaSnapshot) -> Track? {
        records.filter { LyricsProvider.matches(title: $0.title, artist: $0.artist, duration: $0.duration, media: media) }
            .max { left, right in quality(left, media) < quality(right, media) }
    }

    private static func quality(_ track: Track, _ media: MediaSnapshot) -> Double {
        let album = !media.album.isEmpty && LyricsProvider.normalized(track.album) == LyricsProvider.normalized(media.album) ? 2.0 : 0
        let duration = track.duration > 0 && media.duration > 0 ? max(0, 1 - abs(track.duration - media.duration) / 5) : 0
        return album + duration
    }
}
