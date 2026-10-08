import Foundation

struct LyricWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}
struct LyricLine: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var words: [LyricWord] = []
}
struct LyricsDocument: Codable, Equatable, Sendable {
    var lines: [LyricLine]
    var source: String
    var matchScore: Double? = nil
    var trackIdentifier: String? = nil
    var hasWordTiming: Bool { lines.contains { !$0.words.isEmpty } }
    func index(at time: Double) -> Int? { lines.lastIndex { $0.start <= time } }

    static let demo: LyricsDocument = {
        let phrases = ["让音乐轻轻流过夜色", "每一个字 都有自己的光", "Follow the rhythm of the night"]
        return LyricsDocument(lines: phrases.enumerated().map { index, text in
            let start = Double(index) * 5
            let units = text.contains("Follow") ? text.split(separator: " ").map { String($0) + " " } : text.map(String.init)
            let step = 4.4 / Double(units.count)
            return LyricLine(start: start, end: start + 5, text: units.joined(), words: units.enumerated().map {
                LyricWord(text: $0.element, start: start + Double($0.offset) * step, end: start + Double($0.offset + 1) * step)
            })
        }, source: "示意动画")
    }()
}

enum LyricsParser {
    // Enhanced LRC uses absolute word timestamps; YRC uses absolute millisecond starts.
    static func parse(_ input: String, source: String, duration: Double = 0) -> LyricsDocument? {
        let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        let enhanced = try! NSRegularExpression(pattern: #"<(\d+):(\d+(?:\.\d+)?)>([^<]*)"#)
        let yrcLine = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
        let kWord = try! NSRegularExpression(pattern: #"\(0,(\d+)\)([^\(]*)"#)
        let qWord = try! NSRegularExpression(pattern: #"([^\(]*?)\((\d+),(\d+)\)"#)
        let yrcWord = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^\(]*)"#)
        let offsetRE = try! NSRegularExpression(pattern: #"(?i)\[offset:([+-]?\d+)\]"#)
        let ns = input as NSString
        let offset = offsetRE.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)).flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var lines: [LyricLine] = []
        for raw in input.components(separatedBy: .newlines) {
            let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let str = raw as NSString
            let range = NSRange(location: 0, length: str.length)
            if let header = yrcLine.firstMatch(in: raw, range: range) {
                let start = (Double(str.substring(with: header.range(at: 1))) ?? 0) / 1000
                let end = start + (Double(str.substring(with: header.range(at: 2))) ?? 0) / 1000
                let yrcWords = yrcWord.matches(in: raw, range: range).map { match -> LyricWord in
                    let t = (Double(str.substring(with: match.range(at: 1))) ?? 0) / 1000
                    return LyricWord(text: str.substring(with: match.range(at: 3)), start: t + offset, end: t + offset + (Double(str.substring(with: match.range(at: 2))) ?? 0) / 1000)
                }
                var words = yrcWords
                if words.isEmpty {
                    let body = str.substring(from: NSMaxRange(header.range))
                    let fragment = body as NSString
                    let bodyRange = NSRange(location: 0, length: fragment.length)
                    var cursor = start + offset
                    words = kWord.matches(in: body, range: bodyRange).map { match in
                        let duration = (Double(fragment.substring(with: match.range(at: 1))) ?? 0) / 1000
                        let word = LyricWord(text: fragment.substring(with: match.range(at: 2)), start: cursor, end: cursor + duration)
                        cursor += duration
                        return word
                    }
                    if words.isEmpty {
                        words = qWord.matches(in: body, range: bodyRange).map { match in
                            let t = (Double(fragment.substring(with: match.range(at: 2))) ?? 0) / 1000 + offset
                            return LyricWord(text: fragment.substring(with: match.range(at: 1)), start: t, end: t + (Double(fragment.substring(with: match.range(at: 3))) ?? 0) / 1000)
                        }
                    }
                }
                if !words.isEmpty { lines.append(LyricLine(start: start + offset, end: end + offset, text: words.map(\.text).joined(), words: words)) }
                continue
            }
            let matches = stamp.matches(in: raw, range: range)
            guard let last = matches.last else { continue }
            let content = str.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            let wordString = content as NSString
            let marked = enhanced.matches(in: content, range: NSRange(location: 0, length: wordString.length))
            let starts = marked.map { (Double(wordString.substring(with: $0.range(at: 1))) ?? 0) * 60 + (Double(wordString.substring(with: $0.range(at: 2))) ?? 0) + offset }
            for match in matches {
                let start = (Double(str.substring(with: match.range(at: 1))) ?? 0) * 60 + (Double(str.substring(with: match.range(at: 2))) ?? 0) + offset
                // Repeated line stamps have no reliable repeated word timing.
                let words = matches.count == 1 ? marked.enumerated().compactMap { i, m -> LyricWord? in
                    let text = wordString.substring(with: m.range(at: 3))
                    guard !text.isEmpty else { return nil }
                    return LyricWord(text: text, start: starts[i], end: i + 1 < starts.count ? starts[i + 1] : starts[i])
                } : []
                lines.append(LyricLine(start: start, end: start, text: marked.isEmpty ? content : marked.map { wordString.substring(with: $0.range(at: 3)) }.joined(), words: words))
            }
        }
        lines.sort { $0.start < $1.start }
        for i in lines.indices {
            let next = i + 1 < lines.count ? lines[i + 1].start : max(duration, lines[i].start + 5)
            if lines[i].end <= lines[i].start { lines[i].end = next }
            for j in lines[i].words.indices where lines[i].words[j].end <= lines[i].words[j].start {
                lines[i].words[j].end = lines[i].end
            }
        }
        lines.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.isEmpty ? nil : LyricsDocument(lines: lines, source: source)
    }
}


enum LyricsChineseVariant: String, Codable, CaseIterable {
    case simplified, traditional, original
    var title: String {
        switch self { case .simplified: return "简体中文"; case .traditional: return "繁體中文"; case .original: return "保留歌词原文" }
    }
    func convert(_ text: String) -> String {
        switch self {
        case .original: return text
        case .simplified: return text.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false) ?? text
        case .traditional: return text.applyingTransform(StringTransform(rawValue: "Simplified-Traditional"), reverse: false) ?? text
        }
    }
}
extension LyricsDocument {
    func displaying(_ variant: LyricsChineseVariant) -> LyricsDocument {
        guard variant != .original else { return self }
        var result = self
        for i in result.lines.indices {
            if result.lines[i].words.isEmpty {
                result.lines[i].text = variant.convert(result.lines[i].text)
            } else {
                // Transform each timed fragment, then rebuild text from those same
                // fragments. This keeps glyph indices aligned with word timings.
                for j in result.lines[i].words.indices {
                    result.lines[i].words[j].text = variant.convert(result.lines[i].words[j].text)
                }
                result.lines[i].text = result.lines[i].words.map(\.text).joined()
            }
        }
        return result
    }
}
