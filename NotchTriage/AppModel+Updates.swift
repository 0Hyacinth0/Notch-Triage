import AppKit
import Foundation
import SwiftUI

extension AppModel {
    /// The settings window owns its update flow. Unlike the compact notch menu,
    /// it should start the download directly so progress remains visible in
    /// the page where the user initiated the action.
    func handleSettingsUpdateAction() {
        guard !updateStatus.isBusy else { return }
        if let availableUpdate {
            dismissUpdatePrompt()
            installUpdate(availableUpdate, context: .settings)
        } else {
            dismissUpdatePrompt()
            checkForUpdates(context: .settings)
        }
    }

    func handleUpdateMenuAction() {
        guard !updateStatus.isBusy else { return }
        if let availableUpdate {
            UserDefaults.standard.set(
                availableUpdate.version,
                forKey: PreferenceKey.lastPromptedVersion
            )
            presentUpdatePrompt(for: availableUpdate)
        } else {
            checkForUpdates(context: .panel)
        }
    }

    func checkForUpdates(context: UpdatePresentationContext) {
        guard !updateStatus.isBusy else { return }
        updateTask?.cancel()
        updateDownloadProgress = nil
        updateStatus = .checking

        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await updateService.latestRelease()
                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(
                    Date(),
                    forKey: PreferenceKey.lastUpdateCheck
                )

                if isNewerVersion(release.version, than: currentVersion) {
                    availableUpdate = release
                    updateStatus = .available(release.version)
                    if context.isManualCheck {
                        UserDefaults.standard.set(
                            release.version,
                            forKey: PreferenceKey.lastPromptedVersion
                        )
                    }
                    if context.presentsAvailableReleaseInPanel {
                        presentUpdatePrompt(for: release)
                    } else if context == .automatic {
                        presentAutomaticUpdatePromptIfNeeded(for: release)
                    }
                } else {
                    availableUpdate = nil
                    updateStatus = .upToDate(currentVersion)
                    if context.isManualCheck {
                        updatePrompt = AppUpdatePrompt(
                            title: "已经是最新版本",
                            message: "当前版本为 v\(currentVersion)。",
                            release: nil
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                updateStatus = .failed(error.localizedDescription)
                refreshScheduler.reschedule(.updates, after: 15 * 60)
                if context.isManualCheck {
                    updatePrompt = AppUpdatePrompt(
                        title: "检查更新失败",
                        message: error.localizedDescription,
                        release: nil
                    )
                }
            }
        }
    }

    func installUpdate(
        _ release: AppRelease,
        context: UpdatePresentationContext = .panel
    ) {
        guard !updateStatus.isBusy else { return }
        let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
        guard isInstalledApplication(currentAppURL) else {
            dismissUpdatePrompt()
            updatePrompt = AppUpdatePrompt(
                title: "无法自动安装",
                message: "请先将 NotchTriage.app 移到“应用程序”文件夹，再从那里运行并检查更新。",
                release: nil
            )
            return
        }

        if context.presentsInstallProgressInPanel {
            withAnimation(motion(NotchDesign.Motion.panelOpen)) {
                sendPanelEvent(.installStarted)
            }
        }
        updateStatus = .downloading(release.version)
        updateDownloadProgress = AppUpdateDownloadProgress(
            receivedBytes: 0,
            totalBytes: Int64(release.assetSize)
        )
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let preparedUpdate = try await updateService.prepareUpdate(
                    release,
                    replacing: currentAppURL,
                    onDownloadProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  case .downloading = self.updateStatus else { return }
                            self.updateDownloadProgress = progress
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                updateDownloadProgress = AppUpdateDownloadProgress(
                    receivedBytes: Int64(release.assetSize),
                    totalBytes: Int64(release.assetSize)
                )
                updateStatus = .installing(release.version)

                let installedURL = try FileManager.default.replaceItemAt(
                    currentAppURL,
                    withItemAt: preparedUpdate.appURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                ) ?? currentAppURL

                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.createsNewApplicationInstance = true
                configuration.allowsRunningApplicationSubstitution = false
                configuration.promptsUserIfNeeded = true
                _ = try await NSWorkspace.shared.openApplication(
                    at: installedURL,
                    configuration: configuration
                )
                NSApp.terminate(nil)
            } catch is CancellationError {
                updateDownloadProgress = nil
                if context.presentsInstallProgressInPanel {
                    sendPanelEvent(.installFinished)
                }
            } catch {
                updateDownloadProgress = nil
                updateStatus = .failed(error.localizedDescription)
                if context.presentsInstallProgressInPanel {
                    sendPanelEvent(.installFinished)
                }
                updatePrompt = AppUpdatePrompt(
                    title: "更新安装失败",
                    message: error.localizedDescription,
                    release: nil
                )
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
    }

    var updateDiagnosticHealth: ServiceHealth {
        switch updateStatus {
        case .idle:
            return .loading("等待自动检查")
        case .checking:
            return .loading("正在检查 GitHub Release")
        case .available(let version):
            return .warning("发现可安装版本 v\(version)")
        case .downloading(let version):
            return .loading("正在下载 v\(version)")
        case .installing(let version):
            return .loading("正在安装 v\(version)")
        case .upToDate(let version):
            return .ready("当前已是最新版 v\(version)")
        case .failed(let message):
            return .failed(message)
        }
    }

    private func presentAutomaticUpdatePromptIfNeeded(for release: AppRelease) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: PreferenceKey.lastPromptedVersion)
                != release.version else { return }
        defaults.set(release.version, forKey: PreferenceKey.lastPromptedVersion)

        withAnimation(motion(NotchDesign.Motion.panelOpen)) {
            sendPanelEvent(
                .automaticUpdateWorkspaceRequested(
                    releaseVersion: release.version
                )
            )
        }
    }

    func presentUpdatePrompt(for release: AppRelease) {
        let summary = release.notes
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let abbreviatedNotes = summary.count > 320
            ? String(summary.prefix(320)) + "…"
            : summary
        let message = abbreviatedNotes.isEmpty
            ? "确认后将下载、验证并安装更新，然后重启 Notch Triage。"
            : abbreviatedNotes
                + "\n\n确认后将下载、验证并安装更新，然后重启 Notch Triage。"
        let prompt = AppUpdatePrompt(
            title: "发现 \(release.displayVersion)",
            message: message,
            release: release
        )
        updatePrompt = prompt
        sendPanelEvent(.releaseUpdatePromptPresented(id: prompt.id))
    }

    func dismissUpdatePrompt() {
        if case .releaseUpdatePrompt(let id) = panelState.presentationOverride {
            sendPanelEvent(.releaseUpdatePromptDismissed(id: id))
        }
        updatePrompt = nil
    }

    func installPresentedUpdate(_ release: AppRelease) {
        dismissUpdatePrompt()
        installUpdate(release)
    }

    private func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private func isInstalledApplication(_ appURL: URL) -> Bool {
        let path = appURL.resolvingSymlinksInPath().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(userApplications + "/")
    }
}
