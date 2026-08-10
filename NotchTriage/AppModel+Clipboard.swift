import AppKit
import Foundation
import SwiftUI

extension AppModel {
    func startClipboardHistoryLifecycle() {
        clipboardLifecycleGeneration &+= 1
        loadClipboardHistorySnapshot()
        guard clipboardHistoryEnabled, !isBackgroundRefreshPaused else { return }
        startClipboardMonitorIfPermitted()
    }

    func stopClipboardHistoryLifecycle() {
        clipboardLifecycleGeneration &+= 1
        clipboardMonitor?.stop()
        replaceClipboardMonitoringActive(false)
        clipboardStoreTask?.cancel()
        clipboardFeedbackTask?.cancel()
        replaceClipboardFeedback(nil)

        guard clipboardRetentionPolicy == .session else { return }
        replaceClipboardHistoryItems([])
        Task { [clipboardStore] in
            _ = await clipboardStore.removeAll()
        }
    }

    func setClipboardHistoryPaused(_ paused: Bool) {
        guard clipboardHistoryEnabled else { return }
        if paused {
            clipboardMonitor?.suspend()
            replaceClipboardMonitoringActive(false)
        } else if areApplicationServicesRunning {
            startClipboardMonitorIfPermitted()
        }
    }

    func enableClipboardHistory() {
        guard !clipboardHistoryEnabled else { return }
        replaceClipboardHistoryEnabled(true)
        UserDefaults.standard.set(
            true,
            forKey: PreferenceKey.clipboardHistoryEnabled
        )
        refreshClipboardAccessNotice()
        if areApplicationServicesRunning, !isBackgroundRefreshPaused {
            startClipboardMonitorIfPermitted()
        }
        showClipboardFeedback("剪贴板历史已启用，只会读取白名单内容")
    }

    func disableClipboardHistory(clearHistory: Bool) {
        clipboardLifecycleGeneration &+= 1
        clipboardMonitor?.stop()
        replaceClipboardMonitoringActive(false)
        replaceClipboardHistoryEnabled(false)
        UserDefaults.standard.set(
            false,
            forKey: PreferenceKey.clipboardHistoryEnabled
        )

        if clearHistory {
            clearClipboardHistory()
        } else {
            showClipboardFeedback("监控已停止，现有历史已保留")
        }
        replaceClipboardAccessNotice(nil)
    }

