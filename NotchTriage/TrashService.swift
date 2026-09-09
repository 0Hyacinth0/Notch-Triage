import AppKit
import CoreServices
import Foundation

@MainActor
final class TrashService {
    typealias CountHandler = @MainActor (Int?) -> Void
    typealias HealthHandler = @MainActor (ServiceHealth) -> Void
    typealias ErrorHandler = @MainActor (String) -> Void

    private let onCount: CountHandler
    private let onHealth: HealthHandler
    private let onError: ErrorHandler
    private var refreshGeneration: UInt64 = 0

    init(
        onCount: @escaping CountHandler,
        onHealth: @escaping HealthHandler,
        onError: @escaping ErrorHandler
    ) {
        self.onCount = onCount
        self.onHealth = onHealth
        self.onError = onError
    }

    func start() {
        refresh()
    }

    func stop() {
        refreshGeneration &+= 1
    }

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let url = Self.trashURL() else {
            onCount(nil)
            onHealth(.warning("无法定位用户废纸篓"))
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let count = Self.finderTrashCountIfAlreadyAuthorized()
                ?? Self.localTrashCount(at: url)
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                if let count {
                    self.onCount(count)
                } else {
                    self.onCount(nil)
                    self.onHealth(.warning("废纸篓计数不可用，仍可直接清空"))
                }
            }
        }
    }

    func openTrash() {
        guard let url = Self.trashURL() else { return }
        NSWorkspace.shared.open(url)
    }

    func emptyTrash() {
        let permissionStatus = Self.finderAutomationPermission(askUserIfNeeded: true)
        guard permissionStatus == noErr else {
            let message: String
            if permissionStatus == OSStatus(errAEEventNotPermitted) {
                message = "请在“系统设置 → 隐私与安全性 → 自动化”中允许 Notch Triage 控制 Finder，然后重试。"
            } else {
                message = "Finder 自动化权限不可用（错误 \(permissionStatus)）。"
            }
            onHealth(.failed(message))
            onError(message)
            return
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.executeEmptyTrash()
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation else { return }
                switch result {
                case .success:
                    self.onHealth(.ready("已请求 Finder 清空废纸篓"))
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        self?.refresh()
                    }
                case .failure(let message):
                    self.onHealth(.failed(message))
                    self.onError(message)
                }
            }
        }
    }

    private nonisolated static func trashURL() -> URL? {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
    }

    private nonisolated static func localTrashCount(at url: URL) -> Int? {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).count
        } catch {
            return nil
        }
    }

    private nonisolated static func finderTrashCountIfAlreadyAuthorized() -> Int? {
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

    private nonisolated static func executeEmptyTrash() -> TrashOperationResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: """
        tell application "Finder"
            empty trash
        end tell
        """) else {
            return .failure("无法创建 Finder 清空脚本")
        }
        _ = script.executeAndReturnError(&error)

        guard let error else { return .success }
        let code = error[NSAppleScript.errorNumber] as? Int
        let detail = error[NSAppleScript.errorMessage] as? String
            ?? error.description
        let message = code == Int(errAEEventNotPermitted)
            ? "Finder 拒绝了清空请求。请在“系统设置 → 隐私与安全性 → 自动化”中允许 Notch Triage 控制 Finder。"
            : "Finder 未能清空废纸篓：\(detail)"
        return .failure(message)
    }

    private nonisolated static func finderAutomationPermission(
        askUserIfNeeded: Bool
    ) -> OSStatus {
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

private enum TrashOperationResult: Sendable {
    case success
    case failure(String)
}
