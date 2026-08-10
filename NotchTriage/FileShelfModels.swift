import Foundation

/// Whether a referenced file or directory can currently be resolved on disk.
enum FileShelfAvailability: Equatable, Sendable {
    case available
    case unavailable
}

/// A session-only reference to a local file or directory.
///
/// The shelf owns no file contents.  Keeping the URL here means adding,
/// removing, and clearing an item never moves, copies, or deletes the source
/// item.  Availability is intentionally evaluated when read so a reference
/// remains visible after the source is moved or removed.
struct FileShelfItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let addedAt: Date
    let availability: FileShelfAvailability
    let isDirectory: Bool
    let byteSize: Int64?

    init(
        id: UUID = UUID(),
        url: URL,
        addedAt: Date = Date()
    ) {
        let standardizedURL = url.standardizedFileURL
        let resourceValues = try? standardizedURL.resourceValues(
            forKeys: [.isDirectoryKey, .fileSizeKey]
        )
        self.id = id
        self.url = standardizedURL
        self.addedAt = addedAt
        availability = FileManager.default.fileExists(
            atPath: standardizedURL.path
        ) ? .available : .unavailable
        isDirectory = resourceValues?.isDirectory ?? false
        byteSize = isDirectory
            ? nil
            : resourceValues?.fileSize.map(Int64.init)
    }

    /// The normalized path used by `FileShelfStore` for de-duplication.
    var standardizedPath: String {
        url.standardizedFileURL.path
    }

    var name: String {
        let lastPathComponent = url.lastPathComponent
        return lastPathComponent.isEmpty ? url.path : lastPathComponent
    }

    var isAvailable: Bool {
        availability == .available
    }

    func refreshed() -> FileShelfItem {
        FileShelfItem(id: id, url: url, addedAt: addedAt)
    }
}

/// The high-level result shown while accepting a file drop.
enum FileDropAcceptance: Equatable, Sendable {
    case accepted(count: Int)
    case partial(acceptedCount: Int, rejectedCount: Int, reason: String)
    case rejected(count: Int, reason: String)

    var acceptedCount: Int {
        switch self {
        case .accepted(let count):
            return count
        case .partial(let acceptedCount, _, _):
            return acceptedCount
        case .rejected:
            return 0
        }
    }

    var rejectedCount: Int {
        switch self {
        case .accepted:
            return 0
        case .partial(_, let rejectedCount, _):
            return rejectedCount
        case .rejected(let count, _):
            return count
        }
    }

    var reason: String? {
        switch self {
        case .accepted:
            return nil
        case .partial(_, _, let reason), .rejected(_, let reason):
            return reason
        }
    }

    var isAccepted: Bool {
        switch self {
        case .accepted:
            return true
        case .partial, .rejected:
            return false
        }
    }

    var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }
}

/// Counts and references produced by one `FileShelfStore.add` operation.
struct FileShelfMutationResult: Equatable, Sendable {
    let addedCount: Int
    let duplicateCount: Int
    let overLimitCount: Int
    /// Count of URLs rejected because they were not local file URLs.
    let rejectedCount: Int
    /// Newly-created items, in the order in which they were accepted.
    let addedItems: [FileShelfItem]
    /// All accepted references, including duplicates that were promoted.
    let acceptedItems: [FileShelfItem]
    let acceptance: FileDropAcceptance

    init(
        addedCount: Int,
        duplicateCount: Int,
        overLimitCount: Int,
        rejectedCount: Int,
        addedItems: [FileShelfItem] = [],
        acceptedItems: [FileShelfItem] = [],
        acceptance: FileDropAcceptance? = nil
    ) {
        self.addedCount = addedCount
        self.duplicateCount = duplicateCount
        self.overLimitCount = overLimitCount
        self.rejectedCount = rejectedCount
        self.addedItems = addedItems
        self.acceptedItems = acceptedItems

        let acceptedCount = addedCount + duplicateCount
        let totalRejectedCount = overLimitCount + rejectedCount
        if let acceptance {
            self.acceptance = acceptance
        } else if totalRejectedCount == 0 {
            self.acceptance = .accepted(count: acceptedCount)
        } else if acceptedCount > 0 {
            self.acceptance = .partial(
                acceptedCount: acceptedCount,
                rejectedCount: totalRejectedCount,
                reason: Self.reason(
                    rejectedCount: rejectedCount,
                    overLimitCount: overLimitCount
                )
            )
        } else {
            self.acceptance = .rejected(
                count: totalRejectedCount,
                reason: Self.reason(
                    rejectedCount: rejectedCount,
                    overLimitCount: overLimitCount
                )
            )
        }
    }

    var acceptedCount: Int {
        addedCount + duplicateCount
    }

    var totalRejectedCount: Int {
        rejectedCount + overLimitCount
    }

    var items: [FileShelfItem] {
        acceptedItems
    }

    private static func reason(rejectedCount: Int, overLimitCount: Int) -> String {
        switch (rejectedCount > 0, overLimitCount > 0) {
        case (true, true):
            return "仅支持本地文件或文件夹，且暂存架最多保留 20 项。"
        case (true, false):
            return "仅支持本地 file URL，其他项目已拒绝。"
        case (false, true):
            return "暂存架最多保留 20 项，超出项目未加入。"
        case (false, false):
            return ""
        }
    }
}
