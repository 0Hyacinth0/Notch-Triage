import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum PreferenceKey {
        static let leftWingContent = "notch.leftWingContent"
        static let rightWingContent = "notch.rightWingContent"
        static let lastUpdateCheck = "updates.lastSuccessfulCheck"
        static let lastPromptedVersion = "updates.lastPromptedVersion"
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
    @Published var updateStatus = AppUpdateStatus.idle {
        didSet {
            diagnostics.update(.updates, health: updateDiagnosticHealth)
        }
    }
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
    @Published var isBackgroundRefreshPaused = false
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginRequiresApproval = false
    @Published var launchAtLoginHealth: ServiceHealth = .loading("正在读取登录项状态")

    let diagnostics = DiagnosticsStore()

    @Published var autoDismissBanners = true {
        didSet {
            notificationService.autoDismissBanners = autoDismissBanners
        }
    }

    var pulseTask: Task<Void, Never>?
    var systemHUDDismissTask: Task<Void, Never>?
    var hoverCollapseTask: Task<Void, Never>?
    var panelCloseTask: Task<Void, Never>?
    var updateTask: Task<Void, Never>?
    private var accessibilityRequestTask: Task<Void, Never>?

    func motion(_ animation: Animation) -> Animation {
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
            self?.applyHealth(.ready(
                limits.isEmpty ? "当前没有返回限额桶" : "已读取 \(limits.count) 个动态限额桶"
            ), to: .codex)
        },
        onHealth: { [weak self] health in
            self?.applyHealth(health, to: .codex)
        }
    )

    private lazy var mediaService = MediaService(
        onSnapshot: { [weak self] snapshot in
            self?.media = snapshot
            self?.applyHealth(snapshot == .idle
                ? .warning("未检测到正在播放的曲目")
                : .ready("正在读取 \(snapshot.sourceName)"), to: .media)
        },
        onHealth: { [weak self] health in
            self?.applyHealth(health, to: .media)
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
            self?.applyHealth(health, to: .notifications)
        }
    )

    private lazy var trashService = TrashService(
        onCount: { [weak self] count in
            self?.trashCount = count
            if let count {
                self?.applyHealth(.ready(
                    count == 0 ? "废纸篓为空" : "废纸篓中有 \(count) 项"
                ), to: .trash)
            }
        },
        onHealth: { [weak self] health in
            self?.applyHealth(health, to: .trash)
        }
    )

    private lazy var powerService = PowerMonitorService(
        onSnapshot: { [weak self] power, chargeLimit in
            self?.power = power
            self?.chargeLimit = chargeLimit
        },
        onHealth: { [weak self] health in
            self?.applyHealth(health, to: .power)
        }
    )

    lazy var systemHUDService = SystemHUDService(
        onEvent: { [weak self] snapshot in
            self?.showSystemHUD(snapshot)
        }
    )

    let updateService = UpdateService()
    let launchAtLoginService = LaunchAtLoginService()

    lazy var refreshScheduler = BackgroundRefreshScheduler(jobs: [
        .init(
            id: .notifications,
            compactInterval: 2,
            interactiveInterval: 1.25,
            action: { [weak self] in self?.notificationService.refreshNow() }
        ),
        .init(
            id: .media,
            compactInterval: 5,
            interactiveInterval: 2,
            action: { [weak self] in self?.mediaService.refresh() }
        ),
        .init(
            id: .power,
            compactInterval: 15,
            interactiveInterval: 3,
            action: { [weak self] in self?.powerService.refresh() }
        ),
        .init(
            id: .trash,
            compactInterval: 30,
            interactiveInterval: 10,
            action: { [weak self] in self?.trashService.refresh() }
        ),
        .init(
            id: .codex,
            compactInterval: 60,
            interactiveInterval: 60,
            action: { [weak self] in self?.codexService.refresh() }
        ),
        .init(
            id: .brightness,
            compactInterval: 8,
            interactiveInterval: 4,
            action: { [weak self] in self?.systemHUDService.refreshBrightness() }
        ),
        .init(
            id: .updates,
            compactInterval: 6 * 60 * 60,
            interactiveInterval: 6 * 60 * 60,
            refreshOnResume: false,
            action: { [weak self] in self?.checkForUpdates(manual: false) }
        )
    ])

    private lazy var activityMonitor = AppActivityMonitor { [weak self] paused, reason in
        self?.setBackgroundRefreshPaused(paused, reason: reason)
    }

    func start() {
        codexService.start()
        mediaService.start()
        notificationService.autoDismissBanners = autoDismissBanners
        notificationService.start(promptForAccessibility: true)
        trashService.start()
        powerService.start()
        systemHUDService.start()
        refreshLaunchAtLoginStatus()
        refreshScheduler.start()
        activityMonitor.start()
        checkForUpdates(manual: false)
        diagnostics.recordLifecycle("应用服务已启动；后台刷新由统一调度器管理")
    }

    func stop() {
        activityMonitor.stop()
        refreshScheduler.stop()
        pulseTask?.cancel()
        systemHUDDismissTask?.cancel()
        hoverCollapseTask?.cancel()
        panelCloseTask?.cancel()
        updateTask?.cancel()
        accessibilityRequestTask?.cancel()
        codexService.stop()
        mediaService.stop()
        notificationService.stop()
        trashService.stop()
        powerService.stop()
        systemHUDService.stop()
        diagnostics.recordLifecycle("应用服务已停止")
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
        refreshScheduler.setInteractive(true)
        notificationService.refreshNow()
        trashService.refresh()
        powerService.refresh()
    }

    func collapseExpanded() {
        guard isExpanded, !isPanelClosing else { return }
        hoverCollapseTask?.cancel()
        isNotchCanvasExpanded = true
        isPanelClosing = true
        refreshScheduler.setInteractive(false)

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

    func requestAccessibility() {
        accessibilityRequestTask?.cancel()
        let shouldWaitForPanel = isExpanded || isPanelClosing
        if isExpanded {
            collapseExpanded()
        }
        applyHealth(.loading("正在打开辅助功能权限设置"), to: .notifications)

        accessibilityRequestTask = Task { [weak self] in
            try? await Task.sleep(
                for: shouldWaitForPanel
                    ? .milliseconds(760)
                    : .milliseconds(120)
            )
            guard !Task.isCancelled, let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.notificationService.requestAccessibility()
        }
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
        if let message = trashService.emptyTrash() {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.updatePrompt = AppUpdatePrompt(
                    title: "无法清空废纸篓",
                    message: message,
                    release: nil
                )
            }
        }
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
