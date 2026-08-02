import AppKit
import ApplicationServices
import Foundation

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

    private var previousFingerprints = Set<String>()
    private var hasBaseline = false
    private var accessibilityProbeTask: Task<Void, Never>?

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
        accessibilityProbeTask?.cancel()
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
            onHealth(.warning("辅助功能权限未授权，或现有授权记录不匹配"))
            return
        }

        guard let notificationCenter = notificationCenterApplication() else {
            onHealth(.warning("尚未发现系统通知中心进程"))
            onSources([])
            return
        }

        let appElement = AXUIElementCreateApplication(notificationCenter.processIdentifier)
        let windows = elements(appElement, attribute: kAXWindowsAttribute)
        let scanned = windows.compactMap(scanWindow)
        let currentFingerprints = Set(scanned.map { $0.fingerprint })

        if hasBaseline {
            for item in scanned where !previousFingerprints.contains(item.fingerprint) {
                onPulse(
                    NotificationPulse(
                        sourceName: item.sourceName,
                        bundleIdentifier: item.bundleIdentifier
                    )
                )

                if autoDismissBanners, item.isBanner {
                    safelyDismissBanner(item.element)
                }
            }
        } else {
            hasBaseline = true
        }

        previousFingerprints = currentFingerprints
        onSources(aggregateSources(scanned))

        if windows.isEmpty {
            onHealth(.ready("通知桥已就绪，当前没有可见通知节点"))
        } else {
            onHealth(.ready("辅助功能权限有效；已镜像 \(windows.count) 个系统通知节点"))
        }
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

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.refreshNow()
        }
    }

    func clearAllNotifications() {
        guard hasAccessibilityAccess(),
              let app = notificationCenterApplication() else {
            onHealth(.warning("没有辅助功能权限，无法清理通知"))
            return
        }

        openNotificationCenter()

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self else { return }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let buttons = self.descendants(of: appElement, maximumDepth: 8)
                .filter { self.string($0, attribute: kAXRoleAttribute) == kAXButtonRole as String }

            let clearLabels = ["clear all", "全部清除", "清除全部"]
            if let clearButton = buttons.first(where: { button in
                let label = [
                    self.string(button, attribute: kAXTitleAttribute),
                    self.string(button, attribute: kAXDescriptionAttribute),
                    self.string(button, attribute: kAXIdentifierAttribute)
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                return clearLabels.contains { label.contains($0) }
            }) {
                let result = AXUIElementPerformAction(clearButton, kAXPressAction as CFString)
                self.onHealth(
                    result == .success
                        ? .ready("已请求系统通知中心清除全部")
                        : .warning("系统拒绝了清除全部操作")
                )
            } else {
                self.onHealth(.warning("未找到系统“全部清除”按钮"))
            }
            self.refreshNow()
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

        guard let notificationCenter = notificationCenterApplication() else {
            return false
        }
        let appElement = AXUIElementCreateApplication(
            notificationCenter.processIdentifier
        )
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            appElement,
            kAXRoleAttribute as CFString,
            &role
        ) == .success
    }

    private struct ScannedNotification {
        let element: AXUIElement
        let sourceName: String
        let bundleIdentifier: String?
        let fingerprint: String
        let isBanner: Bool
    }

    private func scanWindow(_ window: AXUIElement) -> ScannedNotification? {
        let texts = descendants(of: window, maximumDepth: 5)
            .flatMap { element -> [String] in
                [
                    string(element, attribute: kAXTitleAttribute),
                    string(element, attribute: kAXDescriptionAttribute),
                    string(element, attribute: kAXIdentifierAttribute)
                ].compactMap { $0 }
            }

        let source = detectSource(in: texts)
        let frame = frame(of: window)
        let frameKey = frame.map {
            "\(Int($0.origin.x)):\(Int($0.origin.y)):\(Int($0.width)):\(Int($0.height))"
        } ?? "unknown"
        let role = string(window, attribute: kAXRoleAttribute) ?? "window"
        let fingerprint = "\(source.name)|\(role)|\(frameKey)"

        return ScannedNotification(
            element: window,
            sourceName: source.name,
            bundleIdentifier: source.bundleIdentifier,
            fingerprint: fingerprint,
            isBanner: isBannerFrame(frame)
        )
    }

    private func detectSource(in texts: [String]) -> (name: String, bundleIdentifier: String?) {
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> (String, String?)? in
            guard let name = app.localizedName,
                  name != "NotificationCenter",
                  !name.isEmpty else {
                return nil
            }
            return (name, app.bundleIdentifier)
        }

        for candidate in candidates.sorted(by: { $0.0.count > $1.0.count }) {
            if texts.contains(where: {
                $0.localizedCaseInsensitiveContains(candidate.0)
            }) {
                return candidate
            }
        }

        let knownSources: [(String, String?)] = [
            ("Codex", "com.openai.chat"),
            ("ChatGPT", "com.openai.chat"),
            ("微信", "com.tencent.xinWeChat"),
            ("钉钉", nil),
            ("QQ邮箱", nil),
            ("日历", "com.apple.iCal"),
            ("提醒事项", "com.apple.reminders")
        ]

        for source in knownSources where texts.contains(where: {
            $0.localizedCaseInsensitiveContains(source.0)
        }) {
            return source
        }

        return ("系统通知", nil)
    }

    private func safelyDismissBanner(_ window: AXUIElement) {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(window, &actions) == .success,
              let actionNames = actions as? [String],
              actionNames.contains(kAXCancelAction as String) else {
            onHealth(.warning("检测到横幅，但系统没有提供可确认安全的收起动作"))
            return
        }

        let result = AXUIElementPerformAction(window, kAXCancelAction as CFString)
        onHealth(
            result == .success
                ? .ready("已安全请求收起原生横幅")
                : .warning("系统拒绝收起横幅，已保留原生通知")
        )
    }

    private func aggregateSources(_ scanned: [ScannedNotification]) -> [NotificationSource] {
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

    private func notificationCenterApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
                || $0.localizedName == "NotificationCenter"
        }
    }

    private func isBannerFrame(_ frame: CGRect?) -> Bool {
        guard let frame else { return false }
        return frame.width >= 220
            && frame.width <= 520
            && frame.height > 40
            && frame.height < 320
            && frame.origin.y < 260
    }

    private func descendants(
        of root: AXUIElement,
        maximumDepth: Int
    ) -> [AXUIElement] {
        guard maximumDepth > 0 else { return [] }
        let children = elements(root, attribute: kAXChildrenAttribute)
        return children + children.flatMap {
            descendants(of: $0, maximumDepth: maximumDepth - 1)
        }
    }

    private func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private func string(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
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
}
