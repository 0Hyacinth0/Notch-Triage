import Foundation

/// Phrase-first conversion using the Apache-2.0 OpenCC dictionary data in
/// OpenCC/. Keeps lyric timing outside the conversion path.
enum OpenCCPhraseConverter {
    private struct DictionarySet {
        let values: [String: String]
        let maximumLength: Int
    }

    private static let traditionalToSimplified = load("TSCharacters", "TSPhrases")
    private static let simplifiedToTraditional = load("STCharacters", "STPhrases")

    static func convert(_ text: String, toSimplified: Bool) -> String? {
        let dictionary = toSimplified ? traditionalToSimplified : simplifiedToTraditional
        guard dictionary.maximumLength > 0 else { return nil }
        let characters = Array(text)
        var output = String()
        output.reserveCapacity(text.utf8.count)
        var position = 0
        while position < characters.count {
            var matched = false
            let limit = min(dictionary.maximumLength, characters.count - position)
            for length in stride(from: limit, through: 1, by: -1) {
                let phrase = String(characters[position..<(position + length)])
                guard let replacement = dictionary.values[phrase] else { continue }
                output.append(replacement)
                position += length
                matched = true
                break
            }
            if !matched {
                output.append(characters[position])
                position += 1
            }
        }
        return output
    }

    private static func load(_ charactersFile: String, _ phrasesFile: String) -> DictionarySet {
        var values: [String: String] = [:]
        var maximumLength = 0
        for name in [charactersFile, phrasesFile] {
            let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "OpenCC")
                ?? Bundle.main.url(forResource: name, withExtension: "txt")
            guard let url, let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in raw.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                let fields = line.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2, let first = fields[1].split(whereSeparator: \.isWhitespace).first,
                      !fields[0].isEmpty else { continue }
                let key = String(fields[0])
                values[key] = String(first)
                maximumLength = max(maximumLength, key.count)
            }
        }
        return DictionarySet(values: values, maximumLength: maximumLength)
    }
}
