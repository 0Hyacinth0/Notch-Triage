import AppKit
import ApplicationServices
import Foundation

struct NotificationSourceCandidate: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
}

enum NotificationSourceDetection {
    static let notificationCenterBundleIdentifier = "com.apple.notificationcenterui"
    static let bannerHostBundleIdentifier = "com.apple.UserNotificationCenter"
    static let notificationCenterNames = [
        "NotificationCenter",
        "Notification Center",
        "通知中心"
    ]
    static let bannerHostNames = ["UserNotificationCenter"]

    static let knownSources = [
        // Match Codex by its visible name; a bundle-only OpenAI match can be
        // ambiguous with ChatGPT.
        NotificationSourceCandidate(name: "Codex", bundleIdentifier: nil),
        NotificationSourceCandidate(name: "ChatGPT", bundleIdentifier: "com.openai.chat"),
        NotificationSourceCandidate(name: "微信", bundleIdentifier: "com.tencent.xinWeChat"),
        NotificationSourceCandidate(name: "钉钉", bundleIdentifier: nil),
        NotificationSourceCandidate(name: "QQ邮箱", bundleIdentifier: nil),
        NotificationSourceCandidate(name: "日历", bundleIdentifier: "com.apple.iCal"),
        NotificationSourceCandidate(name: "提醒事项", bundleIdentifier: "com.apple.reminders")
    ]

    static let notificationMarkers = ["通知", "notification", "alert", "提醒"]
    static let widgetMarkers = ["widget", "widget-local", "widgetkit"]

    static func detect(
        in texts: [String],
        candidates: [NotificationSourceCandidate]
    ) -> NotificationSourceCandidate? {
        if let application = detectApplication(in: texts, candidates: candidates) {
            return application
        }

        let values = normalized(texts)
        guard !values.contains(where: isNotificationCenter) else {
            return nil
        }
        if containsNotificationMarker(in: values) {
            return NotificationSourceCandidate(name: "系统通知", bundleIdentifier: nil)
        }

        return nil
    }

    static func detectApplication(
        in texts: [String],
        candidates: [NotificationSourceCandidate]
    ) -> NotificationSourceCandidate? {
        let values = normalized(texts)
        let allCandidates = uniqueCandidates(candidates + knownSources)
            .filter { !isWidgetOrExtension($0) && !isNotificationCenter($0) }
            .sorted { $0.name.count > $1.name.count }

        // Prefer an explicit app name over a bundle ID. Several app labels can
        // share an identifier, while the visible name still disambiguates them.
        if let namedMatch = allCandidates.first(where: { candidate in
            values.contains {
                $0.localizedCaseInsensitiveContains(candidate.name)
            }
        }) {
            guard let bundleIdentifier = namedMatch.bundleIdentifier else {
                return namedMatch
            }
            let matchingNames = Set(allCandidates.compactMap { candidate -> String? in
                guard let candidateIdentifier = candidate.bundleIdentifier,
                      candidateIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame else {
                    return nil
                }
                return candidate.name
            })
            if matchingNames.count > 1 {
                return NotificationSourceCandidate(
                    name: namedMatch.name,
                    bundleIdentifier: nil
                )
            }
            return namedMatch
        }

        let bundleMatches = allCandidates.filter { candidate in
            guard let bundleIdentifier = candidate.bundleIdentifier else { return false }
            return values.contains {
                $0.localizedCaseInsensitiveContains(bundleIdentifier)
            }
        }
        guard let firstMatch = bundleMatches.first else { return nil }
        guard let bundleIdentifier = firstMatch.bundleIdentifier else { return nil }
        let matchingNames = Set(bundleMatches.compactMap { candidate -> String? in
            guard let candidateIdentifier = candidate.bundleIdentifier,
                  candidateIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame else {
                return nil
            }
            return candidate.name
        })
        guard matchingNames.count > 1 else { return firstMatch }

        guard bundleIdentifier.caseInsensitiveCompare("com.openai.chat") == .orderedSame else {
            return nil
        }

        // A bundle-only match cannot truthfully distinguish these OpenAI apps.
        return NotificationSourceCandidate(
            name: "OpenAI",
            bundleIdentifier: bundleIdentifier
        )
    }

    static func isNotificationCenter(_ candidate: NotificationSourceCandidate) -> Bool {
        if [notificationCenterBundleIdentifier, bannerHostBundleIdentifier].contains(where: {
            candidate.bundleIdentifier?.caseInsensitiveCompare($0) == .orderedSame
        }) {
            return true
        }
        return (notificationCenterNames + bannerHostNames).contains {
            candidate.name.caseInsensitiveCompare($0) == .orderedSame
        }
    }

    static func isNotificationCenter(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if [notificationCenterBundleIdentifier, bannerHostBundleIdentifier].contains(where: {
            value.caseInsensitiveCompare($0) == .orderedSame
        }) {
            return true
        }
        return (notificationCenterNames + bannerHostNames).contains {
            value.caseInsensitiveCompare($0) == .orderedSame
        }
    }

    private static func normalized(_ texts: [String]) -> [String] {
        let values = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values
    }

    static func containsNotificationMarker(in texts: [String]) -> Bool {
        texts.contains { text in
            notificationMarkers.contains {
                text.localizedCaseInsensitiveContains($0)
            }
        }
    }

    static func isWidgetOrExtension(_ candidate: NotificationSourceCandidate) -> Bool {
        [candidate.name, candidate.bundleIdentifier]
            .compactMap { $0 }
            .contains(where: isWidgetOrExtension)
    }

    static func isWidgetOrExtension(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        return widgetMarkers.contains { normalized.contains($0) }
    }

    private static func uniqueCandidates(
        _ candidates: [NotificationSourceCandidate]
    ) -> [NotificationSourceCandidate] {
        candidates.reduce(into: []) { result, candidate in
            guard !result.contains(candidate) else { return }
            result.append(candidate)
        }
    }
}

