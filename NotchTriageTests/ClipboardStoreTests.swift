import Foundation
import XCTest

@testable import NotchTriage

final class ClipboardStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testPayloadProjectionsAndCodableRoundTrip() throws {
        let text = ClipboardPayload.text("hello")
        XCTAssertEqual(text.byteCount, 5)
        XCTAssertFalse(text.stableFingerprint.isEmpty)

        let item = ClipboardHistoryItem(
            capturedAt: Date(timeIntervalSince1970: 123),
            sourceChangeCount: 42,
            payload: text
        )
        XCTAssertEqual(item.byteCount, 5)
        XCTAssertEqual(item.title, "hello")
        XCTAssertTrue(item.subtitle.contains("5 B"))

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipboardHistoryItem.self, from: data)
        XCTAssertEqual(decoded, item)
    }

    func testDuplicatePromotesAndUpdatesMetadata() async throws {
        let url = try makeFileURL(named: "note.txt")
        let store = ClipboardStore(
            retentionPolicy: .session,
            persistenceURL: persistenceURL()
        )

        let first = await store.add(
            .fileURLs([url]),
            sourceChangeCount: 1,
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let second = await store.add(
            .text("other"),
            sourceChangeCount: 2,
            capturedAt: Date(timeIntervalSince1970: 20)
        )
        let duplicate = await store.add(
            .fileURLs([url.standardizedFileURL]),
            sourceChangeCount: 3,
            capturedAt: Date(timeIntervalSince1970: 30)
        )

        XCTAssertTrue(first.isAccepted)
        XCTAssertTrue(second.isAccepted)
        XCTAssertTrue(duplicate.isDuplicate)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.first?.payload, .fileURLs([url.standardizedFileURL]))
        XCTAssertEqual(snapshot.first?.sourceChangeCount, 3)
        XCTAssertEqual(snapshot.first?.capturedAt, Date(timeIntervalSince1970: 30))
    }

    func testItemAndTotalBudgetLimitsReturnReasons() async throws {
        let store = ClipboardStore()
        let tooMuchText = String(repeating: "x", count: ClipboardStore.maximumTextUTF8Bytes + 1)
        let tooMuchImage = Data(repeating: 1, count: ClipboardStore.maximumImageBytes + 1)
        let tooManyURLs = (0..<(ClipboardStore.maximumFileURLCount + 1)).map { index in
            URL(fileURLWithPath: "/tmp/clipboard-\(index)")
        }

        let textResult = await store.add(.text(tooMuchText))
        let imageResult = await store.add(.image(tooMuchImage, mimeType: "image/png"))
        let urlsResult = await store.add(.fileURLs(tooManyURLs))

        XCTAssertEqual(textResult.rejectionReason, .textTooLarge)
        XCTAssertEqual(imageResult.rejectionReason, .imageTooLarge)
        XCTAssertEqual(urlsResult.rejectionReason, .tooManyFileURLs)

        let oversized = ClipboardPayload.image(
            Data(repeating: 2, count: ClipboardStore.maximumPayloadBytes + 1),
            mimeType: "image/png"
        )
        let oversizedResult = await store.add(oversized)
        XCTAssertEqual(oversizedResult.rejectionReason, .imageTooLarge)
    }

    func testCapacityIsFiftyAndEvictsOldestItem() async throws {
        let store = ClipboardStore()
        for index in 0..<ClipboardStore.maximumItemCount {
            let result = await store.add(.text("item-\(index)"))
            XCTAssertTrue(result.isAccepted)
        }
        let newest = await store.add(.text("one-too-many"))
        XCTAssertTrue(newest.isAccepted)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, ClipboardStore.maximumItemCount)
        XCTAssertEqual(snapshot.first?.payload, .text("one-too-many"))
        XCTAssertFalse(snapshot.contains { $0.payload == .text("item-0") })
    }

    func testTotalPayloadBudgetRejectsNewItem() async throws {
        let store = ClipboardStore()
        let firstChunk = Data(repeating: 1, count: ClipboardStore.maximumImageBytes)
        let secondChunk = Data(repeating: 2, count: ClipboardStore.maximumImageBytes)
        let thirdChunk = Data(repeating: 3, count: ClipboardStore.maximumImageBytes)
        let first = await store.add(.image(firstChunk, mimeType: "image/png"))
        let second = await store.add(.image(secondChunk, mimeType: "image/png"))
        XCTAssertTrue(first.isAccepted)
        XCTAssertTrue(second.isAccepted)
        let result = await store.add(.image(thirdChunk, mimeType: "image/png"))
        XCTAssertTrue(result.isAccepted)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.first?.payload, .image(thirdChunk, mimeType: "image/png"))
        let totalByteCount = await store.totalByteCount
        XCTAssertLessThanOrEqual(totalByteCount, ClipboardStore.maximumPayloadBytes)
    }

    func testAllRetentionPoliciesExposeExpectedMaxAge() {
        XCTAssertNil(ClipboardRetentionPolicy.session.maxAge)
        XCTAssertEqual(ClipboardRetentionPolicy.oneDay.maxAge, 86_400)
        XCTAssertEqual(ClipboardRetentionPolicy.sevenDays.maxAge, 604_800)
    }

    func testEmptyAndUnsupportedPayloadsAreRejected() async {
        let store = ClipboardStore()
        let blank = await store.add(.text("  \n"))
        let emptyFiles = await store.add(.fileURLs([]))
        let unsupportedImage = await store.add(
            .image(Data([1]), mimeType: "image/webp")
        )
        XCTAssertEqual(blank.rejectionReason, .emptyPayload)
        XCTAssertEqual(emptyFiles.rejectionReason, .emptyPayload)
        XCTAssertEqual(unsupportedImage.rejectionReason, .unsupportedImageType)
    }

    func testOneDayAndSevenDayTTLPruneOnLoad() async throws {
        let persistence = persistenceURL()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = ClipboardHistoryItem(
            capturedAt: now.addingTimeInterval(-86_401),
            payload: .text("old")
        )
        let fresh = ClipboardHistoryItem(
            capturedAt: now.addingTimeInterval(-86_399),
            payload: .text("fresh")
        )
        try JSONEncoder().encode([old, fresh]).write(to: persistence)
        let store = ClipboardStore(
            retentionPolicy: .oneDay,
            persistenceURL: persistence,
            now: { now }
        )
        _ = await store.load()
        let oneDaySnapshot = await store.snapshot()
        XCTAssertEqual(oneDaySnapshot.map(\.payload), [.text("fresh")])

        let sevenDayOld = ClipboardHistoryItem(
            capturedAt: now.addingTimeInterval(-604_801),
            payload: .text("seven-old")
        )
        try JSONEncoder().encode([sevenDayOld]).write(to: persistence)
        let sevenDayStore = ClipboardStore(
            retentionPolicy: .sevenDays,
            persistenceURL: persistence,
            now: { now }
        )
        let sevenDayLoad = await sevenDayStore.load()
        XCTAssertTrue(sevenDayLoad.items.isEmpty)
    }

    func testSessionDoesNotPersistAndRemovesOldFile() async throws {
        let persistence = persistenceURL()
        try Data("old history".utf8).write(to: persistence)
        let store = ClipboardStore(
            retentionPolicy: .session,
            persistenceURL: persistence
        )
        _ = await store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.path))
        let result = await store.add(.text("in memory"))
        XCTAssertTrue(result.isAccepted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.path))
    }

    func testPersistentHistoryWritesAndReloadsAtomically() async throws {
        let persistence = persistenceURL()
        let store = ClipboardStore(
            retentionPolicy: .oneDay,
            persistenceURL: persistence
        )
        let result = await store.add(.text("persisted"))
        XCTAssertTrue(result.isAccepted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.path))

        let reloaded = ClipboardStore(
            retentionPolicy: .oneDay,
            persistenceURL: persistence
        )
        _ = await reloaded.load()
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot.map(\.payload), [.text("persisted")])
    }

    func testPersistentImageUsesSidecarInsteadOfEmbeddingBytesInIndex() async throws {
        let persistence = persistenceURL()
        let imageBytes = Data("private-image-bytes".utf8)
        let store = ClipboardStore(
            retentionPolicy: .sevenDays,
            persistenceURL: persistence
        )

        let result = await store.add(
            .image(imageBytes, mimeType: "image/png")
        )
        XCTAssertTrue(result.isAccepted)

        let indexData = try Data(contentsOf: persistence)
        XCTAssertFalse(indexData.range(of: imageBytes) != nil)
        XCTAssertFalse(String(decoding: indexData, as: UTF8.self).contains(
            imageBytes.base64EncodedString()
        ))

        let sidecarDirectory = persistence.deletingLastPathComponent()
            .appendingPathComponent("Clipboard Images", isDirectory: true)
        let sidecars = try FileManager.default.contentsOfDirectory(
            at: sidecarDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(sidecars.count, 1)
        XCTAssertEqual(
            sidecars[0].lastPathComponent,
            "\(ClipboardPayload.image(imageBytes, mimeType: "image/png").stableFingerprint).clipboard-image"
        )
        XCTAssertEqual(try Data(contentsOf: sidecars[0]), imageBytes)

        let reloaded = ClipboardStore(
            retentionPolicy: .sevenDays,
            persistenceURL: persistence
        )
        _ = await reloaded.load()
        let reloadedSnapshot = await reloaded.snapshot()
        XCTAssertEqual(
            reloadedSnapshot.first?.payload,
            .image(imageBytes, mimeType: "image/png")
        )

        _ = await reloaded.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarDirectory.path))
    }

    func testClearingHistoryPreservesUnmanagedFilesInSidecarDirectory() async throws {
        let persistence = persistenceURL()
        let store = ClipboardStore(
            retentionPolicy: .sevenDays,
            persistenceURL: persistence
        )
        _ = await store.add(.image(Data([1, 2, 3]), mimeType: "image/png"))
        let sidecarDirectory = persistence.deletingLastPathComponent()
            .appendingPathComponent("Clipboard Images", isDirectory: true)
        let unmanagedFile = sidecarDirectory.appendingPathComponent("do-not-delete.txt")
        try Data("owned elsewhere".utf8).write(to: unmanagedFile)

        _ = await store.removeAll()

        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanagedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.path))
        let remaining = try FileManager.default.contentsOfDirectory(
            at: sidecarDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(remaining.map(\.lastPathComponent), ["do-not-delete.txt"])
    }

    func testClearFailureKeepsInMemoryHistoryAndReportsFailure() async throws {
        let lockedDirectory = temporaryDirectory
            .appendingPathComponent("locked-history", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockedDirectory,
            withIntermediateDirectories: true
        )
        let persistence = lockedDirectory.appendingPathComponent("history.json")
        let store = ClipboardStore(
            retentionPolicy: .sevenDays,
            persistenceURL: persistence
        )
        _ = await store.add(.text("must not pretend to be cleared"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: lockedDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: lockedDirectory.path
            )
        }

        let result = await store.removeAllResult()
        let snapshot = await store.snapshot()

        XCTAssertFalse(result.didSucceed)
        XCTAssertEqual(
            snapshot.map(\.payload),
            [.text("must not pretend to be cleared")]
        )
    }

    func testSidecarCleanupFailureKeepsCommittedClearAndReportsResidualData() async throws {
        let persistence = persistenceURL()
        let store = ClipboardStore(
            retentionPolicy: .sevenDays,
            persistenceURL: persistence
        )
        _ = await store.add(.image(Data([4, 5, 6]), mimeType: "image/png"))
        let sidecarDirectory = persistence.deletingLastPathComponent()
            .appendingPathComponent("Clipboard Images", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: sidecarDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: sidecarDirectory.path
            )
        }

        let result = await store.removeAllResult()
        let snapshot = await store.snapshot()

        XCTAssertTrue(result.didSucceed)
        XCTAssertFalse(result.didCleanPersistedData)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.path))
    }

    func testCorruptPersistenceIsDiscarded() async throws {
        let persistence = persistenceURL()
        let store = ClipboardStore(
            retentionPolicy: .oneDay,
            persistenceURL: persistence
        )
        try Data("not-json".utf8).write(to: persistence)
        let result = await store.load()
        XCTAssertTrue(result.wasCorrupt)
        XCTAssertTrue(result.didCleanPersistedData)
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.path))
    }

    func testUnreadablePersistenceCleanupFailureIsReported() async throws {
        let persistence = persistenceURL()
        try FileManager.default.createDirectory(
            at: persistence,
            withIntermediateDirectories: true
        )
        let unmanagedFile = persistence.appendingPathComponent("keep.txt")
        try Data("not managed by clipboard history".utf8).write(to: unmanagedFile)
        let store = ClipboardStore(
            retentionPolicy: .oneDay,
            persistenceURL: persistence
        )

        let result = await store.load()
        let snapshot = await store.snapshot()

        XCTAssertFalse(result.didReadPersistence)
        XCTAssertFalse(result.didCleanPersistedData)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanagedFile.path))
    }

    func testInvalidFileURLsAreRejectedAndStandardized() async throws {
        let file = try makeFileURL(named: "file.txt")
        let variant = temporaryDirectory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("..")
            .appendingPathComponent(file.lastPathComponent)
        let store = ClipboardStore()

        let accepted = await store.add(.fileURLs([variant]))
        XCTAssertTrue(accepted.isAccepted)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.first?.payload, .fileURLs([file.standardizedFileURL]))

        let rejected = await store.add(.fileURLs([URL(string: "https://example.com")!]))
        XCTAssertEqual(rejected.rejectionReason, .invalidFileURL)
    }

    func testRemoveClearAndPolicyReplacementOnlyTouchStorePersistence() async throws {
        let persistence = persistenceURL()
        let store = ClipboardStore(
            retentionPolicy: .oneDay,
            persistenceURL: persistence
        )
        let result = await store.add(.text("keep clipboard untouched"))
        let item = try XCTUnwrap(result.item)
        let removed = await store.remove(id: item.id)
        XCTAssertTrue(removed)
        let removedCount = await store.removeAll()
        XCTAssertEqual(removedCount, 0)

        _ = await store.add(.text("to clear"))
        let clearedCount = await store.removeAll()
        XCTAssertEqual(clearedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.path))

        _ = await store.add(.text("session only"))
        _ = await store.replacePolicy(.session)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.map(\.payload), [.text("session only")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.path))
    }

    private func persistenceURL() -> URL {
        temporaryDirectory.appendingPathComponent("clipboard-history.json")
    }

    private func makeFileURL(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data("file".utf8)
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        var template = Array(
            (FileManager.default.temporaryDirectory.path
                + "/NotchTriageClipboardTests.XXXXXX").utf8CString
        )
        guard let path = template.withUnsafeMutableBufferPointer({ buffer in
            mkdtemp(buffer.baseAddress)
        }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}
