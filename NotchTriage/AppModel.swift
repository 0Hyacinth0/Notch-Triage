import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    private enum PreferenceKey {
        static let leftWingContent = "notch.leftWingContent"
        static let rightWingContent = "notch.rightWingContent"
        static let lastUpdateCheck = "updates.lastSuccessfulCheck"
    }

    @Published var isExpanded = false
    @Published var isPanelClosing = false
    @Published var isNotchCanvasExpanded = false
    @Published var isHoveringNotch = false
    @Published var menuBarHeight: CGFloat = 37
    @Published var notchWidth: CGFloat = 186
    @Published var media = MediaSnapshot.idle
    @Published var codexLimits: [CodexLimitBucket] = []
    @Published var notificationSources: [NotificationSource] = []
    @Published var notificationPulse: NotificationPulse?
    @Published var systemHUD: SystemHUDSnapshot?
    @Published var trashCount: Int?
    @Published var power = PowerSnapshot.empty
    @Published var chargeLimit = ChargeLimitSnapshot.unavailable
    @Published var updateStatus = AppUpdateStatus.idle
    @Published var updateDownloadProgress: AppUpdateDownloadProgress?
    @Published var availableUpdate: AppRelease?
    @Published var updatePrompt: AppUpdatePrompt?
    @Published var leftWingContent: NotchWingContent {
        didSet {
            UserDefaults.standard.set(
                leftWingContent.rawValue,
                forKey: PreferenceKey.leftWingContent
            )
        }
    }
    @Published var rightWingContent: NotchWingContent {
        didSet {
            UserDefaults.standard.set(
                rightWingContent.rawValue,
                forKey: PreferenceKey.rightWingContent
            )
        }
    }

    @Published var codexHealth: ServiceHealth = .loading("正在连接 Codex")
    @Published var mediaHealth: ServiceHealth = .loading("正在读取系统播放状态")
    @Published var notificationHealth: ServiceHealth = .loading("正在检查辅助功能权限")
    @Published var trashHealth: ServiceHealth = .loading("正在读取废纸篓")
    @Published var powerHealth: ServiceHealth = .loading("正在读取电池与适配器")

    @Published var autoDismissBanners = true {
        didSet {
            notificationService.autoDismissBanners = autoDismissBanners
        }
    }

    private var pulseTask: Task<Void, Never>?
    private var systemHUDDismissTask: Task<Void, Never>?
    private var hoverCollapseTask: Task<Void, Never>?
    private var panelCloseTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?

    private func motion(_ animation: Animation) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .linear(duration: 0.01)
            : animation
    }

    init() {
        leftWingContent = NotchWingContent(
            rawValue: UserDefaults.standard.string(
                forKey: PreferenceKey.leftWingContent
            ) ?? ""
        ) ?? .media
        rightWingContent = NotchWingContent(
            rawValue: UserDefaults.standard.string(
                forKey: PreferenceKey.rightWingContent
            ) ?? ""
        ) ?? .codex
    }

    private lazy var codexService = CodexUsageService(
        onLimits: { [weak self] limits in
            self?.codexLimits = limits
            self?.codexHealth = .ready(
                limits.isEmpty ? "当前没有返回限额桶" : "已读取 \(limits.count) 个动态限额桶"
            )
        },
        onHealth: { [weak self] health in
            self?.codexHealth = health
        }
    )

    private lazy var mediaService = MediaService(
        onSnapshot: { [weak self] snapshot in
            self?.media = snapshot
            self?.mediaHealth = snapshot == .idle
                ? .warning("未检测到正在播放的曲目")
                : .ready("正在读取 \(snapshot.sourceName)")
        },
        onHealth: { [weak self] health in
            self?.mediaHealth = health
        }
    )

    private lazy var notificationService = NotificationBridge(
        onSources: { [weak self] sources in
            self?.notificationSources = sources
        },
        onPulse: { [weak self] pulse in
            self?.showNotificationPulse(pulse)
        },
        onHealth: { [weak self] health in
            self?.notificationHealth = health
        }
    )

    private lazy var trashService = TrashService(
        onCount: { [weak self] count in
            self?.trashCount = count
            if let count {
                self?.trashHealth = .ready(
                    count == 0 ? "废纸篓为空" : "废纸篓中有 \(count) 项"
                )
            }
        },
        onHealth: { [weak self] health in
            self?.trashHealth = health
        }
    )

    private lazy var powerService = PowerMonitorService(
        onSnapshot: { [weak self] power, chargeLimit in
            self?.power = power
            self?.chargeLimit = chargeLimit
        },
        onHealth: { [weak self] health in
            self?.powerHealth = health
        }
    )

    private lazy var systemHUDService = SystemHUDService(
        onEvent: { [weak self] snapshot in
            self?.showSystemHUD(snapshot)
        }
    )

    private let updateService = UpdateService()

    func start() {
        codexService.start()
        mediaService.start()
        notificationService.autoDismissBanners = autoDismissBanners
        notificationService.start(promptForAccessibility: true)
        trashService.start()
        powerService.start()
        systemHUDService.start()
        scheduleAutomaticUpdateCheck()
    }

    func stop() {
        pulseTask?.cancel()
        systemHUDDismissTask?.cancel()
        hoverCollapseTask?.cancel()
        panelCloseTask?.cancel()
        updateTask?.cancel()
        codexService.stop()
        mediaService.stop()
        notificationService.stop()
        trashService.stop()
        powerService.stop()
        systemHUDService.stop()
    }

    func toggleExpanded() {
        guard !isPanelClosing else { return }
        if isExpanded {
            collapseExpanded()
            return
        }

        hoverCollapseTask?.cancel()
        panelCloseTask?.cancel()
        isNotchCanvasExpanded = true
        isExpanded = true
        isHoveringNotch = false
        notificationService.refreshNow()
        trashService.refresh()
        powerService.refresh()
    }

    func collapseExpanded() {
        guard isExpanded, !isPanelClosing else { return }
        hoverCollapseTask?.cancel()
        isNotchCanvasExpanded = true
        isPanelClosing = true

        panelCloseTask?.cancel()
        panelCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(340))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                withAnimation(self.motion(NotchDesign.Motion.panelClose)) {
                    self.isExpanded = false
                    self.isPanelClosing = false
                    self.isHoveringNotch = false
                }
            }

            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      !self.isExpanded,
                      !self.isPanelClosing,
                      !self.isHoveringNotch else { return }
                self.isNotchCanvasExpanded = false
            }
        }
    }

    func handleUpdateMenuAction() {
        if let availableUpdate {
            presentUpdatePrompt(for: availableUpdate)
        } else {
            checkForUpdates(manual: true)
        }
    }

    func checkForUpdates(manual: Bool) {
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
                    if manual {
                        presentUpdatePrompt(for: release)
                    }
                } else {
                    availableUpdate = nil
                    updateStatus = .upToDate(currentVersion)
                    if manual {
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
                if manual {
                    updatePrompt = AppUpdatePrompt(
                        title: "检查更新失败",
                        message: error.localizedDescription,
                        release: nil
                    )
                }
            }
        }
    }

    func installUpdate(_ release: AppRelease) {
        guard !updateStatus.isBusy else { return }
        let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
        guard isInstalledApplication(currentAppURL) else {
            updatePrompt = AppUpdatePrompt(
                title: "无法自动安装",
                message: "请先将 NotchTriage.app 移到“应用程序”文件夹，再从那里运行并检查更新。",
                release: nil
            )
            return
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
                return
            } catch {
                updateDownloadProgress = nil
                updateStatus = .failed(error.localizedDescription)
                updatePrompt = AppUpdatePrompt(
                    title: "更新安装失败",
                    message: error.localizedDescription,
                    release: nil
                )
            }
        }
    }

    func requestAccessibility() {
        notificationService.requestAccessibility()
    }

    func clearAllNotifications() {
        notificationService.clearAllNotifications()
    }

    func refreshCodex() {
        codexService.refresh()
    }

    func openTrash() {
        trashService.openTrash()
    }

    func emptyTrash() {
        trashService.emptyTrash()
    }

    func refreshPower() {
        powerService.refresh()
    }

    func setChargeLimit(_ limit: Int) {
        powerService.setChargeLimit(limit)
    }

    func temporarilyFillBattery() {
        powerService.temporarilyFillToFull()
    }

    func resumeChargeLimit() {
        powerService.resumeChargeLimit()
    }

    func setLeftWingContent(_ content: NotchWingContent) {
        withAnimation(motion(NotchDesign.Motion.value)) {
            leftWingContent = content
        }
    }

    func setRightWingContent(_ content: NotchWingContent) {
        withAnimation(motion(NotchDesign.Motion.value)) {
            rightWingContent = content
        }
    }

    func swapWingContents() {
        let previousLeft = leftWingContent
        withAnimation(motion(NotchDesign.Motion.value)) {
            leftWingContent = rightWingContent
            rightWingContent = previousLeft
        }
    }

    func resetWingContents() {
        withAnimation(motion(NotchDesign.Motion.value)) {
            leftWingContent = .media
            rightWingContent = .codex
        }
    }

    func setNotchHovered(_ hovered: Bool) {
        guard !isExpanded else { return }
        hoverCollapseTask?.cancel()

        if hovered {
            isNotchCanvasExpanded = true
            withAnimation(motion(NotchDesign.Motion.hover)) {
                isHoveringNotch = true
            }
            return
        }

        hoverCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isExpanded else { return }
                withAnimation(
                    self.motion(NotchDesign.Motion.hover),
                    completionCriteria: .logicallyComplete
                ) {
                    self.isHoveringNotch = false
                } completion: {
                    guard !self.isExpanded,
                          !self.isPanelClosing,
                          !self.isHoveringNotch else { return }
                    self.isNotchCanvasExpanded = false
                }
            }
        }
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    private var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
    }

    private func scheduleAutomaticUpdateCheck() {
        let lastCheck = UserDefaults.standard.object(
            forKey: PreferenceKey.lastUpdateCheck
        ) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= 12 * 60 * 60 else { return }

        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.checkForUpdates(manual: false)
            }
        }
    }

    private func presentUpdatePrompt(for release: AppRelease) {
        let summary = release.notes
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let abbreviatedNotes = summary.count > 320
            ? String(summary.prefix(320)) + "…"
            : summary
        let message = abbreviatedNotes.isEmpty
            ? "确认后将下载、验证并安装更新，然后重启 Notch Triage。"
            : abbreviatedNotes
                + "\n\n确认后将下载、验证并安装更新，然后重启 Notch Triage。"
        updatePrompt = AppUpdatePrompt(
            title: "发现 \(release.displayVersion)",
            message: message,
            release: release
        )
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

    private func showNotificationPulse(_ pulse: NotificationPulse) {
        pulseTask?.cancel()
        withAnimation(motion(NotchDesign.Motion.value)) {
            notificationPulse = pulse
        }

        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                withAnimation(self.motion(NotchDesign.Motion.value)) {
                    self.notificationPulse = nil
                }
            }
        }
    }

    private func showSystemHUD(_ snapshot: SystemHUDSnapshot) {
        guard !isPanelClosing else { return }
        systemHUDDismissTask?.cancel()
        isNotchCanvasExpanded = true

        let isContinuousUpdate = systemHUD?.kind == snapshot.kind

        withAnimation(
            motion(
                isContinuousUpdate
                    ? NotchDesign.Motion.value
                    : NotchDesign.Motion.panelOpen
            )
        ) {
            systemHUD = snapshot
        }

        let visibility: Duration = snapshot.kind == .airPods
            ? .milliseconds(2_600)
            : .milliseconds(1_650)
        systemHUDDismissTask = Task { [weak self] in
            try? await Task.sleep(for: visibility)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                withAnimation(
                    self.motion(NotchDesign.Motion.panelClose),
                    completionCriteria: .logicallyComplete
                ) {
                    self.systemHUD = nil
                } completion: {
                    guard !self.isExpanded,
                          !self.isPanelClosing,
                          !self.isHoveringNotch,
                          self.systemHUD == nil else { return }
                    self.isNotchCanvasExpanded = false
                }
            }
        }
    }
}