enum NotificationClearAllLabelDetection {
    private static let labels = [
        "clear all", "clear all notifications", "dismiss all", "remove all",
        "clearall", "clearallbutton", "clearallnotifications",
        "clearallnotificationbutton", "clearallnotificationsbutton",
        "dismissall", "removeall",
        "全部清除", "清除全部", "清除所有", "全部清除通知", "清除所有通知",
        "すべて消去", "すべてを消去", "すべてクリア", "通知をすべて消去",
        "모두 지우기", "모두 삭제", "모든 알림 지우기",
        "alle löschen", "alles löschen", "alle entfernen",
        "tout effacer", "tout supprimer", "effacer tout",
        "borrar todo", "borrar todas", "eliminar todo", "eliminar todas", "limpiar todo",
        "cancella tutto", "rimuovi tutto",
        "limpar tudo", "apagar tudo",
        "alles wissen", "alles verwijderen",
        "очистить все", "удалить все",
        "مسح الكل", "إزالة الكل", "حذف الكل",
        "נקה הכל", "מחק הכל", "הסר הכל",
        "εκκαθάριση όλων", "διαγραφή όλων",
        "सब साफ़ करें", "सभी मिटाएं", "सभी हटाएं",
        "ล้างทั้งหมด", "ลบทั้งหมด",
        "xóa tất cả", "xóa hết",
        "hapus semua", "bersihkan semua",
        "kosongkan semua", "padam semua",
        "șterge tot", "șterge toate",
        "összes törlése", "mindent töröl",
        "vymazať všetko", "odstrániť všetko",
        "tümünü temizle", "tümünü sil",
        "wyczyść wszystkie", "usuń wszystkie",
        "rensa alla", "ta bort alla",
        "ryd alle", "fjern alle",
        "tyhjennä kaikki", "poista kaikki",
        "tøm alle", "fjern alle",
        "smazat vše", "odstranit vše"
    ]

    static func matches(_ accessibilityText: String) -> Bool {
        let normalizedText = normalized(accessibilityText)
        return labels.contains { normalizedText.contains(normalized($0)) }
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }
}

private final class NotificationAXCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private enum NotificationAXStatus: Sendable {
    case success
    case timedOut
    case unavailable
    case cancelled
}

private struct NotificationAXItem: Equatable, Sendable {
    let sourceName: String
    let bundleIdentifier: String?
    let fingerprint: String
    let isBanner: Bool
}

private struct NotificationAXScanResult: Sendable {
    let status: NotificationAXStatus
    let items: [NotificationAXItem]
    let observedNotificationCenterSurface: Bool
    let dismissedCount: Int
    let dismissalFailures: Int
}

private struct NotificationAXClearResult: Sendable {
    let status: NotificationAXStatus
    let didPressClear: Bool
}

private enum NotificationAXClearVerification: Equatable, Sendable {
    case clearAllButtonStillVisible
    case clearAllButtonNoLongerVisible
    case surfaceUnavailable
    case inconclusive
}

private struct NotificationAXScanRequest: Sendable {
    let id: Int
    let notificationCenterProcessIdentifier: pid_t?
    let bannerHostProcessIdentifier: pid_t?
    let scansNotificationCenterSurface: Bool
    let candidates: [NotificationSourceCandidate]
}

private enum NotificationAXSurface: Equatable, Sendable {
    case notificationCenter
    case bannerHost
}

private struct NotificationAXScanTarget: Sendable {
    let processIdentifier: pid_t
    let surface: NotificationAXSurface
}

private final class NotificationAXWorker: @unchecked Sendable {
    private static let maximumScanDepth = 7
    private static let maximumActionDepth = 8
    private static let maximumNodeCount = 160
    private static let maximumClearActionNodeCount = 700
    private static let messagingTimeout: Float = 0.08
    private static let scanDeadline: TimeInterval = 0.65
    private static let clearActionDeadline: TimeInterval = 2
    private static let clearActionMessagingTimeout: Float = 0.2
    private struct NodeSnapshot {
        let role: String?
        let textValues: [String]
        let children: [AXUIElement]
    }

    private struct WindowScan {
        let items: [NotificationAXItem]
        let bannerElement: AXUIElement?
        let observedNotificationCenterSurface: Bool
    }

    private struct ScanBudget {
        let deadlineUptime: TimeInterval
        let cancellation: NotificationAXCancellation
        let maximumNodeCount: Int
        var visitedNodeCount = 0
        var didReachLimit = false

        init(
            deadlineUptime: TimeInterval,
            cancellation: NotificationAXCancellation,
            maximumNodeCount: Int = NotificationAXWorker.maximumNodeCount
        ) {
            self.deadlineUptime = deadlineUptime
            self.cancellation = cancellation
            self.maximumNodeCount = maximumNodeCount
        }

        mutating func visit() -> Bool {
            guard !cancellation.isCancelled else { return false }
            guard ProcessInfo.processInfo.systemUptime < deadlineUptime,
                  visitedNodeCount < maximumNodeCount else {
                didReachLimit = true
                return false
            }
            visitedNodeCount += 1
            return true
        }
    }

    private let queue = DispatchQueue(
        label: "com.hyacinth.notchtriage.notification-accessibility",
        qos: .utility
    )

