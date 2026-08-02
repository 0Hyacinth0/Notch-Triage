import AppKit
import CoreServices
import Foundation

@MainActor
final class TrashService {
    typealias CountHandler = @MainActor (Int?) -> Void
    typealias HealthHandler = @MainActor (ServiceHealth) -> Void

    private let onCount: CountHandler
    private let onHealth: HealthHandler
    private var timer: Timer?

    init(
        onCount: @escaping CountHandler,
        onHealth: @escaping HealthHandler
    ) {
        self.onCount = onCount
        self.onHealth = onHealth
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

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

    func emptyTrash() {
        var error: NSDictionary?
        let script = NSAppleScript(source: """
        tell application "Finder"
            empty trash
        end tell
        """)
        script?.executeAndReturnError(&error)

        if let error {
            onHealth(.failed("清空废纸篓失败：\(error.description)"))
        } else {
            onHealth(.ready("已请求 Finder 清空废纸篓"))
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.refresh()
        }
    }

    private func trashURL() -> URL? {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
    }

    private func finderTrashCountIfAlreadyAuthorized() -> Int? {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let target = finder.aeDesc,
              AEDeterminePermissionToAutomateTarget(
                target,
                typeWildCard,
                typeWildCard,
                false
              ) == noErr else {
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
}
