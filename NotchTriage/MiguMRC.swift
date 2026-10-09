import Foundation

/// Decodes Migu's optional word-timed lyric file. The normal LRC is kept on failure.
enum MiguMRC {
    private static let key: [Int64] = [
        27303562373562475, 18014862372307051,
        22799692160172081, 34058940340699235
    ]
    private static let delta: Int64 = 0x9E3779B9

    static func parse(_ encryptedText: String, duration: Double) -> LyricsDocument? {
        let hex = encryptedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count >= 32, hex.count <= 2_097_152, hex.count.isMultiple(of: 16) else { return nil }
        var values: [Int64] = []
        values.reserveCapacity(hex.count / 16)
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let end = hex.index(cursor, offsetBy: 16)
            guard let value = UInt64(hex[cursor..<end], radix: 16) else { return nil }
            values.append(Int64(bitPattern: value))
            cursor = end
        }
        var sum = Int64(6 + 52 / values.count) &* delta
        var y = values[0]
        while sum != 0 {
            let e = (sum >> 2) & 3
            for index in stride(from: values.count - 1, through: 1, by: -1) {
                let z = values[index - 1]
                values[index] = values[index] &- mix(sum: sum, y: y, z: z, index: index, e: e)
                y = values[index]
            }
            values[0] = values[0] &- mix(sum: sum, y: y, z: values[values.count - 1], index: 0, e: e)
            y = values[0]
            sum = sum &- delta
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * 8)
        for value in values {
            let bits = UInt64(bitPattern: value)
            for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        }
        guard let plain = String(data: Data(bytes), encoding: .utf16LittleEndian) else { return nil }
        let rows = plain.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let timed = rows.filter { row in
            guard row.hasPrefix("["), let close = row.firstIndex(of: "]") else { return false }
            let header = row[row.index(after: row.startIndex)..<close].split(separator: ",")
            return header.count == 2 && !(header[0] == "0" && header[1] == "0")
                && row[close...].contains("(")
        }.joined(separator: "\n")
        guard var document = LyricsParser.parse(timed, source: "咪咕音乐", duration: duration, format: .qrc),
              document.hasWordTiming else { return nil }
        document.parserRevision = 3
        return document
    }

    private static func mix(sum: Int64, y: Int64, z: Int64, index: Int, e: Int64) -> Int64 {
        let left = ((z >> 5) ^ (y &<< 2)) &+ ((y >> 3) ^ (z &<< 4))
        let right = (sum ^ y) &+ (key[Int((Int64(index) & 3) ^ e)] ^ z)
        return left ^ right
    }
}
