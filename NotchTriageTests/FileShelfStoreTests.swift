import Foundation
import XCTest

@testable import NotchTriage

final class FileShelfStoreTests: XCTestCase {
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

    func testAddSupportsMultipleFilesAndFoldersWithNewestFirstOrdering() async throws {
        let first = try makeFile(named: "first.txt")
        let second = try makeFile(named: "second.txt")
        let folder = try makeFolder(named: "Folder")
        let store = FileShelfStore()

        let result = await store.add([first, second, folder])
        let snapshot = await store.snapshot()

        XCTAssertEqual(result.addedCount, 3)
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertEqual(result.overLimitCount, 0)
        XCTAssertEqual(result.rejectedCount, 0)
        XCTAssertEqual(result.acceptedCount, 3)
        XCTAssertEqual(result.acceptance, .accepted(count: 3))
        XCTAssertEqual(
            snapshot.map(\.url),
            [folder, second, first].map(\.standardizedFileURL)
        )
    }

    func testStandardizedPathDeduplicatesAndPromotesExistingReference() async throws {
        let first = try makeFile(named: "first.txt")
        let second = try makeFile(named: "second.txt")
        let store = FileShelfStore()

        _ = await store.add([first, second])
        let variant = temporaryDirectory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("..")
            .appendingPathComponent(first.lastPathComponent)

        let result = await store.add(variant)
        let snapshot = await store.snapshot()

        XCTAssertEqual(result.addedCount, 0)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.acceptance, .accepted(count: 1))
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.first?.url, first.standardizedFileURL)
        XCTAssertEqual(snapshot.first?.id, snapshot.last(where: {
            $0.standardizedPath == first.standardizedFileURL.path
        })?.id)
    }

    func testShelfEnforcesTwentyItemLimitAndStillPromotesDuplicates() async throws {
        let files = try (0..<21).map { index in
            try makeFile(named: "file-\(index).txt")
        }
        let store = FileShelfStore()

        let result = await store.add(files)
        let snapshot = await store.snapshot()

        XCTAssertEqual(result.addedCount, FileShelfStore.maximumItemCount)
        XCTAssertEqual(result.overLimitCount, 1)
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertEqual(result.rejectedCount, 0)
        XCTAssertEqual(result.acceptance.acceptedCount, 20)
        XCTAssertEqual(result.acceptance.rejectedCount, 1)
        XCTAssertEqual(snapshot.count, FileShelfStore.maximumItemCount)

        let duplicateResult = await store.add(files[0])
        XCTAssertEqual(duplicateResult.addedCount, 0)
        XCTAssertEqual(duplicateResult.duplicateCount, 1)
        XCTAssertEqual(duplicateResult.overLimitCount, 0)
        let promotedSnapshot = await store.snapshot()
        XCTAssertEqual(promotedSnapshot.first?.url, files[0].standardizedFileURL)
    }

    func testNonFileURLIsRejectedAndDoesNotEnterShelf() async throws {
        let file = try makeFile(named: "accepted.txt")
        let nonFileURL = try XCTUnwrap(URL(string: "https://example.com/file.txt"))
        let store = FileShelfStore()

        let result = await store.add([nonFileURL, file])

        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertEqual(result.overLimitCount, 0)
        XCTAssertEqual(result.rejectedCount, 1)
        XCTAssertEqual(result.acceptance.acceptedCount, 1)
        XCTAssertEqual(result.acceptance.rejectedCount, 1)
        XCTAssertEqual(result.acceptance.reason, "仅支持本地 file URL，其他项目已拒绝。")
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.map(\.url), [file.standardizedFileURL])
    }

    func testMissingSourceRemainsInShelfAndReportsUnavailable() async throws {
        let file = try makeFile(named: "will-disappear.txt")
        let store = FileShelfStore()
        _ = await store.add(file)

        try FileManager.default.removeItem(at: file)
        let snapshot = await store.snapshot()
        let item = try XCTUnwrap(snapshot.first)

        XCTAssertEqual(item.url, file.standardizedFileURL)
        XCTAssertEqual(item.availability, .unavailable)
        XCTAssertFalse(item.isAvailable)
        XCTAssertEqual(snapshot.count, 1)
    }

    func testRemoveAndClearOnlyDeleteReferencesNotSourceFiles() async throws {
        let first = try makeFile(named: "keep-first.txt")
        let second = try makeFile(named: "keep-second.txt")
        let store = FileShelfStore()
        _ = await store.add([first, second])
        let snapshot = await store.snapshot()

        let itemID = try XCTUnwrap(snapshot.first?.id)
        let removed = await store.remove(id: itemID)
        XCTAssertTrue(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

        let removedCount = await store.removeAll()
        XCTAssertEqual(removedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let clearedSnapshot = await store.snapshot()
        XCTAssertTrue(clearedSnapshot.isEmpty)
    }

    func testRemoveByURLUsesStandardizedPathAndRejectsNonFileURL() async throws {
        let file = try makeFile(named: "remove-me.txt")
        let store = FileShelfStore()
        _ = await store.add(file)
        let variant = temporaryDirectory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("..")
            .appendingPathComponent(file.lastPathComponent)

        let removed = await store.remove(url: variant)
        let rejected = await store.remove(url: URL(string: "https://example.com")!)
        let snapshot = await store.snapshot()
        XCTAssertTrue(removed)
        XCTAssertFalse(rejected)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private func makeFile(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data("test".utf8)
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private func makeFolder(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        var template = Array(
            (FileManager.default.temporaryDirectory.path
                + "/NotchTriageFileShelfTests.XXXXXX").utf8CString
        )
        guard let path = template.withUnsafeMutableBufferPointer({ buffer in
            mkdtemp(buffer.baseAddress)
        }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}
