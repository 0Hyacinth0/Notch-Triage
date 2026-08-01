import AppKit
import Foundation

@MainActor
final class TrashService {
    typealias CountHandler = @MainActor (Int) -> Void
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
        guard let url = trashURL() else {
            onHealth(.warning("无法定位用户废纸篓"))
            return
        }

        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            onCount(items.count)
        } catch {
            onHealth(.warning("无法读取废纸篓：\(error.localizedDescription)"))
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
}
