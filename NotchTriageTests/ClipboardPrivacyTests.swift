import Foundation
import XCTest

@testable import NotchTriage

@MainActor
final class ClipboardPrivacyTests: XCTestCase {
    func testDeclaredTypeClassifierRejectsSensitiveAndUnknownTypes() {
        XCTAssertNil(
            GeneralPasteboardAccess.preferredPayloadKind(
                forDeclaredTypeIdentifiers: [
                    "org.nspasteboard.ConcealedType",
                    "public.utf8-plain-text",
                ]
            )
        )
        XCTAssertNil(
            GeneralPasteboardAccess.preferredPayloadKind(
                forDeclaredTypeIdentifiers: ["com.example.private-value"]
            )
        )
        XCTAssertTrue(
            GeneralPasteboardAccess.isSensitiveTypeIdentifier(
                "com.agilebits.onepassword"
            )
        )
    }

    func testDeclaredTypeClassifierUsesFileImageTextPriority() {
        XCTAssertEqual(
            GeneralPasteboardAccess.preferredPayloadKind(
                forDeclaredTypeIdentifiers: [
                    "public.utf8-plain-text",
                    "public.png",
                    "public.file-url",
                ]
            ),
            .fileURLs
        )
        XCTAssertEqual(
            GeneralPasteboardAccess.preferredPayloadKind(
                forDeclaredTypeIdentifiers: [
                    "public.utf8-plain-text",
                    "public.jpeg",
                ]
            ),
            .image
        )
        XCTAssertEqual(
            GeneralPasteboardAccess.preferredPayloadKind(
                forDeclaredTypeIdentifiers: ["public.utf8-plain-text"]
            ),
            .text
        )
    }

    func testMonitorIsStoppedAndDoesNotReadBeforeStart() async {
        let access = FakePasteboardAccess()
        let monitor = makeMonitor(access: access)

        await givePollingTaskTimeToRun()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(access.changeCountReadCount, 0)
        XCTAssertEqual(access.readPayloadCallCount, 0)
        monitor.stop()
    }

    func testStartEstablishesOnlyChangeCountBaseline() async {
        let access = FakePasteboardAccess(changeCount: 41)
        let monitor = makeMonitor(access: access)

        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(access.changeCountReadCount, 1)

        await givePollingTaskTimeToRun()

        XCTAssertEqual(access.readPayloadCallCount, 0)
        XCTAssertGreaterThan(access.changeCountReadCount, 1)
        monitor.stop()
    }

    func testChangedPasteboardIsReadAndForwardedOnce() async {
        let access = FakePasteboardAccess()
        var received: [(ClipboardPayload, Int)] = []
        let monitor = ClipboardMonitor(
            access: access,
            pollInterval: .milliseconds(1),
            onPayload: { payload, changeCount in
                received.append((payload, changeCount))
            },
            sleeper: { _ in await Task.yield() }
        )

        monitor.start()
        let changeCount = access.publish(.text("hello"))
        let delivered = await eventually {
            received.count == 1
        }

        XCTAssertTrue(delivered)
        XCTAssertEqual(access.readPayloadCallCount, 1)
        XCTAssertEqual(received.first?.1, changeCount)
        XCTAssertEqual(received.first?.0, .text("hello"))
        monitor.stop()
    }

    func testUnsupportedSensitiveAndOversizedPayloadsAreNotForwarded() async {
        let access = FakePasteboardAccess()
        var received: [ClipboardPayload] = []
        let monitor = ClipboardMonitor(
            access: access,
            pollInterval: .milliseconds(1),
            onPayload: { payload, _ in received.append(payload) },
            sleeper: { _ in await Task.yield() }
        )

        monitor.start()
        // A production adapter maps sensitive, unknown, malformed, and
        // over-limit declarations to nil.  The monitor must not turn those
        // rejected reads into history entries.
        _ = access.publish(nil, label: "concealed password")
        _ = await eventually { access.readPayloadCallCount == 1 }
        _ = access.publish(nil, label: "image over 10 MiB")
        _ = await eventually { access.readPayloadCallCount == 2 }

        XCTAssertEqual(access.readPayloadCallCount, 2)
        XCTAssertTrue(received.isEmpty)
        monitor.stop()
    }

