import AppKit
import ApplicationServices
import Foundation

struct NotificationSourceCandidate: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
}

enum NotificationSourceDetection {
    static let knownSources = [
        NotificationSourceCandidate(name: "Codex", bundleIdentifier: "com.openai.chat"),
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
        let values = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let allCandidates = candidates + knownSources

        for candidate in uniqueCandidates(allCandidates).sorted(by: { $0.name.count > $1.name.count }) {
            guard !isWidgetOrExtension(candidate) else { continue }
            let markers = [candidate.name, candidate.bundleIdentifier]
                .compactMap { $0 }
            if values.contains(where: { value in
                markers.contains(where: { value.localizedCaseInsensitiveContains($0) })
            }) {
                return candidate
            }
        }

        if containsNotificationMarker(in: values) {
            return NotificationSourceCandidate(name: "系统通知", bundleIdentifier: nil)
        }

        return nil
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
    let dismissedCount: Int
    let dismissalFailures: Int
}

private struct NotificationAXClearResult: Sendable {
    let status: NotificationAXStatus
    let didPressClear: Bool
}

private struct NotificationAXScanRequest: Sendable {
    let id: Int
    let processIdentifier: pid_t
    let candidates: [NotificationSourceCandidate]
}

private final class NotificationAXWorker: @unchecked Sendable {
    private static let maximumScanDepth = 5
    private static let maximumActionDepth = 8
    private static let maximumNodeCount = 256
    private static let messagingTimeout: Float = 0.2
    private static let scanDeadline: TimeInterval = 1.5

    private struct NodeSnapshot {
        let role: String?
        let textValues: [String]
        let children: [AXUIElement]
    }

    private struct ScanBudget {
        let deadlineUptime: TimeInterval
        let cancellation: NotificationAXCancellation
        var visitedNodeCount = 0
        var didReachLimit = false

