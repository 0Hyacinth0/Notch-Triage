import AppKit
import Foundation

extension AppModel {
    func fileDragEntered(
        sessionID: UUID,
        urls: [URL],
        itemCount: Int
    ) -> Bool {
        guard panelState.presentationOverride != .installingUpdate,
              !panelState.isPresentingReleaseUpdatePrompt else { return false }
        let acceptance = previewFileDropAcceptance(
            urls: urls,
            itemCount: itemCount
        )

        pendingFileDropSessionID = sessionID
        scheduleFileDropSafetyCleanup(sessionID: sessionID)
        fileDropExitTask?.cancel()
        fileDropActivationTask?.cancel()
        if panelState.isPresentingFileDropTarget {
            sendPanelEvent(
                .fileDragEntered(
                    sessionID: sessionID,
                    acceptance: acceptance
                )
            )
            return true
        }
        fileDropActivationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let self,
                  self.pendingFileDropSessionID == sessionID else { return }
            self.sendPanelEvent(
                .fileDragEntered(
                    sessionID: sessionID,
                    acceptance: acceptance
                )
            )
        }
        return true
    }

    func fileDragExited(sessionID: UUID) {
        // AppKit may deliver a trailing draggingExited after a fast drop. An
        // accepted payload owns this session until the async shelf mutation
        // settles; do not let that stale exit clear its protection or return
        // the panel while the add is still in flight.
        if fileDropInFlightSessionID == sessionID {
            return
        }
        let isPending = pendingFileDropSessionID == sessionID
        let isActive = panelState.fileDropTarget?.sessionID == sessionID
        guard isPending || isActive else { return }
        fileDropSafetyTask?.cancel()
        fileDropSafetyTask = nil
        if pendingFileDropSessionID == sessionID {
            pendingFileDropSessionID = nil
            fileDropActivationTask?.cancel()
            fileDropActivationTask = nil
        }
        fileDropExitTask?.cancel()
        fileDropExitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.sendPanelEvent(.fileDragExited(sessionID: sessionID))
            self.sendPanelEvent(.pointerExited)
        }
    }

    func performFileDrop(
        sessionID: UUID,
        urls: [URL],
        itemCount: Int
    ) -> Bool {
        guard panelState.presentationOverride != .installingUpdate,
              !panelState.isPresentingReleaseUpdatePrompt,
              fileDropInFlightSessionID != sessionID,
              pendingFileDropSessionID == sessionID
                || panelState.fileDropTarget?.sessionID == sessionID else {
            return false
        }
        beginFileDropInFlight(sessionID: sessionID)
        pendingFileDropSessionID = nil
        fileDropSafetyTask?.cancel()
        fileDropSafetyTask = nil
        fileDropActivationTask?.cancel()
        fileDropActivationTask = nil
        fileDropExitTask?.cancel()
        fileDropExitTask = nil

        if panelState.fileDropTarget?.sessionID != sessionID {
            sendPanelEvent(
                .fileDragEntered(
                    sessionID: sessionID,
                    acceptance: previewFileDropAcceptance(
                        urls: urls,
                        itemCount: itemCount
                    )
                )
            )
        }
        addFileShelfURLs(urls, dropSessionID: sessionID)
        return true
    }

    func chooseFilesForShelf() {
        guard !panelState.blocksOrdinaryPanelInput else { return }
        let panel = NSOpenPanel()
        panel.title = "添加到文件暂存架"
        panel.prompt = "加入暂存"
        panel.message = "只保存文件引用；不会移动、复制或修改原文件。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.addFileShelfURLs(panel.urls)
        }
    }

    func openFileShelfItem(_ item: FileShelfItem) {
        guard item.isAvailable else {
            showFileShelfFeedback("项目不可用，原文件可能已移动或删除")
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    func revealFileShelfItem(_ item: FileShelfItem) {
        guard item.isAvailable else {
            showFileShelfFeedback("项目不可用，无法在 Finder 中显示")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyFileShelfItem(_ item: FileShelfItem) {
        guard item.isAvailable else {
            showFileShelfFeedback("项目不可用，无法复制")
            return
        }
        if writeClipboardPayload(.fileURLs([item.url])) {
            showFileShelfFeedback("已复制“\(item.name)”")
        } else {
            showFileShelfFeedback("复制失败")
        }
    }

    func removeFileShelfItem(_ item: FileShelfItem) {
        fileShelfMaintenanceTask?.cancel()
        fileShelfMaintenanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.fileShelfStore.remove(id: item.id)
            guard !Task.isCancelled else { return }
            self.replaceFileShelfItems(
                await self.fileShelfStore.snapshot()
            )
            self.showFileShelfFeedback("已从暂存架移除，不影响原文件")
        }
    }

    func clearFileShelf() {
        fileShelfMaintenanceTask?.cancel()
        fileShelfMaintenanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let removedCount = await self.fileShelfStore.removeAll()
            guard !Task.isCancelled else { return }
            self.replaceFileShelfItems([])
            self.showFileShelfFeedback(
                removedCount == 0
                    ? "暂存架已经是空的"
                    : "已清除 \(removedCount) 个引用，原文件未受影响"
            )
        }
    }

    func refreshFileShelfAvailability() {
        fileShelfMaintenanceTask?.cancel()
        fileShelfMaintenanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.fileShelfStore.snapshot()
            guard !Task.isCancelled else { return }
            self.replaceFileShelfItems(snapshot)
        }
    }

    func showWorkspace(section: WorkspaceSection) {
        guard !panelState.blocksOrdinaryPanelInput else { return }
        setWorkspaceSection(section)
        if !isExpanded || isPanelClosing {
            toggleExpanded()
        }
    }

    private func addFileShelfURLs(
        _ urls: [URL],
        dropSessionID: UUID? = nil
    ) {
        // A non-drop add (for example the file chooser) supersedes any
        // accepted drop that has not settled yet. Drop callers mark their
        // session before entering this method, so retain that marker here.
        if dropSessionID == nil {
            cancelFileDropInFlight()
        }
        fileShelfAddTask?.cancel()
        fileShelfAddTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.fileShelfStore.add(urls)
            let snapshot = await self.fileShelfStore.snapshot()
            guard !Task.isCancelled else {
                if let dropSessionID {
                    self.finishFileDropInFlight(sessionID: dropSessionID)
                }
                return
            }

            self.replaceFileShelfItems(snapshot)
            if result.acceptedCount > 0 {
                if let dropSessionID {
                    // A newer drop, stop, or pause may have superseded this
                    // completion. Its persisted data is still reflected in
                    // the snapshot above, but this stale session must not
                    // mutate panel presentation or feedback.
                    guard self.fileDropInFlightSessionID == dropSessionID else {
                        return
                    }
                    self.workspaceSection = .shelf
                    self.sendPanelEvent(
                        .fileDropSucceeded(sessionID: dropSessionID)
                    )
                    self.finishFileDropInFlight(sessionID: dropSessionID)
                } else {
                    self.workspaceSection = .shelf
                    if !self.isExpanded || self.isPanelClosing {
                        self.toggleExpanded()
                    }
                }
            } else if let dropSessionID {
                guard self.fileDropInFlightSessionID == dropSessionID else {
                    return
                }
                self.sendPanelEvent(.fileDragExited(sessionID: dropSessionID))
                self.finishFileDropInFlight(sessionID: dropSessionID)
            }
            self.showFileShelfFeedback(Self.feedback(for: result))
        }
    }

    private func scheduleFileDropSafetyCleanup(sessionID: UUID) {
        fileDropSafetyTask?.cancel()
        fileDropSafetyTask = Task { @MainActor [weak self] in
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            // Let AppKit deliver performDragOperation/draggingExited first.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  let self,
                  self.pendingFileDropSessionID == sessionID
                    || self.panelState.fileDropTarget?.sessionID == sessionID else {
                return
            }
            self.fileDragExited(sessionID: sessionID)
        }
    }

    private func previewFileDropAcceptance(
        urls: [URL],
        itemCount: Int
    ) -> FileDropAcceptance {
        var knownPaths = Set(fileShelfItems.map(\.standardizedPath))
        var addedCount = 0
        var duplicateCount = 0
        var overLimitCount = 0
        let validURLs = urls.filter { $0.isFileURL && !$0.path.isEmpty }

        for url in validURLs {
            let path = url.standardizedFileURL.path
            if knownPaths.contains(path) {
                duplicateCount += 1
            } else if knownPaths.count < FileShelfStore.maximumItemCount {
                knownPaths.insert(path)
                addedCount += 1
            } else {
                overLimitCount += 1
            }
        }

        let rejectedCount = max(0, itemCount - validURLs.count)
        return FileShelfMutationResult(
            addedCount: addedCount,
            duplicateCount: duplicateCount,
            overLimitCount: overLimitCount,
            rejectedCount: rejectedCount
        ).acceptance
    }

    private func showFileShelfFeedback(_ message: String) {
        fileShelfFeedbackTask?.cancel()
        replaceFileShelfFeedback(message)
        fileShelfFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.replaceFileShelfFeedback(nil)
        }
    }

    private static func feedback(
        for result: FileShelfMutationResult
    ) -> String {
        if result.acceptedCount == 0 {
            return result.acceptance.reason ?? "没有可加入的本地文件"
        }
        var parts: [String] = []
        if result.addedCount > 0 {
            parts.append("加入 \(result.addedCount) 项")
        }
        if result.duplicateCount > 0 {
            parts.append("\(result.duplicateCount) 项已置顶")
        }
        if result.totalRejectedCount > 0 {
            parts.append("\(result.totalRejectedCount) 项未加入")
        }
        return parts.joined(separator: "，")
    }
}
