import Foundation
import CryptoKit

/// The amount of time for which clipboard history is retained.
///
/// `session` is deliberately memory-only.  The other policies opt into the
/// JSON persistence managed by `ClipboardStore`.
enum ClipboardRetentionPolicy: String, CaseIterable, Codable, Sendable {
    case session
    case oneDay
    case sevenDays

    /// The time-to-live for an item, or `nil` when it is tied to the process
    /// session rather than a wall-clock duration.
    var maxAge: TimeInterval? {
        switch self {
        case .session:
            return nil
        case .oneDay:
            return 24 * 60 * 60
        case .sevenDays:
            return 7 * 24 * 60 * 60
        }
    }

    /// Convenience spelling used by callers that model a policy as a TTL.
    var timeToLive: TimeInterval? {
        maxAge
    }

    func expirationDate(from capturedAt: Date) -> Date? {
        maxAge.map { capturedAt.addingTimeInterval($0) }
    }
}

/// The allow-listed data types stored by Clipboard History.
enum ClipboardPayload: Codable, Equatable, Sendable {
    case text(String)
    case image(Data, mimeType: String)
    case fileURLs([URL])

    /// Labelled factories keep pasteboard adapters readable while preserving
    /// the compact enum case spelling for data-layer callers.
    static func text(value: String) -> ClipboardPayload {
        .text(value)
    }

    static func image(data: Data, mimeType: String) -> ClipboardPayload {
        .image(data, mimeType: mimeType)
    }

    static func fileURLs(urls: [URL]) -> ClipboardPayload {
        .fileURLs(urls)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType
        case urls
    }

    private enum PayloadType: String, Codable {
        case text
        case image
        case fileURLs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PayloadType.self, forKey: .type)
        switch type {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(
                try container.decode(Data.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType)
            )
        case .fileURLs:
            self = .fileURLs(try container.decode([URL].self, forKey: .urls))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(PayloadType.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode(PayloadType.image, forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .fileURLs(let urls):
            try container.encode(PayloadType.fileURLs, forKey: .type)
            try container.encode(urls, forKey: .urls)
        }
    }

    /// Number of bytes represented by this payload in the local history.
    /// File URL entries are references, so only their normalized URL strings
    /// count toward the budget; the referenced files are never copied.
    var byteCount: Int {
        switch self {
        case .text(let value):
            return value.utf8.count
        case .image(let data, _):
            return data.count
        case .fileURLs(let urls):
            return urls.reduce(into: 0) { result, url in
                result += url.absoluteString.utf8.count
            }
        }
    }

    /// Stable, process-independent content identity used for de-duplication.
    /// `Hasher` is intentionally not used because its seed changes between
    /// processes and would make persisted history unstable.
    var stableFingerprint: String {
        var bytes = Data()
        func append(_ value: String) {
            bytes.append(contentsOf: value.utf8)
            bytes.append(0)
        }

        switch self {
        case .text(let value):
            append("text")
            bytes.append(contentsOf: value.utf8)
        case .image(let data, let mimeType):
            append("image")
            append(mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            bytes.append(data)
        case .fileURLs(let urls):
            append("fileURLs")
            for url in urls {
                append(url.standardizedFileURL.absoluteString)
            }
        }

        return SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Alias kept intentionally small for UI/monitor call sites.
    var fingerprint: String {
        stableFingerprint
    }

    /// Returns the canonical representation used before validation, hashing,
    /// and persistence.  URL normalization is the only structural rewrite.
    func standardized() -> ClipboardPayload? {
        switch self {
        case .text:
            return self
        case .image(let data, let mimeType):
            return .image(
                data,
                mimeType: mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .fileURLs(let urls):
            let normalized = urls.map(\.standardizedFileURL)
            guard normalized.allSatisfy({ $0.isFileURL && !$0.path.isEmpty }) else {
                return nil
            }
            return .fileURLs(normalized)
        }
    }

    /// Human-readable type name for simple list UIs.
    var kind: Kind {
        switch self {
        case .text: return .text
        case .image: return .image
        case .fileURLs: return .fileURLs
        }
    }

    enum Kind: String, Codable, Sendable {
        case text
        case image
        case fileURLs
    }
}

/// A single clipboard history entry.  It contains metadata only; file URL
/// payloads continue to refer to the user's original files.
struct ClipboardHistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    let sourceChangeCount: Int
    let payload: ClipboardPayload

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        sourceChangeCount: Int = 0,
        payload: ClipboardPayload
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.sourceChangeCount = sourceChangeCount
        self.payload = payload
    }

    init(
        _ payload: ClipboardPayload,
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        sourceChangeCount: Int = 0
    ) {
        self.init(
            id: id,
            capturedAt: capturedAt,
            sourceChangeCount: sourceChangeCount,
            payload: payload
        )
    }

    /// A short, side-effect-free title suitable for a list row.
    var title: String {
        switch payload {
        case .text(let value):
            let firstLine = value
                .split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" })
                .first
                .map(String.init) ?? ""
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Text"
            }
            return String(trimmed.prefix(80))
        case .image:
            return "Image"
        case .fileURLs(let urls):
            guard let first = urls.first else { return "Files" }
            let name = first.lastPathComponent
            return name.isEmpty ? first.path : name
        }
    }

    /// A compact, deterministic secondary label.  Date formatting is left to
    /// the view layer so this projection stays pure and locale-independent.
    var subtitle: String {
        switch payload {
        case .text:
            return "Text · \(Self.byteDescription(byteCount))"
        case .image(_, let mimeType):
            let type = mimeType.isEmpty ? "Image" : mimeType
            return "\(type) · \(Self.byteDescription(byteCount))"
        case .fileURLs(let urls):
            return "\(urls.count) file\(urls.count == 1 ? "" : "s") · \(Self.byteDescription(byteCount))"
        }
    }

    /// Number of bytes represented by `payload`.
    var byteCount: Int {
        payload.byteCount
    }

    var fingerprint: String {
        payload.stableFingerprint
    }

    private static func byteDescription(_ count: Int) -> String {
        guard count >= 1_024 else { return "\(count) B" }
        if count < 1_024 * 1_024 {
            return String(format: "%.1f KiB", Double(count) / 1_024)
        }
        return String(format: "%.1f MiB", Double(count) / (1_024 * 1_024))
    }
}

/// Reasons a clipboard payload cannot be accepted by `ClipboardStore`.
enum ClipboardMutationRejectionReason: String, Codable, CaseIterable, Equatable, Sendable {
    case emptyPayload
    case textTooLarge
    case imageTooLarge
    case unsupportedImageType
    case tooManyFileURLs
    case invalidFileURL
    case payloadTooLarge
    case capacityExceeded
    case persistenceFailed