        mutating func visit() -> Bool {
            guard !cancellation.isCancelled else { return false }
            guard ProcessInfo.processInfo.systemUptime < deadlineUptime,
                  visitedNodeCount < NotificationAXWorker.maximumNodeCount else {
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
        processIdentifier: pid_t,
        candidates: [NotificationSourceCandidate]
    ) async -> NotificationAXScanResult {
        let cancellation = NotificationAXCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(
                        returning: Self.performScan(
                            processIdentifier: processIdentifier,
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
                            processIdentifier: processIdentifier,
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

    private static func performScan(
        processIdentifier: pid_t,
        candidates: [NotificationSourceCandidate],
        cancellation: NotificationAXCancellation,
        dismissFingerprints: Set<String>
    ) -> NotificationAXScanResult {
        let application = AXUIElementCreateApplication(processIdentifier)
        setMessagingTimeout(on: application)
        var budget = ScanBudget(
            deadlineUptime: ProcessInfo.processInfo.systemUptime + scanDeadline,
            cancellation: cancellation
        )

        guard budget.visit() else {
            return emptyResult(
                status: cancellation.isCancelled ? .cancelled : .timedOut
            )
        }
        guard let windows = elements(
            application,
            attribute: kAXWindowsAttribute
        ) else {
            return emptyResult(
                status: cancellation.isCancelled ? .cancelled : .unavailable
            )
        }

        var items: [NotificationAXItem] = []
        var dismissedCount = 0
        var dismissalFailures = 0

        for window in windows {
            guard !cancellation.isCancelled else {
                return NotificationAXScanResult(
                    status: .cancelled,
                    items: items,
                    dismissedCount: dismissedCount,
                    dismissalFailures: dismissalFailures
                )
            }
            guard !budget.didReachLimit else { break }
            guard let scanned = scanWindow(
                window,
                candidates: candidates,
                budget: &budget
            ) else {
                continue
            }

            items.append(scanned.item)
            guard dismissFingerprints.contains(scanned.item.fingerprint),
                  scanned.item.isBanner else {
                continue
            }

            if dismissBanner(scanned.element) {
                dismissedCount += 1
            } else {
                dismissalFailures += 1
            }
        }

        let status: NotificationAXStatus
        if cancellation.isCancelled {
            status = .cancelled
        } else if budget.didReachLimit {
            status = .timedOut
        } else {
            status = .success
        }

        return NotificationAXScanResult(
            status: status,
            items: items,
            dismissedCount: dismissedCount,
            dismissalFailures: dismissalFailures
        )
    }

    private static func performClearAll(
        processIdentifier: pid_t,
        cancellation: NotificationAXCancellation
    ) -> NotificationAXClearResult {
        let application = AXUIElementCreateApplication(processIdentifier)
        setMessagingTimeout(on: application)
        var budget = ScanBudget(
            deadlineUptime: ProcessInfo.processInfo.systemUptime + scanDeadline,
            cancellation: cancellation
        )
        var stack: [(AXUIElement, Int)] = [(application, 0)]

        while let (element, depth) = stack.popLast() {
            guard budget.visit() else { break }
            setMessagingTimeout(on: element)

            guard let node = nodeSnapshot(of: element, includeChildren: true) else {
                continue
            }

            if node.role == kAXButtonRole as String {
                let label = node.textValues.joined(separator: " ").lowercased()
                let clearLabels = ["clear all", "全部清除", "清除全部"]
                if clearLabels.contains(where: { label.contains($0) }) {
                    var actions: CFArray?
                    guard AXUIElementCopyActionNames(element, &actions) == .success,
                          let actionNames = actions as? [String],
                          actionNames.contains(kAXPressAction as String) else {
                        return NotificationAXClearResult(
                            status: .success,
                            didPressClear: false
                        )
                    }

                    return NotificationAXClearResult(
                        status: .success,
                        didPressClear: AXUIElementPerformAction(
                            element,
                            kAXPressAction as CFString
                        ) == .success
                    )
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
        } else {
            status = .success
        }
        return NotificationAXClearResult(status: status, didPressClear: false)
    }

    private static func scanWindow(
        _ window: AXUIElement,
        candidates: [NotificationSourceCandidate],
        budget: inout ScanBudget
    ) -> (item: NotificationAXItem, element: AXUIElement)? {
        guard budget.visit() else { return nil }
        setMessagingTimeout(on: window)
        guard let node = nodeSnapshot(of: window, includeChildren: true),
              node.role == kAXWindowRole as String,
              let frame = frame(of: window),
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }

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

        let frameKey = "\(Int(frame.origin.x)):\(Int(frame.origin.y)):"
            + "\(Int(frame.width)):\(Int(frame.height))"
        let fingerprint = "\(source.name)|window|\(frameKey)"
        return (
            NotificationAXItem(
                sourceName: source.name,
                bundleIdentifier: source.bundleIdentifier,
                fingerprint: fingerprint,
                isBanner: isBannerFrame(frame)
            ),
            window
        )
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

    private static func setMessagingTimeout(on element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
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

    private static func isBannerFrame(_ frame: CGRect) -> Bool {
        frame.width >= 220
            && frame.width <= 520
            && frame.height > 40
            && frame.height < 320
            && frame.origin.y < 260
    }

    private static func emptyResult(
        status: NotificationAXStatus
    ) -> NotificationAXScanResult {
        NotificationAXScanResult(
            status: status,
            items: [],
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
    typealias PulseHandler = @MainActor (NotificationPulse) -> Void
    typealias HealthHandler = @MainActor (ServiceHealth) -> Void
    typealias AuthorizationRepairHandler = @MainActor () -> Void

    var autoDismissBanners = true

    private let onSources: SourcesHandler
    private let onPulse: PulseHandler
    private let onHealth: HealthHandler
    private let onAuthorizationRepairSuggested: AuthorizationRepairHandler
    private let notificationScanner = NotificationAXWorker()

    private var previousFingerprints = Set<String>()
    private var hasBaseline = false
    private var accessibilityProbeTask: Task<Void, Never>?
    private var notificationScanTask: Task<Void, Never>?
    private var notificationActionTask: Task<Void, Never>?
    private var pendingScanRequest: NotificationAXScanRequest?
    private var activeScanRequestID: Int?
    private var notificationScanRequestID = 0
    private var stopping = false

    private var sourceCandidatesCache: [NotificationSourceCandidate] = []
    private var sourceCandidatesCacheExpiresAt: TimeInterval = 0
    private var notificationCenterPIDCache: pid_t?
    private var notificationCenterPIDCacheExpiresAt: TimeInterval = 0

    private enum PreferenceKey {
        static let didAutomaticallyRequestAccessibility = "NotificationBridge.didAutomaticallyRequestAccessibility"
    }

    init(
        onSources: @escaping SourcesHandler,
        onPulse: @escaping PulseHandler,
        onHealth: @escaping HealthHandler,
        onAuthorizationRepairSuggested: @escaping AuthorizationRepairHandler
    ) {
        self.onSources = onSources
        self.onPulse = onPulse
        self.onHealth = onHealth
        self.onAuthorizationRepairSuggested = onAuthorizationRepairSuggested
    }

    func start(promptForAccessibility: Bool) {
        stopping = false
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
        notificationActionTask?.cancel()
        notificationActionTask = nil
        cancelNotificationScan()
        previousFingerprints.removeAll()
        hasBaseline = false
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
            previousFingerprints.removeAll()
            hasBaseline = false
            onSources([])
            onHealth(.warning("辅助功能权限未授权，或现有授权记录不匹配"))
            return
        }

        guard let processIdentifier = cachedNotificationCenterProcessIdentifier() else {
            cancelNotificationScan()
            onHealth(.warning("尚未发现系统通知中心进程"))
            onSources([])
            return
        }

        notificationScanRequestID &+= 1
        let request = NotificationAXScanRequest(
            id: notificationScanRequestID,
            processIdentifier: processIdentifier,
            candidates: cachedSourceCandidates()
        )

        if notificationScanTask != nil {
            pendingScanRequest = request
            notificationScanTask?.cancel()
            return
        }
        beginNotificationScan(request)
    }

    func openNotificationCenter() {
        guard hasAccessibilityAccess() else {
            requestAccessibility()
            return
        }

        let keyCodeForN: CGKeyCode = 45
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForN, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForN, keyDown: false)
        down?.flags = .maskSecondaryFn
        up?.flags = .maskSecondaryFn
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    func clearAllNotifications() {
        guard hasAccessibilityAccess(),
              let processIdentifier = cachedNotificationCenterProcessIdentifier() else {
            onHealth(.warning("没有辅助功能权限，无法清理通知"))
            return
        }

        openNotificationCenter()
        notificationActionTask?.cancel()
        let scanner = notificationScanner
        notificationActionTask = Task { @MainActor [weak self, scanner] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            let result = await scanner.clearAllNotifications(
                processIdentifier: processIdentifier
            )
            guard let self, !Task.isCancelled, !self.stopping else { return }
            self.finishClearAll(result)
        }
    }

    private func beginNotificationScan(_ request: NotificationAXScanRequest) {
        guard !stopping else { return }
        let scanner = notificationScanner
        activeScanRequestID = request.id
        notificationScanTask = Task { @MainActor [weak self, scanner] in
            let result = await scanner.scan(
                processIdentifier: request.processIdentifier,
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

        let scanned = result.items
        let currentFingerprints = Set(scanned.map(\.fingerprint))
        var newBannerFingerprints = Set<String>()

        if hasBaseline {
            for item in scanned where !previousFingerprints.contains(item.fingerprint) {
                onPulse(
                    NotificationPulse(
                        sourceName: item.sourceName,
                        bundleIdentifier: item.bundleIdentifier
                    )
                )
                if autoDismissBanners, item.isBanner {
                    newBannerFingerprints.insert(item.fingerprint)
                }
            }
        } else {
            hasBaseline = true
        }

        previousFingerprints = currentFingerprints
        onSources(aggregateSources(scanned))

        if !newBannerFingerprints.isEmpty {
            dismissBanners(
                fingerprints: newBannerFingerprints,
                request: request
            )
        }

        if scanned.isEmpty {
            onHealth(.ready("通知桥已就绪，当前没有可识别的通知节点"))
        } else {
            onHealth(.ready("辅助功能权限有效；已镜像 \(scanned.count) 个系统通知节点"))
        }
    }

    private func dismissBanners(
        fingerprints: Set<String>,
        request: NotificationAXScanRequest
    ) {
        notificationActionTask?.cancel()
        let scanner = notificationScanner
        notificationActionTask = Task { @MainActor [weak self, scanner] in
            let result = await scanner.dismissBanners(
                processIdentifier: request.processIdentifier,
                candidates: request.candidates,
                fingerprints: fingerprints
            )
            guard let self, !Task.isCancelled, !self.stopping else { return }
            guard result.status == .success else { return }

            if result.dismissedCount > 0 {
                self.onHealth(.ready("已安全请求收起 \(result.dismissedCount) 个原生横幅"))
            } else if result.dismissalFailures > 0 {
                self.onHealth(.warning("检测到横幅，但系统拒绝了收起操作"))
            }
        }
    }

    private func finishClearAll(_ result: NotificationAXClearResult) {
        notificationActionTask = nil
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
                onHealth(.warning("未找到系统“全部清除”按钮"))
                refreshNow()
                return
            }

            onHealth(.ready("已请求系统通知中心清除全部"))
            previousFingerprints.removeAll()
            hasBaseline = false
            onSources([])
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                self?.refreshNow()
            }
        }
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

        sourceCandidatesCache = NSWorkspace.shared.runningApplications.compactMap {
            app -> NotificationSourceCandidate? in
            guard let name = app.localizedName,
                  name != "NotificationCenter",
                  !name.isEmpty else {
                return nil
            }
            return NotificationSourceCandidate(
                name: name,
                bundleIdentifier: app.bundleIdentifier
            )
        }
        sourceCandidatesCacheExpiresAt = now + 30
        return sourceCandidatesCache
    }

    private func cachedNotificationCenterProcessIdentifier() -> pid_t? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= notificationCenterPIDCacheExpiresAt else {
            return notificationCenterPIDCache
        }

        notificationCenterPIDCache = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
                || $0.localizedName == "NotificationCenter"
        }?.processIdentifier
        notificationCenterPIDCacheExpiresAt = now + 5
        return notificationCenterPIDCache
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
