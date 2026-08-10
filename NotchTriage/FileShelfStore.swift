import Foundation

/// In-memory, session-only storage for local file and directory references.
///
/// The actor serializes mutations without performing disk writes.  It only
/// checks file existence when a `FileShelfItem`'s availability is requested.
actor FileShelfStore {
    static let maximumItemCount = 20

    private let capacity: Int
    private var items: [FileShelfItem] = []

    init(maxItems: Int = FileShelfStore.maximumItemCount) {
        capacity = min(max(maxItems, 0), FileShelfStore.maximumItemCount)
    }

    /// Returns references from newest to oldest.
    func snapshot() -> [FileShelfItem] {
        items = items.map { $0.refreshed() }
        return items
    }

    /// Adds a batch of local file or directory URLs.
    ///
    /// URLs are processed in array order; each accepted URL is promoted to the
    /// front, so the last accepted URL in a batch is newest. Existing
    /// references are promoted rather than duplicated. Non-file URLs count as
    /// `rejected`, while new URLs beyond the capacity count as `overLimit`.
    @discardableResult
    func add(_ urls: [URL]) -> FileShelfMutationResult {
        var addedCount = 0
        var duplicateCount = 0
        var overLimitCount = 0
        var rejectedCount = 0
        var addedItems: [FileShelfItem] = []
        var acceptedItems: [FileShelfItem] = []

        for url in urls {
            guard let normalizedURL = Self.normalizedFileURL(url) else {
                rejectedCount += 1
                continue
            }

            let path = normalizedURL.path
            if let index = items.firstIndex(where: {
                $0.standardizedPath == path
            }) {
                let existing = items.remove(at: index).refreshed()
                items.insert(existing, at: 0)
                duplicateCount += 1
                acceptedItems.append(existing)
                continue
            }

            guard items.count < capacity else {
                overLimitCount += 1
                continue
            }

            let item = FileShelfItem(url: normalizedURL)
            items.insert(item, at: 0)
            addedCount += 1
            addedItems.append(item)
            acceptedItems.append(item)
        }

        return FileShelfMutationResult(
            addedCount: addedCount,
            duplicateCount: duplicateCount,
            overLimitCount: overLimitCount,
            rejectedCount: rejectedCount,
            addedItems: addedItems,
            acceptedItems: acceptedItems
        )
    }

    /// Labelled spelling for call sites that make the batch explicit.
    @discardableResult
    func add(urls: [URL]) -> FileShelfMutationResult {
        add(urls)
    }

    @discardableResult
    func add(_ url: URL) -> FileShelfMutationResult {
        add([url])
    }

    /// Removes one reference by its stable shelf identifier.
    @discardableResult
    func remove(id: FileShelfItem.ID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }
        items.remove(at: index)
        return true
    }

    @discardableResult
    func remove(_ id: FileShelfItem.ID) -> Bool {
        remove(id: id)
    }

    /// Removes a reference by normalized local URL.
    @discardableResult
    func remove(url: URL) -> Bool {
        guard let normalizedURL = Self.normalizedFileURL(url) else {
            return false
        }
        guard let index = items.firstIndex(where: {
            $0.standardizedPath == normalizedURL.path
        }) else {
            return false
        }
        items.remove(at: index)
        return true
    }

    @discardableResult
    func remove(_ url: URL) -> Bool {
        remove(url: url)
    }

    /// Removes a reference by its item value.
    @discardableResult
    func remove(_ item: FileShelfItem) -> Bool {
        remove(id: item.id)
    }

    /// Clears references only; no source file operation is performed.
    @discardableResult
    func removeAll() -> Int {
        let removedCount = items.count
        items.removeAll(keepingCapacity: false)
        return removedCount
    }

    @discardableResult
    func clear() -> Int {
        removeAll()
    }

    private static func normalizedFileURL(_ url: URL) -> URL? {
        guard url.isFileURL, !url.path.isEmpty else { return nil }
        let normalizedURL = url.standardizedFileURL
        guard normalizedURL.isFileURL, !normalizedURL.path.isEmpty else {
            return nil
        }
        return normalizedURL
    }
}
