import Foundation
import Compression

/// Decodes and parses Kugou's KRC container without changing the source file.
enum LyricsKRC {
    struct Metadata {
        let title: String
        let artist: String
        let album: String
        let hash: String
    }

    private static let cipher: [UInt8] = [
        0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
        0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69
    ]

    static func decode(_ data: Data) -> String? {
        guard data.count > 4, data.count < 1_000_000,
              data.prefix(4).elementsEqual(Data("krc1".utf8)) else { return nil }
        let encrypted = Array(data.dropFirst(4))
        let compressed = encrypted.enumerated().map { index, byte in byte ^ cipher[index % cipher.count] }
        var output = [UInt8](repeating: 0, count: 8_000_000)
        let size = output.withUnsafeMutableBufferPointer { destination in
            compressed.withUnsafeBufferPointer { source in
                compression_decode_buffer(destination.baseAddress!, destination.count,
                                          source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0, size < output.count else { return nil }
        return String(bytes: output.prefix(size), encoding: .utf8)
    }

    static func metadata(_ text: String) -> Metadata {
        var tags: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["), let separator = line.firstIndex(of: ":"), line.hasSuffix("]") else { continue }
            let name = String(line[line.index(after: line.startIndex)..<separator]).lowercased()
            let value = String(line[line.index(after: separator)..<line.index(before: line.endIndex)])
            tags[name] = value
        }
        return Metadata(title: tags["ti"] ?? "", artist: tags["ar"] ?? "",
                        album: tags["al"] ?? "", hash: tags["hash"] ?? "")
    }

    static func parse(_ input: String, duration: Double = 0) -> LyricsDocument? {
        let linePattern = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
        let wordPattern = try! NSRegularExpression(pattern: #"<(-?\d+),(\d+),\d+>([^<]*)"#)
        let rows = input.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var lines: [LyricLine] = []
        var language: String?
        for raw in rows {
            if raw.hasPrefix("[language:"), raw.hasSuffix("]") {
                language = String(raw.dropFirst(10).dropLast())
                continue
            }
            let string = raw as NSString
            guard let header = linePattern.firstMatch(in: raw, range: NSRange(location: 0, length: string.length)),
                  let startMilliseconds = Double(string.substring(with: header.range(at: 1))),
                  let lengthMilliseconds = Double(string.substring(with: header.range(at: 2))) else { continue }
            let body = string.substring(with: header.range(at: 3))
            let bodyString = body as NSString
            let start = startMilliseconds / 1000
            let words = wordPattern.matches(in: body, range: NSRange(location: 0, length: bodyString.length))
                .compactMap { match -> LyricWord? in
                    guard let offset = Double(bodyString.substring(with: match.range(at: 1))),
                          let length = Double(bodyString.substring(with: match.range(at: 2))) else { return nil }
                    let text = bodyString.substring(with: match.range(at: 3))
                    return LyricWord(text: text, start: max(0, start + offset / 1000),
                                     end: max(0, start + (offset + length) / 1000))
                }
            guard !words.isEmpty else { continue }
            let text = words.map(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append(LyricLine(start: start, end: start + lengthMilliseconds / 1000,
                                   text: text, words: words))
        }
        guard !lines.isEmpty else { return nil }
        if let language { attachLanguage(language, to: &lines) }
        lines.sort { $0.start < $1.start }
        if let last = lines.indices.last, lines[last].end <= lines[last].start {
            lines[last].end = max(duration, lines[last].start + 5)
        }
        return LyricsDocument(lines: lines, source: "酷狗音乐", parserRevision: 2)
    }

    private static func attachLanguage(_ encoded: String, to lines: inout [LyricLine]) {
        guard let bytes = Data(base64Encoded: encoded), bytes.count < 1_000_000,
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let tracks = root["content"] as? [[String: Any]] else { return }
        for track in tracks {
            guard let type = track["type"] as? Int,
                  let values = track["lyricContent"] as? [[String]], values.count == lines.count else { continue }
            let content = values.map { $0.joined().trimmingCharacters(in: .whitespacesAndNewlines) }
            if type == 0 {
                let whole = content.joined()
                let han = whole.unicodeScalars.filter { $0.value >= 0x3400 && $0.value <= 0x9fff }.count
                guard !whole.isEmpty, Double(han) / Double(max(1, whole.unicodeScalars.count)) <= 0.3 else { continue }
            }
            for index in lines.indices where !content[index].isEmpty && content[index] != "//" {
                if type == 1 { lines[index].translation = content[index] }
                if type == 0 { lines[index].romanization = content[index] }
            }
        }
    }
}
