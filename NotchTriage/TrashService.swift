import AppKit
import CoreServices
import Foundation

@MainActor
final class TrashService {
    typealias CountHandler = @MainActor (Int?) -> Void
    typealias HealthHandler = @MainActor (ServiceHealth) -> Void

    private let onCount: CountHandler
    private let onHealth: HealthHandler

    init(
        onCount: @escaping CountHandler,
        onHealth: @escaping HealthHandler
    ) {
        self.onCount = onCount
        self.onHealth = onHealth
    }

    func start() {
        refresh()
    }

    func stop() {}

    func refresh() {
        if let count = finderTrashCountIfAlreadyAuthorized() {
            onCount(count)
            return
        }

        guard let url = trashURL() else {
            onCount(nil)
            onHealth(.warning("无法定位用户废纸篓"))
            return
        }

        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
            onCount(items.count)
        } catch {
            onCount(nil)
            onHealth(.warning("废纸篓计数不可用，仍可直接清空"))
        }
    }

    func openTrash() {
        guard let url = trashURL() else { return }
        NSWorkspace.shared.open(url)
    }

    func emptyTrash() -> String? {
        let permissionStatus = finderAutomationPermission(askUserIfNeeded: true)
        guard permissionStatus == noErr else {
            let message: String
            if permissionStatus == OSStatus(errAEEventNotPermitted) {
                message = "请在“系统设置 → 隐私与安全性 → 自动化”中允许 Notch Triage 控制 Finder，然后重试。"
            } else {
                message = "Finder 自动化权限不可用（错误 \(permissionStatus)）。"
            }
            onHealth(.failed(message))
            return message
        }

        var error: NSDictionary?
        let script = NSAppleScript(source: """
        tell application "Finder"
            empty trash
        end tell
        """)
        script?.executeAndReturnError(&error)

        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            let detail = error[NSAppleScript.errorMessage] as? String
                ?? error.description
            let message = code == Int(errAEEventNotPermitted)
                ? "Finder 拒绝了清空请求。请在“系统设置 → 隐私与安全性 → 自动化”中允许 Notch Triage 控制 Finder。"
                : "Finder 未能清空废纸篓：\(detail)"
            onHealth(.failed(message))
            return message
        } else {
            onHealth(.ready("已请求 Finder 清空废纸篓"))
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.refresh()
        }
        return nil
    }

    private func trashURL() -> URL? {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
    }

    private func finderTrashCountIfAlreadyAuthorized() -> Int? {
        guard finderAutomationPermission(askUserIfNeeded: false) == noErr else {
            return nil
        }

        var error: NSDictionary?
        let script = NSAppleScript(source: """
        tell application "Finder"
            count every item of trash
        end tell
        """)
        guard let result = script?.executeAndReturnError(&error), error == nil else {
            return nil
        }
        return max(0, Int(result.int32Value))
    }

    private func finderAutomationPermission(askUserIfNeeded: Bool) -> OSStatus {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let target = finder.aeDesc else {
            return OSStatus(errAEEventNotPermitted)
        }
        return AEDeterminePermissionToAutomateTarget(
            target,
            typeWildCard,
            typeWildCard,
            askUserIfNeeded
        )
    }
}