    func scan(
        targets: [NotificationAXScanTarget],
        candidates: [NotificationSourceCandidate]
    ) async -> NotificationAXScanResult {
        let cancellation = NotificationAXCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(
                        returning: Self.performScan(
                            targets: targets,
                            candidates: candidates,
                            cancellation: cancellation,
                            dismissFingerprints: []
                        )
                    )
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    func dismissBanners(
        processIdentifier: pid_t,
        candidates: [NotificationSourceCandidate],
        fingerprints: Set<String>
    ) async -> NotificationAXScanResult {
        let cancellation = NotificationAXCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(
                        returning: Self.performScan(
                            targets: [
                                NotificationAXScanTarget(
                                    processIdentifier: processIdentifier,
                                    surface: .bannerHost
                                )
                            ],
                            candidates: candidates,
                            cancellation: cancellation,
                            dismissFingerprints: fingerprints
                        )
                    )
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    func clearAllNotifications(
        processIdentifier: pid_t
    ) async -> NotificationAXClearResult {
        let cancellation = NotificationAXCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(
                        returning: Self.performClearAll(
                            processIdentifier: processIdentifier,
                            cancellation: cancellation
                        )
                    )
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    func verifyClearAllNotifications(
        processIdentifier: pid_t
    ) async -> NotificationAXClearVerification {
        let cancellation = NotificationAXCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(
                        returning: Self.verifyClearAllNotifications(
                            processIdentifier: processIdentifier,
                            cancellation: cancellation
                        )
                    )
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    func isNotificationCenterSurfaceVisible(processIdentifier: pid_t) -> Bool {
        Self.isNotificationCenterSurfaceVisible(processIdentifier: processIdentifier)
    }

    private static func performScan(
        targets: [NotificationAXScanTarget],
        candidates: [NotificationSourceCandidate],
        cancellation: NotificationAXCancellation,
        dismissFingerprints: Set<String>
    ) -> NotificationAXScanResult {
        var items: [NotificationAXItem] = []
        var observedNotificationCenterSurface = false
        var dismissedCount = 0
        var dismissalFailures = 0
        var completedTargetCount = 0
        var reachedLimit = false

        for target in targets {
            guard !cancellation.isCancelled else {
                return NotificationAXScanResult(
                    status: .cancelled,
                    items: items,
                    observedNotificationCenterSurface: observedNotificationCenterSurface,
                    dismissedCount: dismissedCount,
                    dismissalFailures: dismissalFailures
                )
            }

            if target.surface == .notificationCenter,
               !isNotificationCenterSurfaceVisible(
                   processIdentifier: target.processIdentifier
               ) {
                completedTargetCount += 1
                continue
            }

            let application = AXUIElementCreateApplication(target.processIdentifier)
            setMessagingTimeout(on: application)
            var budget = ScanBudget(
                deadlineUptime: ProcessInfo.processInfo.systemUptime + scanDeadline,
                cancellation: cancellation
            )
            guard budget.visit(),
                  let windows = elements(
                      application,
                      attribute: kAXWindowsAttribute
                  ) else {
                reachedLimit = reachedLimit || budget.didReachLimit
                continue
            }

            var targetItems: [NotificationAXItem] = []
            var targetObservedNotificationCenterSurface = false
            var targetDismissedCount = 0
            var targetDismissalFailures = 0
            for window in windows {
                guard !cancellation.isCancelled else { break }
                guard !budget.didReachLimit else { break }
                guard let scanned = scanWindow(
                    window,
                    surface: target.surface,
                    candidates: candidates,
                    budget: &budget
                ) else {
                    continue
                }

                targetItems.append(contentsOf: scanned.items)
                targetObservedNotificationCenterSurface = targetObservedNotificationCenterSurface
                    || scanned.observedNotificationCenterSurface
                guard let bannerElement = scanned.bannerElement,
                      scanned.items.contains(where: {
                          $0.isBanner && dismissFingerprints.contains($0.fingerprint)
                      }) else {
                    continue
                }

                if dismissBanner(bannerElement) {
                    targetDismissedCount += 1
                } else {
                    targetDismissalFailures += 1
                }
            }

            reachedLimit = reachedLimit || budget.didReachLimit
            if !budget.didReachLimit {
                items.append(contentsOf: targetItems)
                observedNotificationCenterSurface = observedNotificationCenterSurface
                    || targetObservedNotificationCenterSurface
                dismissedCount += targetDismissedCount
                dismissalFailures += targetDismissalFailures
                completedTargetCount += 1
            }
        }

        let status: NotificationAXStatus
        if cancellation.isCancelled {
            status = .cancelled
        } else if completedTargetCount > 0 {
            status = .success
        } else if reachedLimit {
            status = .timedOut
        } else {
            status = .unavailable
        }

        return NotificationAXScanResult(
            status: status,
            items: items,
            observedNotificationCenterSurface: observedNotificationCenterSurface,
            dismissedCount: dismissedCount,
            dismissalFailures: dismissalFailures
        )
    }

    private static func performClearAll(
        processIdentifier: pid_t,
        cancellation: NotificationAXCancellation
    ) -> NotificationAXClearResult {
        guard isNotificationCenterSurfaceVisible(processIdentifier: processIdentifier) else {
            return NotificationAXClearResult(status: .unavailable, didPressClear: false)
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        setMessagingTimeout(on: application, timeout: clearActionMessagingTimeout)
        var budget = ScanBudget(
            deadlineUptime: ProcessInfo.processInfo.systemUptime + clearActionDeadline,
            cancellation: cancellation,
            maximumNodeCount: maximumClearActionNodeCount
        )
        var stack: [(AXUIElement, Int)] = [(application, 0)]
        var encounteredUnreadableElement = false

        while let (element, depth) = stack.popLast() {
            guard budget.visit() else { break }
            setMessagingTimeout(on: element, timeout: clearActionMessagingTimeout)

            guard let node = nodeSnapshot(of: element, includeChildren: true) else {
                encounteredUnreadableElement = true
                continue
            }

            if node.role == kAXButtonRole as String {
                if NotificationClearAllLabelDetection.matches(
                    node.textValues.joined(separator: " ")
                ) {
                    var actions: CFArray?
                    guard AXUIElementCopyActionNames(element, &actions) == .success,
                          let actionNames = actions as? [String],
                          actionNames.contains(kAXPressAction as String) else {
                        continue
                    }

                    if AXUIElementPerformAction(
                            element,
                            kAXPressAction as CFString
                        ) == .success {
                        return NotificationAXClearResult(status: .success, didPressClear: true)
                    }
                }
            }

            guard depth < maximumActionDepth else { continue }
            for child in node.children.reversed() {
                stack.append((child, depth + 1))
            }
        }

        let status: NotificationAXStatus
        if cancellation.isCancelled {
            status = .cancelled
        } else if budget.didReachLimit {
            status = .timedOut
        } else if encounteredUnreadableElement {
            status = .unavailable
        } else {
            status = .success
        }
        return NotificationAXClearResult(status: status, didPressClear: false)
    }

    private static func verifyClearAllNotifications(
        processIdentifier: pid_t,
        cancellation: NotificationAXCancellation
    ) -> NotificationAXClearVerification {
        guard isNotificationCenterSurfaceVisible(processIdentifier: processIdentifier) else {
            return .surfaceUnavailable
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        setMessagingTimeout(on: application, timeout: clearActionMessagingTimeout)
        var budget = ScanBudget(
            deadlineUptime: ProcessInfo.processInfo.systemUptime + clearActionDeadline,
            cancellation: cancellation,
            maximumNodeCount: maximumClearActionNodeCount
        )
        guard budget.visit(),
              let windows = elements(application, attribute: kAXWindowsAttribute),
              !windows.isEmpty else {
            return .inconclusive
        }

        var stack = windows.reversed().map { ($0, 0) }
        var encounteredUnreadableElement = false
        while let (element, depth) = stack.popLast() {
            guard budget.visit() else { return .inconclusive }
            setMessagingTimeout(on: element, timeout: clearActionMessagingTimeout)
            guard let node = nodeSnapshot(
                of: element,
                includeChildren: depth < maximumActionDepth
            ) else {
                encounteredUnreadableElement = true
                continue
            }

            if node.role == kAXButtonRole as String,
               NotificationClearAllLabelDetection.matches(
                   node.textValues.joined(separator: " ")
               ) {
                return .clearAllButtonStillVisible
            }

            guard depth < maximumActionDepth else { continue }
            for child in node.children.reversed() {
                stack.append((child, depth + 1))
            }
        }

        guard !cancellation.isCancelled,
              !budget.didReachLimit,
              !encounteredUnreadableElement else {
            return .inconclusive
        }
        return .clearAllButtonNoLongerVisible
    }

    private static func scanWindow(
        _ window: AXUIElement,
        surface: NotificationAXSurface,
        candidates: [NotificationSourceCandidate],
        budget: inout ScanBudget
    ) -> WindowScan? {
        guard budget.visit() else { return nil }
        setMessagingTimeout(on: window)
        guard let node = nodeSnapshot(of: window, includeChildren: true),
              node.role == kAXWindowRole as String,
              booleanValue(window, attribute: kAXHiddenAttribute as String) != true,
              booleanValue(window, attribute: kAXMinimizedAttribute as String) != true,
              let frame = frame(of: window),
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }

        if surface == .bannerHost {
            var texts = node.textValues
            appendNotificationTexts(
                from: node.children,
                maximumDepth: maximumScanDepth,
                into: &texts,
                budget: &budget
            )
            guard let source = NotificationSourceDetection.detect(
                in: texts,
                candidates: candidates
            ) else {
                return nil
            }

            return WindowScan(
                items: [
                    NotificationAXItem(
                        sourceName: source.name,
                        bundleIdentifier: source.bundleIdentifier,
                        fingerprint: "\(source.name)|banner|\(frameKey(frame))|\(textFingerprint(texts))",
                        isBanner: true
                    )
                ],
                bannerElement: window,
                observedNotificationCenterSurface: false
            )
        }

        guard frame.width >= 400,
              frame.height >= 400 else {
            return nil
        }

        var items: [NotificationAXItem] = []
        var fingerprints = Set<String>()
        for child in node.children {
            _ = appendNotificationCards(
                from: child,
                depthRemaining: maximumScanDepth,
                candidates: candidates,
                items: &items,
                fingerprints: &fingerprints,
                budget: &budget
            )
            guard !budget.didReachLimit else { break }
        }
        return WindowScan(
            items: items,
            bannerElement: nil,
            observedNotificationCenterSurface: true
        )
    }

    /// Walks only the visible Notification Center surface on the worker queue.
    /// A source is emitted at its deepest matching AX node so parent groups do
    /// not turn one notification card into several duplicate rows.
    private static func appendNotificationCards(
        from element: AXUIElement,
        depthRemaining: Int,
        candidates: [NotificationSourceCandidate],
        items: inout [NotificationAXItem],
        fingerprints: inout Set<String>,
        budget: inout ScanBudget
    ) -> Set<String> {
        guard depthRemaining >= 0,
              !budget.didReachLimit,
              budget.visit() else { return [] }
        setMessagingTimeout(on: element)
        guard let node = nodeSnapshot(
            of: element,
            includeChildren: depthRemaining > 0
        ) else {
            return []
        }

        guard !node.textValues.contains(where: {
            NotificationSourceDetection.isWidgetOrExtension($0)
        }) else {
            return []
        }

        var descendantSourceKeys = Set<String>()
        if depthRemaining > 0 {
            for child in node.children {
                descendantSourceKeys.formUnion(
                    appendNotificationCards(
                        from: child,
                        depthRemaining: depthRemaining - 1,
                        candidates: candidates,
                        items: &items,
                        fingerprints: &fingerprints,
                        budget: &budget
                    )
                )
                guard !budget.didReachLimit else { break }
            }
        }

        guard let source = NotificationSourceDetection.detectApplication(
            in: node.textValues,
            candidates: candidates
        ) else {
            return descendantSourceKeys
        }

        let sourceKey = source.bundleIdentifier ?? source.name
        let alreadyFoundInDescendant = descendantSourceKeys.contains(sourceKey)
        descendantSourceKeys.insert(sourceKey)
        guard !alreadyFoundInDescendant,
              let itemFrame = frame(of: element),
              itemFrame.width > 0,
              itemFrame.height > 0 else {
            return descendantSourceKeys
        }

        let fingerprint = "\(sourceKey)|card|\(frameKey(itemFrame))"
        guard fingerprints.insert(fingerprint).inserted else {
            return descendantSourceKeys
        }
        items.append(
            NotificationAXItem(
                sourceName: source.name,
                bundleIdentifier: source.bundleIdentifier,
                fingerprint: fingerprint,
                isBanner: false
            )
        )
        return descendantSourceKeys
    }

    private static func frameKey(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)):\(Int(frame.origin.y)):"
            + "\(Int(frame.width)):\(Int(frame.height))"
    }

    /// Keeps notification contents out of retained state while still allowing
    /// two banners from the same app and screen position to be distinguished.
    private static func textFingerprint(_ texts: [String]) -> String {
        let normalized = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func appendNotificationTexts(
        from children: [AXUIElement],
        maximumDepth: Int,
        into texts: inout [String],
        budget: inout ScanBudget
    ) {
        guard maximumDepth > 0 else { return }

        for child in children {
            guard !budget.didReachLimit,
                  budget.visit() else { return }
            setMessagingTimeout(on: child)
            guard let node = nodeSnapshot(
                of: child,
                includeChildren: maximumDepth > 1
            ) else {
                continue
            }

            // Widget containers own their visual descendants. Skipping the
            // whole subtree prevents widgets from becoming notifications.
            guard !node.textValues.contains(where: {
                NotificationSourceDetection.isWidgetOrExtension($0)
            }) else {
                continue
            }

            texts.append(contentsOf: node.textValues)
            appendNotificationTexts(
                from: node.children,
                maximumDepth: maximumDepth - 1,
                into: &texts,
                budget: &budget
            )
        }
    }

    private static func nodeSnapshot(
        of element: AXUIElement,
        includeChildren: Bool
    ) -> NodeSnapshot? {
        var attributes = [
            kAXRoleAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXIdentifierAttribute,
            kAXValueAttribute,
            kAXHelpAttribute
        ] as [String]
        if includeChildren {
            attributes.insert(kAXChildrenAttribute, at: 0)
        }

        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        ) == .success,
        let values = rawValues as? [Any] else {
            return nil
        }

        let children: [AXUIElement]
        let roleIndex: Int
        if includeChildren {
            children = values.first as? [AXUIElement] ?? []
            roleIndex = 1
        } else {
            children = []
            roleIndex = 0
        }

        let role = stringValue(values[safe: roleIndex])
        let textValues = values
            .dropFirst(roleIndex + 1)
            .compactMap(stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return NodeSnapshot(
            role: role,
            textValues: textValues,
            children: children
        )
    }

    private static func elements(
        _ element: AXUIElement,
        attribute: String
    ) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? [AXUIElement] ?? []
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        return nil
    }

    private static func booleanValue(
        _ element: AXUIElement,
        attribute: String
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func setMessagingTimeout(
        on element: AXUIElement,
        timeout: Float = messagingTimeout
    ) {
        _ = AXUIElementSetMessagingTimeout(element, timeout)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func dismissBanner(_ window: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(window, &actions) == .success,
              let actionNames = actions as? [String],
              actionNames.contains(kAXCancelAction as String) else {
            return false
        }
        return AXUIElementPerformAction(
            window,
            kAXCancelAction as CFString
        ) == .success
    }

    private static func isNotificationCenterSurfaceVisible(
        processIdentifier: pid_t
    ) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        return windows.contains { window in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue >= 0 else {
                return false
            }
            return true
        }
    }

    private static func emptyResult(
        status: NotificationAXStatus
    ) -> NotificationAXScanResult {
        NotificationAXScanResult(
            status: status,
            items: [],
            observedNotificationCenterSurface: false,
            dismissedCount: 0,
            dismissalFailures: 0
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
final class NotificationBridge {
    typealias SourcesHandler = @MainActor ([NotificationSource]) -> Void
    typealias NotificationCenterSourcesHandler = @MainActor ([NotificationSource]) -> Void
    typealias PulseHandler = @MainActor (NotificationPulse) -> Void
    typealias HealthHandler = @MainActor (ServiceHealth) -> Void
    typealias AuthorizationRepairHandler = @MainActor () -> Void

    var autoDismissBanners = NotificationBannerPreferences.defaultAutoDismissBanners

    private let onSources: SourcesHandler
    private let onNotificationCenterSources: NotificationCenterSourcesHandler
    private let onPulse: PulseHandler
    private let onHealth: HealthHandler
    private let onAuthorizationRepairSuggested: AuthorizationRepairHandler
    private let notificationScanner = NotificationAXWorker()
    private static let maximumRetainedNotificationCount = 100

    /// Retains only banners observed in real time. The source app activation
    /// observer removes them without reading Notification Center history.
    private var retainedNotificationItems: [NotificationAXItem] = []
    private var previousFingerprints = Set<String>()
    private var hasBaseline = false
    private var accessibilityProbeTask: Task<Void, Never>?
    private var notificationScanTask: Task<Void, Never>?
    private var notificationClearTask: Task<Void, Never>?
    private var notificationDismissTask: Task<Void, Never>?
    private var activatedApplicationObserver: NSObjectProtocol?
    private var pendingScanRequest: NotificationAXScanRequest?
    private var activeScanRequestID: Int?
    private var notificationScanRequestID = 0
    private var stopping = false

    private var sourceCandidatesCache: [NotificationSourceCandidate] = []
    private var sourceCandidatesCacheExpiresAt: TimeInterval = 0
    private var notificationCenterPIDCache: pid_t?
    private var notificationCenterPIDCacheExpiresAt: TimeInterval = 0
    private var bannerHostPIDCache: pid_t?
    private var bannerHostPIDCacheExpiresAt: TimeInterval = 0

    private enum PreferenceKey {
        static let didAutomaticallyRequestAccessibility = "NotificationBridge.didAutomaticallyRequestAccessibility"
    }

    init(
        onSources: @escaping SourcesHandler,
        onNotificationCenterSources: @escaping NotificationCenterSourcesHandler,
        onPulse: @escaping PulseHandler,
        onHealth: @escaping HealthHandler,
        onAuthorizationRepairSuggested: @escaping AuthorizationRepairHandler
    ) {
        self.onSources = onSources
        self.onNotificationCenterSources = onNotificationCenterSources
        self.onPulse = onPulse
        self.onHealth = onHealth
        self.onAuthorizationRepairSuggested = onAuthorizationRepairSuggested
    }

    func start(promptForAccessibility: Bool) {
        stopping = false
        beginObservingActivatedApplications()
        if hasAccessibilityAccess() {
            onHealth(.ready("辅助功能权限已授权"))
        } else if promptForAccessibility,
                  !UserDefaults.standard.bool(forKey: PreferenceKey.didAutomaticallyRequestAccessibility) {
            // Persist before asking so an interrupted prompt cannot turn into a
            // system dialog on every subsequent launch.
            UserDefaults.standard.set(true, forKey: PreferenceKey.didAutomaticallyRequestAccessibility)
            requestAccessibility()
        } else {
            onHealth(.warning("辅助功能权限未授权，或现有授权记录不匹配"))
        }
        refreshNow()
    }

    func stop() {
        stopping = true
        accessibilityProbeTask?.cancel()
        accessibilityProbeTask = nil
        notificationClearTask?.cancel()
        notificationClearTask = nil
        notificationDismissTask?.cancel()
        notificationDismissTask = nil
        stopObservingActivatedApplications()
        cancelNotificationScan()
        retainedNotificationItems.removeAll()
        previousFingerprints.removeAll()
        hasBaseline = false
        onNotificationCenterSources([])
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
            || hasAccessibilityAccess()
        onHealth(
            trusted
                ? .ready("辅助功能权限已授权")
                : .loading("等待系统确认辅助功能权限")
        )
        if trusted {
            refreshNow()
        } else {
            probeAccessibilityAfterRequest()
        }
    }

    func refreshNow() {
        guard hasAccessibilityAccess() else {
            cancelNotificationScan()
            retainedNotificationItems.removeAll()
            previousFingerprints.removeAll()
            hasBaseline = false
            onSources([])
            onNotificationCenterSources([])
            onHealth(.warning("辅助功能权限未授权，或现有授权记录不匹配"))
            return
        }

        let bannerHostProcessIdentifier = cachedBannerHostProcessIdentifier()
        let notificationCenterProcessIdentifier = visibleNotificationCenterProcessIdentifier()
        if notificationCenterProcessIdentifier == nil {
            onNotificationCenterSources([])
        }
        guard bannerHostProcessIdentifier != nil || notificationCenterProcessIdentifier != nil else {
            cancelNotificationScan()
            previousFingerprints.removeAll()
            hasBaseline = false
            onNotificationCenterSources([])
            onHealth(.warning("尚未发现系统通知横幅或通知中心窗口"))
            return
        }

        notificationScanRequestID &+= 1
        let request = NotificationAXScanRequest(
            id: notificationScanRequestID,
            notificationCenterProcessIdentifier: notificationCenterProcessIdentifier,
            bannerHostProcessIdentifier: bannerHostProcessIdentifier,
            scansNotificationCenterSurface: notificationCenterProcessIdentifier != nil,
            candidates: cachedSourceCandidates()
        )

        if notificationScanTask != nil {
            pendingScanRequest = request
            return
        }
        beginNotificationScan(request)
    }

    func openNotificationCenter() {
        guard hasAccessibilityAccess() else {
            requestAccessibility()
            return
        }
        guard visibleNotificationCenterProcessIdentifier() != nil
                || postNotificationCenterShortcut() else {
            onHealth(.warning("无法打开系统通知中心"))
            return
        }

        invalidateNotificationCenterProcessCache()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    private func postNotificationCenterShortcut() -> Bool {
        let keyCodeForN: CGKeyCode = 45
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCodeForN,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCodeForN,
            keyDown: false
        ) else {
            return false
        }
        down.flags = .maskSecondaryFn
        up.flags = .maskSecondaryFn
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func clearAllNotifications() {
        // The overview also retains source-only banner records. A confirmed
        // clear-all action removes those records along with the system items.
        retainedNotificationItems.removeAll()
        onSources([])

        guard hasAccessibilityAccess() else {
            onHealth(.warning("没有辅助功能权限，无法清理通知"))
            return
        }

        notificationClearTask?.cancel()
        let scanner = notificationScanner
        notificationClearTask = Task { @MainActor [weak self, scanner] in
            guard let self else { return }

            var processIdentifier = self.visibleNotificationCenterProcessIdentifier()
            if processIdentifier == nil {
                guard self.postNotificationCenterShortcut() else {
                    self.onHealth(.warning("无法打开系统通知中心"))
                    return
                }
            }

            for _ in 0..<16 where processIdentifier == nil {
                try? await Task.sleep(for: .milliseconds(125))
                guard !Task.isCancelled, !self.stopping else { return }
                self.invalidateNotificationCenterProcessCache()
                processIdentifier = self.visibleNotificationCenterProcessIdentifier()
            }

            guard let processIdentifier else {
                self.onHealth(.warning("系统通知中心未能打开；没有清除本地横幅记录"))
                return
            }

            self.onHealth(.loading("正在请求清理系统通知中心"))
            let result = await scanner.clearAllNotifications(
                processIdentifier: processIdentifier
            )
            guard !Task.isCancelled, !self.stopping else { return }

            guard result.didPressClear else {
                self.finishClearAll(result, verification: nil)
                return
            }

            self.onHealth(.loading("已发送清除请求，正在复查通知中心"))
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, !self.stopping else { return }
            let verification = await scanner.verifyClearAllNotifications(
                processIdentifier: processIdentifier
            )
            guard !Task.isCancelled, !self.stopping else { return }
            self.finishClearAll(result, verification: verification)
        }
    }

    func clearObservedBannerRecords() {
        retainedNotificationItems.removeAll()
        onSources([])
        onHealth(.ready("已清除本次运行的横幅来源记录"))
    }

    private func visibleNotificationCenterProcessIdentifier() -> pid_t? {
        if let processIdentifier = cachedNotificationCenterProcessIdentifier(),
           notificationScanner.isNotificationCenterSurfaceVisible(
               processIdentifier: processIdentifier
           ) {
            return processIdentifier
        }

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        guard let window = windows.first(where: { window in
            guard let ownerName = window[kCGWindowOwnerName as String] as? String else {
                return false
            }
            return NotificationSourceDetection.notificationCenterNames.contains {
                $0.caseInsensitiveCompare(ownerName) == .orderedSame
            }
        }), let processIdentifier = window[kCGWindowOwnerPID as String] as? NSNumber else {
            return nil
        }
        return pid_t(processIdentifier.int32Value)
    }

    private func beginNotificationScan(_ request: NotificationAXScanRequest) {
        guard !stopping else { return }
        let scanner = notificationScanner
        activeScanRequestID = request.id
        notificationScanTask = Task { @MainActor [weak self, scanner] in
            var targets: [NotificationAXScanTarget] = []
            if let bannerHostProcessIdentifier = request.bannerHostProcessIdentifier {
                targets.append(
                    NotificationAXScanTarget(
                        processIdentifier: bannerHostProcessIdentifier,
                        surface: .bannerHost
                    )
                )
            }
            if request.scansNotificationCenterSurface,
               let notificationCenterProcessIdentifier = request.notificationCenterProcessIdentifier {
                targets.append(
                    NotificationAXScanTarget(
                        processIdentifier: notificationCenterProcessIdentifier,
                        surface: .notificationCenter
                    )
                )
            }
            let result = await scanner.scan(
                targets: targets,
                candidates: request.candidates
            )
            guard let self else { return }
            self.finishNotificationScan(request, result: result)
        }
    }

    private func finishNotificationScan(
        _ request: NotificationAXScanRequest,
        result: NotificationAXScanResult
    ) {
        guard activeScanRequestID == request.id else { return }

        notificationScanTask = nil
        activeScanRequestID = nil

        let isLatest = request.id == notificationScanRequestID && !stopping
        if isLatest {
            applyNotificationScanResult(result, request: request)
        }

        let pendingRequest = pendingScanRequest
        pendingScanRequest = nil
        if !stopping, let pendingRequest {
            beginNotificationScan(pendingRequest)
        }
    }

    private func applyNotificationScanResult(
        _ result: NotificationAXScanResult,
        request: NotificationAXScanRequest
    ) {
        switch result.status {
        case .cancelled:
            return
        case .unavailable:
            invalidateNotificationCenterProcessCache()
            onHealth(.warning("通知中心暂时无法响应辅助功能扫描"))
            return
        case .timedOut:
            onHealth(.warning("通知扫描达到时间或节点上限，已保留上次结果"))
            return
        case .success:
            break
        }

        let currentNotificationCenterSources: [NotificationSource]
        if request.scansNotificationCenterSurface,
           result.observedNotificationCenterSurface {
            currentNotificationCenterSources = aggregateSources(
                result.items.filter { !$0.isBanner }
            )
        } else {
            currentNotificationCenterSources = []
        }
        onNotificationCenterSources(currentNotificationCenterSources)

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let scannedBanners = result.items.filter { item in
            item.isBanner && !notificationItem(
                item,
                matchesBundleIdentifier: frontmostApplication?.bundleIdentifier,
                applicationName: frontmostApplication?.localizedName
            )
        }
        retainedNotificationItems.append(
            contentsOf: scannedBanners.filter {
                !hasBaseline || !previousFingerprints.contains($0.fingerprint)
            }
        )
        if retainedNotificationItems.count > Self.maximumRetainedNotificationCount {
            retainedNotificationItems.removeFirst(
                retainedNotificationItems.count - Self.maximumRetainedNotificationCount
            )
        }

        let currentFingerprints = Set(scannedBanners.map(\.fingerprint))
        var newBannerFingerprints = Set<String>()

        if hasBaseline {
            for item in scannedBanners where !previousFingerprints.contains(item.fingerprint) {
                onPulse(
                    NotificationPulse(
                        sourceName: item.sourceName,
                        bundleIdentifier: item.bundleIdentifier
                    )
                )
                if autoDismissBanners {
                    newBannerFingerprints.insert(item.fingerprint)
                }
            }
        } else {
            hasBaseline = true
        }

        previousFingerprints = currentFingerprints
        onSources(aggregateSources(retainedNotificationItems))

        if !newBannerFingerprints.isEmpty {
            if let bannerHostProcessIdentifier = request.bannerHostProcessIdentifier {
                dismissBanners(
                    fingerprints: newBannerFingerprints,
                    processIdentifier: bannerHostProcessIdentifier,
                    candidates: request.candidates
                )
            }
        }

        if retainedNotificationItems.isEmpty {
            onHealth(.ready("通知桥已就绪，当前没有可识别的通知节点"))
        } else {
            onHealth(.ready("通知桥已就绪；已保留 \(retainedNotificationItems.count) 个实时通知"))
        }
    }

    private func dismissBanners(
        fingerprints: Set<String>,
        processIdentifier: pid_t,
        candidates: [NotificationSourceCandidate]
    ) {
        notificationDismissTask?.cancel()
        let scanner = notificationScanner
        notificationDismissTask = Task { @MainActor [weak self, scanner] in
            let result = await scanner.dismissBanners(
                processIdentifier: processIdentifier,
                candidates: candidates,
                fingerprints: fingerprints
            )
            guard let self, !Task.isCancelled, !self.stopping else { return }
            self.notificationDismissTask = nil
            guard result.status == .success else { return }

            if result.dismissedCount > 0 {
                self.onHealth(.ready("已安全请求收起 \(result.dismissedCount) 个原生横幅"))
            } else if result.dismissalFailures > 0 {
                self.onHealth(.warning("检测到横幅，但系统拒绝了收起操作"))
            }
        }
    }

    private func finishClearAll(
        _ result: NotificationAXClearResult,
        verification: NotificationAXClearVerification?
    ) {
        defer { scheduleNotificationCenterRefreshAfterClear() }
        notificationClearTask = nil
        switch result.status {
        case .cancelled:
            return
        case .unavailable:
            invalidateNotificationCenterProcessCache()
            onHealth(.warning("通知中心暂时无法响应清除请求"))
        case .timedOut:
            onHealth(.warning("清除通知扫描达到时间或节点上限"))
        case .success:
            guard result.didPressClear else {
                onHealth(.warning("未找到可执行的系统“全部清除”按钮；本地横幅记录已保留"))
                return
            }

            guard let verification else {
                onHealth(.warning("系统已接受清除请求，但无法复查结果；本地横幅记录已保留"))
                return
            }

            guard verification == .clearAllButtonNoLongerVisible else {
                switch verification {
                case .clearAllButtonStillVisible:
                    onHealth(.warning("清除请求后“全部清除”仍可见；本地横幅记录已保留"))
                case .surfaceUnavailable:
                    onHealth(.warning("通知中心已关闭，无法复查清除结果；本地横幅记录已保留"))
                case .inconclusive:
                    onHealth(.warning("无法完整复查通知中心；本地横幅记录已保留"))
                case .clearAllButtonNoLongerVisible:
                    break
                }
                return
            }

            onHealth(.ready("清除请求已执行；通知中心未再显示“全部清除”按钮"))
        }
    }

    private func scheduleNotificationCenterRefreshAfterClear() {
        guard visibleNotificationCenterProcessIdentifier() != nil else {
            onNotificationCenterSources([])
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !self.stopping else { return }
            self.refreshNow()
        }
    }

    private func beginObservingActivatedApplications() {
        guard activatedApplicationObserver == nil else { return }
        activatedApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                return
            }
            let bundleIdentifier = application.bundleIdentifier
            let applicationName = application.localizedName
            Task { @MainActor [weak self] in
                self?.removeRetainedNotifications(
                    bundleIdentifier: bundleIdentifier,
                    applicationName: applicationName
                )
            }
        }
    }

    private func stopObservingActivatedApplications() {
        guard let activatedApplicationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(
            activatedApplicationObserver
        )
        self.activatedApplicationObserver = nil
    }

    private func removeRetainedNotifications(
        bundleIdentifier: String?,
        applicationName: String?
    ) {
        let previousCount = retainedNotificationItems.count
        retainedNotificationItems.removeAll { item in
            notificationItem(
                item,
                matchesBundleIdentifier: bundleIdentifier,
                applicationName: applicationName
            )
        }
        guard retainedNotificationItems.count != previousCount else { return }
        onSources(aggregateSources(retainedNotificationItems))
        if retainedNotificationItems.isEmpty {
            onHealth(.ready("通知桥已就绪，当前没有未处理的实时通知"))
        }
    }

    private func notificationItem(
        _ item: NotificationAXItem,
        matchesBundleIdentifier bundleIdentifier: String?,
        applicationName: String?
    ) -> Bool {
        if let bundleIdentifier,
           let itemBundleIdentifier = item.bundleIdentifier,
           itemBundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame {
            return true
        }
        guard let applicationName else { return false }
        return item.sourceName.caseInsensitiveCompare(applicationName) == .orderedSame
    }

    private func cancelNotificationScan() {
        notificationScanRequestID &+= 1
        notificationScanTask?.cancel()
        notificationScanTask = nil
        activeScanRequestID = nil
        pendingScanRequest = nil
    }

    private func cachedSourceCandidates() -> [NotificationSourceCandidate] {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= sourceCandidatesCacheExpiresAt else {
            return sourceCandidatesCache
        }

        sourceCandidatesCache = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName,
                  !name.isEmpty else {
                return nil
            }
            let candidate = NotificationSourceCandidate(
                name: name,
                bundleIdentifier: app.bundleIdentifier
            )
            return NotificationSourceDetection.isNotificationCenter(candidate)
                ? nil
                : candidate
        }
        sourceCandidatesCacheExpiresAt = now + 30
        return sourceCandidatesCache
    }

    private func cachedNotificationCenterProcessIdentifier() -> pid_t? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= notificationCenterPIDCacheExpiresAt else {
            return notificationCenterPIDCache
        }

        notificationCenterPIDCache = NSWorkspace.shared.runningApplications.first { app in
            if app.bundleIdentifier == NotificationSourceDetection.notificationCenterBundleIdentifier {
                return true
            }
            guard let localizedName = app.localizedName else { return false }
            return NotificationSourceDetection.notificationCenterNames.contains {
                $0.caseInsensitiveCompare(localizedName) == .orderedSame
            }
        }?.processIdentifier
        notificationCenterPIDCacheExpiresAt = now + 5
        return notificationCenterPIDCache
    }

    private func cachedBannerHostProcessIdentifier() -> pid_t? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= bannerHostPIDCacheExpiresAt else {
            return bannerHostPIDCache
        }

        bannerHostPIDCache = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == NotificationSourceDetection.bannerHostBundleIdentifier
        }?.processIdentifier
        bannerHostPIDCacheExpiresAt = now + 5
        return bannerHostPIDCache
    }

    private func invalidateNotificationCenterProcessCache() {
        notificationCenterPIDCache = nil
        notificationCenterPIDCacheExpiresAt = 0
    }

    private func aggregateSources(
        _ scanned: [NotificationAXItem]
    ) -> [NotificationSource] {
        let grouped = Dictionary(grouping: scanned) {
            $0.bundleIdentifier ?? $0.sourceName
        }

        return grouped.values.compactMap { items in
            guard let first = items.first else { return nil }
            return NotificationSource(
                sourceName: first.sourceName,
                bundleIdentifier: first.bundleIdentifier,
                count: items.count
            )
        }
        .sorted {
            if $0.count == $1.count {
                return $0.sourceName < $1.sourceName
            }
            return $0.count > $1.count
        }
    }

    private func probeAccessibilityAfterRequest() {
        accessibilityProbeTask?.cancel()
        accessibilityProbeTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if self.hasAccessibilityAccess() {
                    self.onHealth(.ready("辅助功能权限已授权"))
                    self.refreshNow()
                    return
                }
            }

            self.onHealth(
                .warning(
                    "系统仍未授权；若开关已开启，请使用“修复权限”重新授权"
                )
            )
            self.onAuthorizationRepairSuggested()
        }
    }

    nonisolated static func resetSystemAccessibilityAuthorization(
        bundleIdentifier: String
    ) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleIdentifier]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)
                ?? String(data: outputData, encoding: .utf8)
                ?? "tccutil 返回未知错误"
            return detail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func hasAccessibilityAccess() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        guard let processIdentifier = cachedNotificationCenterProcessIdentifier() else {
            return false
        }
        let appElement = AXUIElementCreateApplication(
            processIdentifier
        )
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            appElement,
            kAXRoleAttribute as CFString,
            &role
        ) == .success
    }

}