    // More descriptive aliases for call sites that prefer the limit wording.
    static let textExceedsLimit = Self.textTooLarge
    static let imageExceedsLimit = Self.imageTooLarge
    static let fileURLCountExceedsLimit = Self.tooManyFileURLs

    var message: String {
        switch self {
        case .emptyPayload:
            return "Empty clipboard payloads are not stored."
        case .textTooLarge:
            return "Text payload exceeds the 50,000 UTF-8 byte limit."
        case .imageTooLarge:
            return "Image payload exceeds the 10 MiB limit."
        case .unsupportedImageType:
            return "Only PNG, JPEG, and TIFF images are supported."
        case .tooManyFileURLs:
            return "A payload may contain at most 20 file URLs."
        case .invalidFileURL:
            return "Only non-empty local file URLs are supported."
        case .payloadTooLarge:
            return "The payload exceeds the 24 MiB history budget."
        case .capacityExceeded:
            return "Clipboard history is full (50 items)."
        case .persistenceFailed:
            return "Clipboard history could not be persisted."
        }
    }
}

/// The result of inserting one payload into `ClipboardStore`.
enum ClipboardMutationResult: Equatable, Sendable {
    case accepted(ClipboardHistoryItem)
    case duplicate(ClipboardHistoryItem)
    case rejected(ClipboardMutationRejectionReason)

    var item: ClipboardHistoryItem? {
        switch self {
        case .accepted(let item), .duplicate(let item):
            return item
        case .rejected:
            return nil
        }
    }

    var acceptedItem: ClipboardHistoryItem? {
        guard case .accepted(let item) = self else { return nil }
        return item
    }

    var rejectionReason: ClipboardMutationRejectionReason? {
        guard case .rejected(let reason) = self else { return nil }
        return reason
    }

    var isAccepted: Bool {
        switch self {
        case .accepted, .duplicate: return true
        case .rejected: return false
        }
    }

    var isDuplicate: Bool {
        if case .duplicate = self { return true }
        return false
    }

    var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    var reason: ClipboardMutationRejectionReason? {
        rejectionReason
    }
}

typealias ClipboardStoreMutationResult = ClipboardMutationResult
typealias ClipboardHistoryPayload = ClipboardPayload
typealias ClipboardItem = ClipboardHistoryItem
