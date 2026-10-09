import Compression
import Foundation

/// Kuwo's optional client lyric track. The web lyric remains the fallback.
enum KuwoLRCX {
    static func fetch(musicID: String, duration: Double) async -> LyricsDocument? {
        guard let text = await download(musicID: musicID, mode: "1") else { return nil }
        return parse(text, duration: duration)
    }

    static func fetchLine(musicID: String, duration: Double) async -> LyricsDocument? {
        guard let text = await download(musicID: musicID, mode: "0") else { return nil }
        return LyricsParser.parse(text, source: "酷我音乐", duration: duration)
    }

    private static func download(musicID: String, mode: String) async -> String? {
        guard !musicID.isEmpty else { return nil }
        var components = URLComponents(string: "https://mlyric.kuwo.cn/mobi.s")!
        components.queryItems = [
            URLQueryItem(name: "f", value: "web"),
            URLQueryItem(name: "type", value: "lyric"),
            URLQueryItem(name: "lrcx", value: mode),
            URLQueryItem(name: "encode", value: "utf8"),
            URLQueryItem(name: "rid", value: musicID)
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 7)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 524_288,
              let text = decode(data) else { return nil }
        return text
    }

    private static func decode(_ data: Data) -> String? {
        let marker = Data([13, 10, 13, 10])
        guard data.prefix(10).elementsEqual(Data("tp=content".utf8)),
              let divider = data.range(of: marker) else { return nil }
        let compressed = [UInt8](data[divider.upperBound...])
        var output = [UInt8](repeating: 0, count: 2_097_152)
        let count = output.withUnsafeMutableBufferPointer { destination in
            compressed.withUnsafeBufferPointer { source in
                compression_decode_buffer(destination.baseAddress!, destination.count,
                                          source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0, count < output.count,
              let base64 = String(bytes: output.prefix(count), encoding: .utf8),
              let cipher = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              cipher.count < 2_097_152 else { return nil }
        let key = Array("yeelion".utf8)
        let plain = cipher.enumerated().map { index, byte in byte ^ key[index % key.count] }
        return String(bytes: plain, encoding: .utf8)
    }

    private static func parse(_ text: String, duration: Double) -> LyricsDocument? {
        let header = try! NSRegularExpression(pattern: #"^\[kuwo:([0-7]+)\]"#)
        let linePattern = try! NSRegularExpression(pattern: #"^\[(\d{1,3}):(\d{2})\.(\d{1,3})\](.*)$"#)
        let wordPattern = try! NSRegularExpression(pattern: #"<(-?\d+),(-?\d+)(?:,-?\d+)?>"#)
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var coefficients: (Int, Int)?
        for row in rows {
            let ns = row as NSString
            guard let match = header.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)),
                  let octal = Int(ns.substring(with: match.range(at: 1)), radix: 8) else { continue }
            let first = octal / 10, second = octal % 10
            if first > 0, second > 0 { coefficients = (first, second) }
            break
        }
        guard let (first, second) = coefficients else { return nil }
        var lines: [LyricLine] = []
        for row in rows {
            let ns = row as NSString
            guard let match = linePattern.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)),
                  let minutes = Int(ns.substring(with: match.range(at: 1))),
                  let seconds = Int(ns.substring(with: match.range(at: 2))) else { continue }
            let fraction = ns.substring(with: match.range(at: 3))
            let milliseconds = (Int(fraction) ?? 0) * Int(pow(10.0, Double(3 - fraction.count)))
            let start = Double((minutes * 60 + seconds) * 1000 + milliseconds) / 1000
            let body = ns.substring(with: match.range(at: 4)) as NSString
            let matches = wordPattern.matches(in: body as String, range: NSRange(location: 0, length: body.length))
            guard !matches.isEmpty else { continue }
            var words: [LyricWord] = []
            var allZero = true
            for index in matches.indices {
                let item = matches[index]
                let a = Int(body.substring(with: item.range(at: 1))) ?? 0
                let b = Int(body.substring(with: item.range(at: 2))) ?? 0
                if a != 0 || b != 0 { allZero = false }
                let textEnd = index + 1 < matches.count ? matches[index + 1].range.location : body.length
                let fragment = body.substring(with: NSRange(location: NSMaxRange(item.range),
                                                           length: max(0, textEnd - NSMaxRange(item.range))))
                let relativeStart = Double(abs(a + b)) / Double(2 * first * 1000)
                let relativeEnd = relativeStart + Double(abs(a - b)) / Double(2 * second * 1000)
                if let previous = words.indices.last, words[previous].end > start + relativeStart {
                    words[previous].end = max(words[previous].start, start + relativeStart)
                }
                words.append(LyricWord(text: fragment, start: start + relativeStart,
                                       end: max(start + relativeStart, start + relativeEnd)))
            }
            guard !allZero, words.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            lines.append(LyricLine(start: start, end: max(start + 0.02, words.map(\.end).max() ?? start),
                                   text: words.map(\.text).joined(), words: words))
        }
        guard !lines.isEmpty else { return nil }
        lines.sort { $0.start < $1.start }
        return LyricsDocument(lines: lines, source: "酷我音乐", parserRevision: 3)
    }
}