    func testRegisteredSelfWriteIsSuppressedOnce() async {
        let access = FakePasteboardAccess()
        var received: [(ClipboardPayload, Int)] = []
        let monitor = ClipboardMonitor(
            access: access,
            pollInterval: .milliseconds(1),
            onPayload: { payload, changeCount in
                received.append((payload, changeCount))
            },
            sleeper: { _ in await Task.yield() }
        )

        monitor.start()
        let selfWriteChangeCount = access.publish(.text("written by user"))
        monitor.registerSelfWrite(changeCount: selfWriteChangeCount)
        await givePollingTaskTimeToRun()
        XCTAssertTrue(received.isEmpty)

        let nextChangeCount = access.publish(.text("copied elsewhere"))
        let delivered = await eventually { received.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(received.first?.1, nextChangeCount)
        monitor.stop()
    }

    func testStopCancelsPollingAndNeverReadsLaterChanges() async {
        let access = FakePasteboardAccess()
        var received: [ClipboardPayload] = []
        let monitor = makeMonitor(access: access) { payload, _ in
            received.append(payload)
        }

        monitor.start()
        monitor.stop()
        let readsAfterStop = access.readPayloadCallCount
        _ = access.publish(.text("after stop"))
        await givePollingTaskTimeToRun()

        XCTAssertEqual(access.readPayloadCallCount, readsAfterStop)
        XCTAssertTrue(received.isEmpty)
    }

    func testSuspendAndResumeResetBaselineWithoutBackfillingPausedContent() async {
        let access = FakePasteboardAccess()
        var received: [ClipboardPayload] = []
        let monitor = makeMonitor(access: access) { payload, _ in
            received.append(payload)
        }

        monitor.start()
        monitor.suspend()
        _ = access.publish(.text("copied while suspended"))
        monitor.resume()
        await givePollingTaskTimeToRun()
        XCTAssertTrue(received.isEmpty)

        _ = access.publish(.text("copied after resume"))
        let delivered = await eventually { received.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(received.first, .text("copied after resume"))
        monitor.stop()
    }

    func testOldPollingGenerationCannotReviveAfterRestart() async {
        let access = FakePasteboardAccess()
        var received: [ClipboardPayload] = []
        let monitor = makeMonitor(access: access) { payload, _ in
            received.append(payload)
        }

        monitor.start()
        monitor.stop()
        _ = access.publish(.text("between generations"))
        monitor.start() // New baseline intentionally skips that old change.
        await givePollingTaskTimeToRun()

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(access.readPayloadCallCount, 0)
        monitor.stop()
    }

    func testLifecycleNeverClearsPasteboard() async {
        let access = FakePasteboardAccess()
        let monitor = makeMonitor(access: access)

        monitor.start()
        monitor.suspend()
        monitor.resume()
        monitor.stop()

        XCTAssertEqual(access.clearCallCount, 0)
    }

    private func makeMonitor(
        access: FakePasteboardAccess,
        onPayload: @escaping @MainActor (ClipboardPayload, Int) -> Void = { _, _ in }
    ) -> ClipboardMonitor {
        ClipboardMonitor(
            access: access,
            pollInterval: .milliseconds(1),
            onPayload: onPayload,
            sleeper: { _ in await Task.yield() }
        )
    }

    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private func givePollingTaskTimeToRun() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    @MainActor
    private final class FakePasteboardAccess: PasteboardAccess {
        private var storedChangeCount: Int
        private(set) var changeCountReadCount = 0
        private(set) var readPayloadCallCount = 0
        private(set) var clearCallCount = 0

        private var payload: ClipboardPayload?
        private var lastLabel: String?

        init(changeCount: Int = 0) {
            storedChangeCount = changeCount
        }

        var changeCount: Int {
            changeCountReadCount += 1
            return storedChangeCount
        }

        var currentChangeCount: Int {
            storedChangeCount
        }

        func readPayload() -> ClipboardPayload? {
            readPayloadCallCount += 1
            return payload
        }

        @discardableResult
        func write(_ payload: ClipboardPayload) -> Int? {
            self.payload = payload
            storedChangeCount += 1
            return storedChangeCount
        }

        func publish(_ payload: ClipboardPayload?, label: String? = nil) -> Int {
            self.payload = payload
            lastLabel = label
            storedChangeCount += 1
            return storedChangeCount
        }

        func clearContents() -> Int {
            clearCallCount += 1
            storedChangeCount += 1
            return storedChangeCount
        }
    }
}
