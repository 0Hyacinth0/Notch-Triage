import Foundation

/// Summary returned by an explicit or initialization-time persistence load.
struct ClipboardLoadResult: Equatable, Sendable {
    let items: [ClipboardHistoryItem]
    let discardedCount: Int
    let wasCorrupt: Bool
    let didReadPersistence: Bool
    let didCleanPersistedData: Bool

    var loadedCount: Int {
        items.count
    }

    var didDiscardItems: Bool {
        discardedCount > 0 || wasCorrupt
    }
}

struct ClipboardClearResult: Equatable, Sendable {
    let removedCount: Int
    let didSucceed: Bool
    let didCleanPersistedData: Bool
}

/// Local clipboard history data store.
///
/// The store has no AppKit or pasteboard dependency by design.  A monitor may
/// pass a payload and its source `changeCount` into `add`; removing, clearing,
/// loading, and changing retention policy only touch this actor's memory and
/// its injected persistence URL.
actor ClipboardStore {
    private struct PersistenceResult {
        let didCommit: Bool
        let didCleanStaleData: Bool
    }

    static let maximumItemCount = 50
    static let maximumPayloadBytes = 24 * 1_024 * 1_024
    static let maximumTextUTF8Bytes = 50_000
    static let maximumImageBytes = 10 * 1_024 * 1_024
    static let maximumFileURLCount = 20

    // Label aliases make the limits discoverable without duplicating values.
    static let maxItemCount = maximumItemCount
    static let maxPayloadBytes = maximumPayloadBytes
    static let maxTextUTF8Bytes = maximumTextUTF8Bytes
    static let maxImageBytes = maximumImageBytes
    static let maxFileURLCount = maximumFileURLCount
    static let maximumPayloadBudget = maximumPayloadBytes
    static let maximumItems = maximumItemCount

    let persistenceURL: URL?
    private(set) var retentionPolicy: ClipboardRetentionPolicy

    private let now: @Sendable () -> Date
    private var items: [ClipboardHistoryItem]
    private(set) var lastPersistenceCleanupSucceeded = true

    init(
        retentionPolicy: ClipboardRetentionPolicy = .session,
        persistenceURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.retentionPolicy = retentionPolicy
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        self.now = now
        // Never perform file I/O in the synchronous actor initializer: the
        // owner is commonly a @MainActor AppModel. `load()` performs the
        // session cleanup or persistent restore on this actor after startup.
        self.items = []
    }

    /// Alternate label matching the policy terminology used by settings UI.
    init(
        policy: ClipboardRetentionPolicy,
        persistenceURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            retentionPolicy: policy,
            persistenceURL: persistenceURL,
            now: now
        )
    }

    /// Returns entries from newest to oldest, cleaning expired entries first.
    func snapshot() -> [ClipboardHistoryItem] {
        _ = purgeExpired()
        return items
    }

    func history() -> [ClipboardHistoryItem] {
        snapshot()
    }

    func allItems() -> [ClipboardHistoryItem] {
        snapshot()
    }

    var count: Int {
        items.count
    }

    var totalByteCount: Int {
        items.reduce(into: 0) { result, item in
            result += item.byteCount
        }
    }

    var totalPayloadBytes: Int {
        totalByteCount
    }

    /// Reads persistence again using the current policy.  This is useful after
    /// an external restore or for an explicit launch lifecycle step.
    @discardableResult
    func load() -> ClipboardLoadResult {
        guard retentionPolicy != .session else {
            let persistence = Self.removePersistence(at: persistenceURL)
            lastPersistenceCleanupSucceeded = persistence.didCommit
                && persistence.didCleanStaleData
            items.removeAll(keepingCapacity: false)
            return ClipboardLoadResult(
                items: [],
                discardedCount: 0,
                wasCorrupt: false,
                didReadPersistence: false,
                didCleanPersistedData: lastPersistenceCleanupSucceeded
            )
        }

        let loaded = Self.readItems(
            from: persistenceURL,
            policy: retentionPolicy,
            now: now()
        )
        items = loaded.items

        let persistence: PersistenceResult
        if loaded.wasCorrupt || loaded.items.isEmpty {
            persistence = Self.removePersistence(at: persistenceURL)
        } else if loaded.didDiscardItems {
            persistence = Self.persist(loaded.items, to: persistenceURL)
        } else {
            persistence = PersistenceResult(
                didCommit: true,
                didCleanStaleData: true
            )
        }
        lastPersistenceCleanupSucceeded = persistence.didCommit
            && persistence.didCleanStaleData
        return ClipboardLoadResult(
            items: loaded.items,
            discardedCount: loaded.discardedCount,
            wasCorrupt: loaded.wasCorrupt,
            didReadPersistence: loaded.didReadPersistence,
            didCleanPersistedData: lastPersistenceCleanupSucceeded
        )
    }

    func loadItems() -> [ClipboardHistoryItem] {
        load().items
    }

    /// Inserts one payload.  New entries are placed at the front.
    @discardableResult
    func add(
        _ payload: ClipboardPayload,
        sourceChangeCount: Int = 0,
        capturedAt: Date? = nil
    ) -> ClipboardMutationResult {
        add(
            payload: payload,
            sourceChangeCount: sourceChangeCount,
            capturedAt: capturedAt
        )
    }

    @discardableResult
    func add(
        payload: ClipboardPayload,
        sourceChangeCount: Int = 0,
        capturedAt: Date? = nil
    ) -> ClipboardMutationResult {
        let date = capturedAt ?? now()
        guard let normalized = Self.validatedPayload(payload) else {
            return .rejected(Self.rejectionReason(for: payload))
        }

        _ = purgeExpired()
        let fingerprint = normalized.stableFingerprint

        if let existingIndex = items.firstIndex(where: {
            $0.fingerprint == fingerprint
        }) {
            let previousItems = items
            let existing = items.remove(at: existingIndex)
            let promoted = ClipboardHistoryItem(
                id: existing.id,
                capturedAt: date,
                sourceChangeCount: sourceChangeCount,
                payload: normalized
            )
            items.insert(promoted, at: 0)
            let persistence = persistIfNeeded()
            lastPersistenceCleanupSucceeded = persistence.didCleanStaleData
            guard persistence.didCommit else {
                items = previousItems
                return .rejected(.persistenceFailed)
            }
            return .duplicate(promoted)
        }

        let byteCount = normalized.byteCount
        guard byteCount <= Self.maximumPayloadBytes else {
            return .rejected(.payloadTooLarge)
        }

        let previousItems = items
        while items.count >= Self.maximumItemCount {
            items.removeLast()
        }
        while totalByteCount + byteCount > Self.maximumPayloadBytes,
              !items.isEmpty {
            items.removeLast()
        }
        let item = ClipboardHistoryItem(
            capturedAt: date,
            sourceChangeCount: sourceChangeCount,
            payload: normalized
        )
        items.insert(item, at: 0)
        let persistence = persistIfNeeded()
        lastPersistenceCleanupSucceeded = persistence.didCleanStaleData
        guard persistence.didCommit else {
            items = previousItems
            return .rejected(.persistenceFailed)
        }
        return .accepted(item)
    }

    @discardableResult
    func insert(
        _ payload: ClipboardPayload,
        sourceChangeCount: Int = 0,
        capturedAt: Date? = nil
    ) -> ClipboardMutationResult {
        add(
            payload,
            sourceChangeCount: sourceChangeCount,
            capturedAt: capturedAt
        )
    }

    @discardableResult
    func record(
        _ payload: ClipboardPayload,
        sourceChangeCount: Int = 0,
        capturedAt: Date? = nil
    ) -> ClipboardMutationResult {
        add(
            payload,
            sourceChangeCount: sourceChangeCount,
            capturedAt: capturedAt
        )
    }

    @discardableResult
    func append(
        _ payload: ClipboardPayload,
        sourceChangeCount: Int = 0,
        capturedAt: Date? = nil
    ) -> ClipboardMutationResult {
        add(
            payload,
            sourceChangeCount: sourceChangeCount,
            capturedAt: capturedAt
        )
    }

    /// Inserts a fully formed item, retaining its identity and timestamp.
    @discardableResult
    func add(_ item: ClipboardHistoryItem) -> ClipboardMutationResult {
        add(
            item.payload,
            sourceChangeCount: item.sourceChangeCount,
            capturedAt: item.capturedAt,
            preservingID: item.id
        )
    }

    @discardableResult
    private func add(
        _ payload: ClipboardPayload,
        sourceChangeCount: Int,
        capturedAt: Date?,
        preservingID id: UUID
    ) -> ClipboardMutationResult {
        let date = capturedAt ?? now()
        guard let normalized = Self.validatedPayload(payload) else {
            return .rejected(Self.rejectionReason(for: payload))
        }

        _ = purgeExpired()
        let fingerprint = normalized.stableFingerprint
        if let existingIndex = items.firstIndex(where: {
            $0.fingerprint == fingerprint
        }) {
            let previousItems = items
            let existing = items.remove(at: existingIndex)
            let promoted = ClipboardHistoryItem(
                id: id == existing.id ? existing.id : id,
                capturedAt: date,
                sourceChangeCount: sourceChangeCount,
                payload: normalized
            )
            items.insert(promoted, at: 0)
            let persistence = persistIfNeeded()
            lastPersistenceCleanupSucceeded = persistence.didCleanStaleData
            guard persistence.didCommit else {
                items = previousItems
                return .rejected(.persistenceFailed)
            }
            return .duplicate(promoted)
        }

        guard normalized.byteCount <= Self.maximumPayloadBytes else {
            return .rejected(.payloadTooLarge)
        }

        let previousItems = items
        while items.count >= Self.maximumItemCount {
            items.removeLast()
        }
        while totalByteCount + normalized.byteCount > Self.maximumPayloadBytes,
              !items.isEmpty {
            items.removeLast()
        }
        let newItem = ClipboardHistoryItem(
            id: id,
            capturedAt: date,
            sourceChangeCount: sourceChangeCount,
            payload: normalized
        )
        items.insert(newItem, at: 0)
        let persistence = persistIfNeeded()
        lastPersistenceCleanupSucceeded = persistence.didCleanStaleData
        guard persistence.didCommit else {
            items = previousItems
            return .rejected(.persistenceFailed)
        }
        return .accepted(newItem)
    }

    /// Removes one entry without touching the system pasteboard.
    @discardableResult
    func remove(id: ClipboardHistoryItem.ID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let previousItems = items
        items.remove(at: index)
        let persistence = persistIfNeeded()
        lastPersistenceCleanupSucceeded = persistence.didCleanStaleData
        guard persistence.didCommit else {
            items = previousItems
            return false
        }
        return true
    }

    @discardableResult
    func remove(_ id: ClipboardHistoryItem.ID) -> Bool {
        remove(id: id)
    }

    @discardableResult
    func remove(_ item: ClipboardHistoryItem) -> Bool {
        remove(id: item.id)
    }

    /// Removes every entry without touching source files or NSPasteboard.
    @discardableResult
    func removeAll() -> Int {
        let result = removeAllResult()
        return result.didSucceed ? result.removedCount : 0
    }

    @discardableResult
    func removeAllResult() -> ClipboardClearResult {
        let removedCount = items.count
        let previousItems = items
        items.removeAll(keepingCapacity: false)
        let persistence = persistIfNeeded()
        lastPersistenceCleanupSucceeded = persistence.didCleanStaleData
        guard persistence.didCommit else {
            items = previousItems
            return ClipboardClearResult(
                removedCount: 0,
                didSucceed: false,
                didCleanPersistedData: false
            )
        }
        return ClipboardClearResult(
            removedCount: removedCount,
            didSucceed: true,
            didCleanPersistedData: persistence.didCleanStaleData
        )
    }

    @discardableResult
    func clear() -> Int {
        removeAll()
    }

    /// Changes retention without reading or writing the system pasteboard.
    /// Switching to `session` retains the entries already in memory for this
    /// process, deletes any old persistence file, and stops future writes.
    /// Switching to a persistent policy retains current entries and writes
    /// them atomically at the injected URL.
    @discardableResult
    func replacePolicy(_ policy: ClipboardRetentionPolicy) -> [ClipboardHistoryItem] {
        let previousPolicy = retentionPolicy
        let previousItems = items
        retentionPolicy = policy
        _ = purgeExpired(persistChanges: false)
        let persistence = persistIfNeeded()
        lastPersistenceCleanupSucceeded = persistence.didCleanStaleData
        guard persistence.didCommit else {
            retentionPolicy = previousPolicy
            items = previousItems
            return items
        }
        return items
    }

    @discardableResult
    func setRetentionPolicy(_ policy: ClipboardRetentionPolicy) -> [ClipboardHistoryItem] {
        replacePolicy(policy)
    }

    // MARK: - Actor-private maintenance

    @discardableResult
    private func purgeExpired(persistChanges: Bool = true) -> Int {
        guard let maxAge = retentionPolicy.maxAge else { return 0 }
        let cutoff = now().addingTimeInterval(-maxAge)
        let previousItems = items
        let originalCount = items.count
        items.removeAll { $0.capturedAt <= cutoff }
        let removedCount = originalCount - items.count
        if removedCount > 0, persistChanges {
            let persistence = persistIfNeeded()
            lastPersistenceCleanupSucceeded = persistence.didCleanStaleData
            if !persistence.didCommit {
                items = previousItems
                return 0
            }
        }
        return removedCount
    }

    private func persistIfNeeded() -> PersistenceResult {
        guard retentionPolicy != .session else {
            return Self.removePersistence(at: persistenceURL)
        }
        guard !items.isEmpty else {
            return Self.removePersistence(at: persistenceURL)
        }
        return Self.persist(items, to: persistenceURL)
    }

    private static func validatedPayload(_ payload: ClipboardPayload) -> ClipboardPayload? {
        switch payload {
        case .text(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= maximumTextUTF8Bytes else { return nil }
        case .image(let data, let mimeType):
            guard !data.isEmpty,
                  supportedImageMIMETypes.contains(mimeType.lowercased()),
                  data.count <= maximumImageBytes else { return nil }
        case .fileURLs(let urls):
            guard !urls.isEmpty,
                  urls.count <= maximumFileURLCount else { return nil }
        }

        guard let standardized = payload.standardized() else { return nil }
        guard standardized.byteCount <= maximumPayloadBytes else { return nil }
        return standardized
    }

    private static func rejectionReason(
        for payload: ClipboardPayload
    ) -> ClipboardMutationRejectionReason {
        switch payload {
        case .text(let value):
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .emptyPayload
            }
            if value.utf8.count > maximumTextUTF8Bytes { return .textTooLarge }
        case .image(let data, let mimeType):
            if data.isEmpty { return .emptyPayload }
            if !supportedImageMIMETypes.contains(mimeType.lowercased()) {
                return .unsupportedImageType
            }
            if data.count > maximumImageBytes { return .imageTooLarge }
        case .fileURLs(let urls):
            if urls.isEmpty { return .emptyPayload }
            if urls.count > maximumFileURLCount { return .tooManyFileURLs }
            if urls.contains(where: {
                let normalized = $0.standardizedFileURL
                return !normalized.isFileURL || normalized.path.isEmpty
            }) {
                return .invalidFileURL
            }
        }

        if let standardized = payload.standardized(),
           standardized.byteCount > maximumPayloadBytes {
            return .payloadTooLarge
        }
        return .invalidFileURL
    }

    private static let supportedImageMIMETypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/tiff",
        "image/tif",
    ]

    // MARK: - Persistence

    private struct ReadResult {
        let items: [ClipboardHistoryItem]
        let discardedCount: Int
        let wasCorrupt: Bool
        let didReadPersistence: Bool
        let needsRewrite: Bool

        var didDiscardItems: Bool {
            discardedCount > 0 || needsRewrite
        }
    }

    private struct PersistedItem: Codable {
        let id: UUID
        let capturedAt: Date
        let sourceChangeCount: Int
        let payload: PersistedPayload

        init(item: ClipboardHistoryItem, imageDirectory: URL?) throws {
            id = item.id
            capturedAt = item.capturedAt
            sourceChangeCount = item.sourceChangeCount
            switch item.payload {
            case .text(let value):
                payload = .text(value)
            case .fileURLs(let urls):
                payload = .fileURLs(urls)
            case .image(let data, let mimeType):
                guard let imageDirectory else {
                    throw CocoaError(.fileNoSuchFile)
                }
                // Immutable content-addressed names keep the previous index
                // valid if writing a new index fails after a sidecar succeeds.
                let fileName = "\(item.payload.stableFingerprint).clipboard-image"
                let fileURL = imageDirectory.appendingPathComponent(fileName)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try data.write(to: fileURL, options: [.atomic])
                }
                payload = .image(fileName: fileName, mimeType: mimeType)
            }
        }

        func materialized(imageDirectory: URL?) -> ClipboardHistoryItem? {
            let materializedPayload: ClipboardPayload
            switch payload {
            case .text(let value):
                materializedPayload = .text(value)
            case .fileURLs(let urls):
                materializedPayload = .fileURLs(urls)
            case .image(let fileName, let mimeType):
                guard let imageDirectory,
                      Self.isSafeSidecarName(fileName),
                      let data = try? Data(
                        contentsOf: imageDirectory.appendingPathComponent(fileName),
                        options: [.mappedIfSafe]
                      ) else {
                    return nil
                }
                materializedPayload = .image(data, mimeType: mimeType)
                if Self.isContentAddressedSidecarName(fileName),
                   "\(materializedPayload.stableFingerprint).clipboard-image" != fileName {
                    return nil
                }
            }
            return ClipboardHistoryItem(
                id: id,
                capturedAt: capturedAt,
                sourceChangeCount: sourceChangeCount,
                payload: materializedPayload
            )
        }

        private static func isSafeSidecarName(_ name: String) -> Bool {
            !name.isEmpty
                && name == URL(fileURLWithPath: name).lastPathComponent
                && !name.contains("..")
                && isManagedSidecarName(name)
        }

        private static func isContentAddressedSidecarName(_ name: String) -> Bool {
            guard name.hasSuffix(".clipboard-image") else { return false }
            let stem = String(name.dropLast(".clipboard-image".count))
            return stem.count == 64 && stem.allSatisfy(\.isHexDigit)
        }

        fileprivate static func isManagedSidecarName(_ name: String) -> Bool {
            guard name.hasSuffix(".clipboard-image") else { return false }
            let stem = String(name.dropLast(".clipboard-image".count))
            return (stem.count == 64 && stem.allSatisfy(\.isHexDigit))
                || UUID(uuidString: stem) != nil
        }
    }

    private enum PersistedPayload: Codable {
        case text(String)
        case image(fileName: String, mimeType: String)
        case fileURLs([URL])

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case fileName
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
            switch try container.decode(PayloadType.self, forKey: .type) {
            case .text:
                self = .text(try container.decode(String.self, forKey: .text))
            case .image:
                self = .image(
                    fileName: try container.decode(String.self, forKey: .fileName),
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
            case .image(let fileName, let mimeType):
                try container.encode(PayloadType.image, forKey: .type)
                try container.encode(fileName, forKey: .fileName)
                try container.encode(mimeType, forKey: .mimeType)
            case .fileURLs(let urls):
                try container.encode(PayloadType.fileURLs, forKey: .type)
                try container.encode(urls, forKey: .urls)
            }
        }
    }

    private static func readItems(
        from url: URL?,
        policy: ClipboardRetentionPolicy,
        now: Date
    ) -> ReadResult {
        guard let url, let data = try? Data(contentsOf: url) else {
            return ReadResult(
                items: [],
                discardedCount: 0,
                wasCorrupt: false,
                didReadPersistence: false,
                needsRewrite: false
            )
        }

        let decoder = JSONDecoder()
        let decoded: [ClipboardHistoryItem]
        let unreadableSidecarCount: Int
        let needsRewrite: Bool
        if let persistedItems = try? decoder.decode([PersistedItem].self, from: data) {
            let imageDirectory = imageDirectory(for: url)
            decoded = persistedItems.compactMap {
                $0.materialized(imageDirectory: imageDirectory)
            }
            unreadableSidecarCount = persistedItems.count - decoded.count
            needsRewrite = false
        } else if let legacyItems = try? decoder.decode(
            [ClipboardHistoryItem].self,
            from: data
        ) {
            // One-time compatibility with development builds that embedded
            // image bytes in the JSON index. The next persist splits them.
            decoded = legacyItems
            unreadableSidecarCount = 0
            needsRewrite = !legacyItems.isEmpty
        } else {
            return ReadResult(
                items: [],
                discardedCount: 1,
                wasCorrupt: true,
                didReadPersistence: true,
                needsRewrite: false
            )
        }

        let cutoff = policy.maxAge.map { now.addingTimeInterval(-$0) }
        var seen = Set<String>()
        var kept: [ClipboardHistoryItem] = []
        var discardedCount = unreadableSidecarCount

        // Persisted data is expected newest-first, but sorting here makes a
        // hand-edited/restored file deterministic and protects capacity order.
        let ordered = decoded.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.id.uuidString > $1.id.uuidString
            }
            return $0.capturedAt > $1.capturedAt
        }

        for item in ordered {
            if let cutoff, item.capturedAt <= cutoff {
                discardedCount += 1
                continue
            }

            guard let standardized = validatedPayload(item.payload) else {
                discardedCount += 1
                continue
            }

            let fingerprint = standardized.stableFingerprint
            guard seen.insert(fingerprint).inserted else {
                discardedCount += 1
                continue
            }
            guard kept.count < maximumItemCount else {
                discardedCount += 1
                continue
            }

            let currentBytes = kept.reduce(into: 0) {
                $0 += $1.byteCount
            }
            guard currentBytes + standardized.byteCount <= maximumPayloadBytes else {
                discardedCount += 1
                continue
            }

            if standardized == item.payload {
                kept.append(item)
            } else {
                kept.append(
                    ClipboardHistoryItem(
                        id: item.id,
                        capturedAt: item.capturedAt,
                        sourceChangeCount: item.sourceChangeCount,
                        payload: standardized
                    )
                )
            }
        }

        return ReadResult(
            items: kept,
            discardedCount: discardedCount,
            wasCorrupt: false,
            didReadPersistence: true,
            needsRewrite: needsRewrite
        )
    }

    private static func persist(
        _ items: [ClipboardHistoryItem],
        to url: URL?
    ) -> PersistenceResult {
        guard let url else {
            return PersistenceResult(didCommit: true, didCleanStaleData: true)
        }
        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            let imageDirectory = imageDirectory(for: url)
            if items.contains(where: {
                if case .image = $0.payload { return true }
                return false
            }), let imageDirectory {
                try FileManager.default.createDirectory(
                    at: imageDirectory,
                    withIntermediateDirectories: true
                )
            }
            let persistedItems = try items.map {
                try PersistedItem(item: $0, imageDirectory: imageDirectory)
            }
            let data = try JSONEncoder().encode(persistedItems)
            try data.write(to: url, options: [.atomic])
            let didClean = removeStaleSidecars(
                keeping: Set(persistedItems.compactMap { item in
                    if case .image(let fileName, _) = item.payload {
                        return fileName
                    }
                    return nil
                }),
                in: imageDirectory
            )
            return PersistenceResult(
                didCommit: true,
                didCleanStaleData: didClean
            )
        } catch {
            return PersistenceResult(didCommit: false, didCleanStaleData: false)
        }
    }

    @discardableResult
    private static func removePersistence(at url: URL?) -> PersistenceResult {
        guard let url else {
            return PersistenceResult(didCommit: true, didCleanStaleData: true)
        }
        let fileManager = FileManager.default
        do {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) {
                guard !isDirectory.boolValue else {
                    return PersistenceResult(
                        didCommit: false,
                        didCleanStaleData: false
                    )
                }
                try fileManager.removeItem(at: url)
            }
        } catch {
            return PersistenceResult(didCommit: false, didCleanStaleData: false)
        }
        if let imageDirectory = imageDirectory(for: url) {
            return PersistenceResult(
                didCommit: true,
                didCleanStaleData: removeStaleSidecars(
                    keeping: [],
                    in: imageDirectory
                )
            )
        }
        return PersistenceResult(didCommit: true, didCleanStaleData: true)
    }

    private static func imageDirectory(for indexURL: URL?) -> URL? {
        indexURL?.deletingLastPathComponent()
            .appendingPathComponent("Clipboard Images", isDirectory: true)
    }

    @discardableResult
    private static func removeStaleSidecars(
        keeping liveFileNames: Set<String>,
        in directory: URL?
    ) -> Bool {
        guard let directory else { return true }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return true }
        guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return false }
        var didSucceed = true
        for fileURL in contents where
            PersistedItem.isManagedSidecarName(fileURL.lastPathComponent)
                && !liveFileNames.contains(fileURL.lastPathComponent) {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                didSucceed = false
            }
        }
        let remaining = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        if remaining?.isEmpty == true {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                didSucceed = false
            }
        }
        return didSucceed
    }

    static func defaultPersistenceURL() -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return applicationSupport
            .appendingPathComponent("Notch Triage", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
    }
}
