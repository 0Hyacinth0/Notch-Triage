import Foundation
import CommonCrypto
import CryptoKit

// Public anonymous NetEase protocol parameters; no account cookies are read.
enum LyricsEAPI {
    static func request(id: Int) throws -> URLRequest {
        let path = "/api/song/lyric/v1"
        let header = ["__csrf": "", "buildver": String(Int(Date().timeIntervalSince1970)), "channel": "", "mobilename": "", "resolution": "1920x1080", "osver": "", "MUSIC_U": "", "os": "android", "appver": "8.0.0", "versioncode": "140", "deviceId": "", "requestId": "\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 1000...9999))"]
        var payload: [String: Any] = ["id": String(id), "cp": "false", "lv": "0", "kv": "0", "tv": "0", "rv": "0", "yv": "0", "ytv": "0", "yrv": "0", "csrf_token": ""]
        payload["header"] = String(decoding: try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]), as: UTF8.self)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        let digest = Insecure.MD5.hash(data: Data("nobody\(path)use\(json)md5forencrypt".utf8)).map { String(format: "%02x", $0) }.joined()
        let plain = Data("\(path)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)".utf8)
        let key = Data("e82ckenh8dichen8".utf8)
        var output = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { target in
            plain.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, nil, source.baseAddress, plain.count, target.baseAddress, target.count, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw URLError(.cannotParseResponse) }
        let hex = output.prefix(written).map { String(format: "%02X", $0) }.joined()
        var request = URLRequest(url: URL(string: "https://interface3.music.163.com/eapi/song/lyric/v1")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = Data("params=\(hex)".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Linux; Android 10)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(header.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        return request
    }
}