    func setClipboardRetentionPolicy(_ policy: ClipboardRetentionPolicy) {
        guard clipboardRetentionPolicy != policy else { return }
        let generation = clipboardLifecycleGeneration
        clipboardStoreTask?.cancel()
        clipboardStoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.clipboardStore.replacePolicy(policy)
            let appliedPolicy = await self.clipboardStore.retentionPolicy
            let didClean = await self.clipboardStore.lastPersistenceCleanupSucceeded
            guard !Task.isCancelled,
                  self.clipboardLifecycleGeneration == generation else { return }
            self.replaceClipboardRetentionPolicy(appliedPolicy)
            UserDefaults.standard.set(
                appliedPolicy.rawValue,
                forKey: PreferenceKey.clipboardRetentionPolicy
            )
            self.replaceClipboardHistoryItems(snapshot)
            self.showClipboardFeedback(
                appliedPolicy != policy
                    ? "无法更改保留期限，请检查本机存储权限"
                    : didClean
                        ? "保留期限已改为\(policy.title)"
                        : "保留期限已更改，但部分旧缓存无法删除"
            )
        }
    }

    func restoreClipboardHistoryItem(_ item: ClipboardHistoryItem) {
        if writeClipboardPayload(item.payload) {
            showClipboardFeedback("已重新复制到系统剪贴板")
        } else {
            showClipboardFeedback("重新复制失败")
        }
    }

    func removeClipboardHistoryItem(_ item: ClipboardHistoryItem) {
        let generation = clipboardLifecycleGeneration
        clipboardStoreTask?.cancel()
        clipboardStoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didRemove = await self.clipboardStore.remove(id: item.id)
            let didClean = await self.clipboardStore.lastPersistenceCleanupSucceeded
            let snapshot = await self.clipboardStore.snapshot()
            guard !Task.isCancelled,
                  self.clipboardLifecycleGeneration == generation else { return }
            self.replaceClipboardHistoryItems(snapshot)
            self.showClipboardFeedback(
                !didRemove
                    ? "无法移除历史，请检查本机存储权限"
                    : didClean
                        ? "已从历史中移除，不影响当前剪贴板"
                        : "已从列表移除，但部分旧缓存无法删除"
            )
        }
    }

    func clearClipboardHistory() {
        let generation = clipboardLifecycleGeneration
        clipboardStoreTask?.cancel()
        clipboardStoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.clipboardStore.removeAllResult()
            let snapshot = await self.clipboardStore.snapshot()
            guard !Task.isCancelled,
                  self.clipboardLifecycleGeneration == generation else { return }
            self.replaceClipboardHistoryItems(snapshot)
            self.showClipboardFeedback(
                !result.didSucceed
                    ? "无法清除历史，请检查本机存储权限"
                    : !result.didCleanPersistedData
                        ? "历史已清空，但部分旧缓存无法删除"
                        : result.removedCount == 0
                            ? "剪贴板历史已经是空的"
                            : "已清除 \(result.removedCount) 条历史，不影响当前剪贴板"
            )
        }
    }

    @discardableResult
    func writeClipboardPayload(_ payload: ClipboardPayload) -> Bool {
        guard let changeCount = pasteboardAccess.write(payload) else {
            return false
        }
        clipboardMonitor?.registerSelfWrite(changeCount: changeCount)
        return true
    }

    func refreshClipboardAccessNotice() {
        switch pasteboardAccess.accessBehavior {
        case .default, .ask:
            replaceClipboardAccessNotice(clipboardHistoryEnabled
                ? "首次读取新复制内容时，macOS 可能询问是否允许。"
                : "启用后，首次读取时 macOS 可能询问是否允许。")
        case .alwaysAllow:
            replaceClipboardAccessNotice("macOS 已允许 Notch Triage 读取剪贴板。")
        case .alwaysDeny:
            replaceClipboardAccessNotice("macOS 当前禁止读取；请在系统设置的隐私与安全中调整。")
            clipboardMonitor?.stop()
            replaceClipboardMonitoringActive(false)
        @unknown default:
            replaceClipboardAccessNotice("剪贴板访问状态未知；系统仍会执行隐私保护。")
        }
    }

    func recheckClipboardAccess() {
        refreshClipboardAccessNotice()
        guard clipboardHistoryEnabled,
              areApplicationServicesRunning,
              !isBackgroundRefreshPaused else { return }
        startClipboardMonitorIfPermitted()
    }

    private func startClipboardMonitorIfPermitted() {
        refreshClipboardAccessNotice()
        guard pasteboardAccess.accessBehavior != .alwaysDeny else { return }
        if clipboardMonitor == nil {
            clipboardMonitor = ClipboardMonitor(
                access: pasteboardAccess,
                onPayload: { [weak self] payload, changeCount in
                    self?.recordClipboardPayload(
                        payload,
                        sourceChangeCount: changeCount
                    )
                }
            )
        }
        clipboardMonitor?.start()
        replaceClipboardMonitoringActive(true)
    }

    private func loadClipboardHistorySnapshot() {
        let generation = clipboardLifecycleGeneration
        clipboardStoreTask?.cancel()
        clipboardStoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let loadResult = await self.clipboardStore.load()
            let snapshot = await self.clipboardStore.snapshot()
            guard !Task.isCancelled,
                  self.clipboardLifecycleGeneration == generation else { return }
            self.replaceClipboardHistoryItems(snapshot)
            if !loadResult.didCleanPersistedData {
                self.showClipboardFeedback("部分旧剪贴板缓存无法删除，请检查本机存储权限")
            }
        }
    }

    private func recordClipboardPayload(
        _ payload: ClipboardPayload,
        sourceChangeCount: Int
    ) {
        let generation = clipboardLifecycleGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.clipboardHistoryEnabled,
                  self.clipboardLifecycleGeneration == generation else { return }
            let result = await self.clipboardStore.add(
                payload,
                sourceChangeCount: sourceChangeCount
            )
            let snapshot = await self.clipboardStore.snapshot()
            guard self.clipboardHistoryEnabled,
                  self.clipboardLifecycleGeneration == generation else { return }
            self.replaceClipboardHistoryItems(snapshot)
            if case .rejected(let reason) = result {
                self.showClipboardFeedback(reason.userMessage)
            }
        }
    }

    private func showClipboardFeedback(_ message: String) {
        clipboardFeedbackTask?.cancel()
        withAnimation(motion(NotchDesign.Motion.value)) {
            replaceClipboardFeedback(message)
        }
        clipboardFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled, let self else { return }
            withAnimation(self.motion(NotchDesign.Motion.value)) {
                self.replaceClipboardFeedback(nil)
            }
        }
    }
}

extension ClipboardRetentionPolicy: Identifiable {
    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return "到 App 退出"
        case .oneDay: return "1 天"
        case .sevenDays: return "7 天"
        }
    }

    var privacyDescription: String {
        switch self {
        case .session:
            return "只保存在内存中，退出后清空。"
        case .oneDay:
            return "在本机保存 1 天，过期自动清理。"
        case .sevenDays:
            return "在本机保存 7 天，过期自动清理。"
        }
    }
}

private extension ClipboardMutationRejectionReason {
    var userMessage: String {
        switch self {
        case .emptyPayload: return "空白内容不会加入历史"
        case .textTooLarge: return "文本超过 50 KB，未加入历史"
        case .imageTooLarge: return "图片超过 10 MiB，未加入历史"
        case .unsupportedImageType: return "只支持 PNG、JPEG 和 TIFF 图片"
        case .tooManyFileURLs: return "一次最多记录 20 个文件"
        case .invalidFileURL: return "该剪贴板内容不是受支持的本地文件"
        case .payloadTooLarge: return "历史已达到 24 MiB 预算"
        case .capacityExceeded: return "历史已达到 50 项上限"
        case .persistenceFailed: return "无法保存剪贴板历史"
        }
    }
}
