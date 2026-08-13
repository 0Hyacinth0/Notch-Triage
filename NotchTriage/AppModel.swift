import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum CodexDisplayMode: String, CaseIterable, Codable, Identifiable, Sendable {
        case weekly
        case balance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .weekly: return "每周限额"
            case .balance: return "Credits 余额"
            }
        }
    }

    enum PreferenceKey {
        static let leftWingContent = "notch.leftWingContent"
        static let rightWingContent = "notch.rightWingContent"
        static let ringAppearance = "notch.ringAppearance"
        static let liquidGlassLevel = "notch.liquidGlassLevel.v2"
        static let legacyLiquidGlassStyle = "notch.liquidGlassStyle"
        static let notificationPromptIcon = "notch.notificationPromptIcon"
        static let notificationPromptColor = "notch.notificationPromptColor"
        static let notificationPromptAnimation = "notch.notificationPromptAnimation"
        static let legacyNotificationEyeStyle = "notch.notificationEyeStyle"
        static let codexDisplayMode = "notch.codexDisplayMode"
        static let workspaceSection = "notch.workspace.lastSection"
        static let clipboardHistoryEnabled = "notch.clipboard.historyEnabled"
        static let clipboardRetentionPolicy = "notch.clipboard.retentionPolicy"
        static let lastUpdateCheck = "updates.lastSuccessfulCheck"
        static let lastPromptedVersion = "updates.lastPromptedVersion"
    }

    @Published private(set) var panelState = PanelState()
    @Published var workspaceSection: WorkspaceSection {
        didSet {
            UserDefaults.standard.set(
                workspaceSection.rawValue,
                forKey: PreferenceKey.workspaceSection
            )
        }
    }
    @Published private(set) var fileShelfItems: [FileShelfItem] = []
    @Published private(set) var fileShelfFeedback: String?
    @Published private(set) var clipboardHistoryEnabled: Bool
    @Published private(set) var clipboardRetentionPolicy: ClipboardRetentionPolicy
    @Published private(set) var clipboardHistoryItems: [ClipboardHistoryItem] = []
    @Published private(set) var clipboardFeedback: String?
    @Published private(set) var clipboardAccessNotice: String?
    @Published private(set) var isClipboardMonitoringActive = false
    @Published var menuBarHeight: CGFloat = 37
    @Published var notchWidth: CGFloat = 186
    @Published var media = MediaSnapshot.idle
    @Published var codexLimits: [CodexLimitBucket] = []
    @Published var codexCredits: CodexCreditsBalance? = nil
    @Published var codexDisplayMode: CodexDisplayMode {
        didSet {
            UserDefaults.standard.set(
                codexDisplayMode.rawValue,
                forKey: PreferenceKey.codexDisplayMode
            )
        }
    }
    @Published var notificationSources: [NotificationSource] = []
    @Published var notificationPulse: NotificationPulse?
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

    @Published var ringAppearance: RingAppearanceSettings {
        didSet {
            guard let data = try? JSONEncoder().encode(ringAppearance) else { return }
            UserDefaults.standard.set(data, forKey: PreferenceKey.ringAppearance)
        }
    }

    @Published private(set) var liquidGlassLevel: Double

    @Published var notificationPromptIcon: NotificationPromptIcon {
        didSet {
            UserDefaults.standard.set(
                notificationPromptIcon.rawValue,
                forKey: PreferenceKey.notificationPromptIcon
            )
        }
    }

    @Published var notificationPromptColor: NotificationPromptColor {
        didSet {
            UserDefaults.standard.set(
                notificationPromptColor.rawValue,
                forKey: PreferenceKey.notificationPromptColor
            )
        }
    }

    @Published var notificationPromptAnimation: NotificationPromptAnimation {
        didSet {
            UserDefaults.standard.set(
                notificationPromptAnimation.rawValue,
                forKey: PreferenceKey.notificationPromptAnimation
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
    @Published var accessibilityRepairSuggested = false

    let diagnostics = DiagnosticsStore()

    @Published var autoDismissBanners = true {
        didSet {
            notificationService.autoDismissBanners = autoDismissBanners
        }
    }

    var notificationAttentionActive: Bool {
        notificationPulse != nil || !notificationSources.isEmpty
    }

    /// The one-week rolling bucket, falling back to the largest available
    /// window when the server does not expose exactly 10,080 minutes.
    var weeklyCodexLimit: CodexLimitBucket? {
        Self.weeklyCodexLimit(from: codexLimits)
    }

    nonisolated static func weeklyCodexLimit(
        from limits: [CodexLimitBucket]
    ) -> CodexLimitBucket? {
        let validLimits = limits.filter { $0.windowMinutes > 0 }
        let weekly = validLimits.filter { $0.windowMinutes == 10_080 }
        if let exact = weekly.min(by: preferredLimitOrder) {
            return exact
        }
        return validLimits.max(by: preferredLimitOrder)
    }

    private nonisolated static func preferredLimitOrder(
        _ lhs: CodexLimitBucket,
        _ rhs: CodexLimitBucket
    ) -> Bool {
        if lhs.windowMinutes != rhs.windowMinutes {
            return lhs.windowMinutes < rhs.windowMinutes
        }
        return lhs.id < rhs.id
    }

    @Published private(set) var notificationAnimationTick = 0

    var pulseTask: Task<Void, Never>?
    var systemHUDDismissTask: Task<Void, Never>?
    var hoverCollapseTask: Task<Void, Never>?
    var panelCloseTask: Task<Void, Never>?
    var updateTask: Task<Void, Never>?
    var updatePromptPresentationTask: Task<Void, Never>?
    var settingsWindowTask: Task<Void, Never>?
    var fileDropActivationTask: Task<Void, Never>?
    var fileDropExitTask: Task<Void, Never>?
    var fileDropSafetyTask: Task<Void, Never>?
    var fileShelfAddTask: Task<Void, Never>?
    var fileShelfMaintenanceTask: Task<Void, Never>?
    var fileShelfFeedbackTask: Task<Void, Never>?
    var clipboardStoreTask: Task<Void, Never>?
    var clipboardFeedbackTask: Task<Void, Never>?
    var pendingFileDropSessionID: UUID?
    /// The drag session whose accepted payload is still being persisted.
    ///
    /// This is deliberately separate from `pendingFileDropSessionID`: the
    /// latter only covers the AppKit drag-enter/activation window, while this
    /// session remains live until the async shelf mutation has settled.
    @Published private(set) var fileDropInFlightSessionID: UUID?
    var settingsWindowOpener: (() -> Void)?
    private var accessibilityRequestTask: Task<Void, Never>?
    private var notificationAnimationTask: Task<Void, Never>?
    private var acceptsSystemHUDEvents = false
    let fileShelfStore = FileShelfStore()
    let clipboardStore: ClipboardStore
    let pasteboardAccess = GeneralPasteboardAccess()
    var clipboardMonitor: ClipboardMonitor?
    var clipboardLifecycleGeneration: UInt64 = 0
    var areApplicationServicesRunning = false

    func replacePanelState(_ state: PanelState) {
        panelState = state
    }

    func replaceFileShelfItems(_ items: [FileShelfItem]) {
        fileShelfItems = items
    }

    func replaceFileShelfFeedback(_ feedback: String?) {
        fileShelfFeedback = feedback
    }

    func replaceClipboardHistoryItems(_ items: [ClipboardHistoryItem]) {
        clipboardHistoryItems = items
    }

    func replaceClipboardFeedback(_ feedback: String?) {
        clipboardFeedback = feedback
    }

    func replaceClipboardHistoryEnabled(_ enabled: Bool) {
        clipboardHistoryEnabled = enabled
    }

    func replaceClipboardRetentionPolicy(_ policy: ClipboardRetentionPolicy) {
        clipboardRetentionPolicy = policy
    }

    func replaceClipboardAccessNotice(_ notice: String?) {
        clipboardAccessNotice = notice
    }

    func replaceClipboardMonitoringActive(_ active: Bool) {
        isClipboardMonitoringActive = active
    }

    var isFileDropInFlight: Bool {
        fileDropInFlightSessionID != nil
    }

    func beginFileDropInFlight(sessionID: UUID) {
        fileDropInFlightSessionID = sessionID
    }

    func finishFileDropInFlight(sessionID: UUID) {
        guard fileDropInFlightSessionID == sessionID else { return }
        fileDropInFlightSessionID = nil
    }

    func cancelFileDropInFlight() {
        fileDropInFlightSessionID = nil
    }

    func motion(_ animation: Animation) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .linear(duration: 0.01)
            : animation
    }

    init() {
        let defaults = UserDefaults.standard
        workspaceSection = WorkspaceSection.restored(
            from: defaults.string(forKey: PreferenceKey.workspaceSection)
        )
        clipboardHistoryEnabled = defaults.bool(
            forKey: PreferenceKey.clipboardHistoryEnabled
        )
        let restoredClipboardRetentionPolicy = ClipboardRetentionPolicy(
            rawValue: defaults.string(
                forKey: PreferenceKey.clipboardRetentionPolicy
            ) ?? ""
        ) ?? .session
        clipboardRetentionPolicy = restoredClipboardRetentionPolicy
        clipboardStore = ClipboardStore(
            retentionPolicy: restoredClipboardRetentionPolicy
        )
        leftWingContent = NotchWingContent(
            rawValue: defaults.string(
                forKey: PreferenceKey.leftWingContent
            ) ?? ""
        ) ?? .media
        rightWingContent = NotchWingContent(
            rawValue: defaults.string(
                forKey: PreferenceKey.rightWingContent
            ) ?? ""
        ) ?? .codex
        codexDisplayMode = CodexDisplayMode(
            rawValue: defaults.string(
                forKey: PreferenceKey.codexDisplayMode
            ) ?? ""
        ) ?? .weekly
        let legacyPromptIcon: NotificationPromptIcon
        switch defaults.string(
            forKey: PreferenceKey.legacyNotificationEyeStyle
        ) {
        case "filled": legacyPromptIcon = .sparkles
        case "circle": legacyPromptIcon = .sun
        default: legacyPromptIcon = .sparkle
        }
        notificationPromptIcon = NotificationPromptIcon(
            rawValue: defaults.string(
                forKey: PreferenceKey.notificationPromptIcon
            ) ?? ""
        ) ?? legacyPromptIcon
        notificationPromptColor = NotificationPromptColor(
            rawValue: defaults.string(
                forKey: PreferenceKey.notificationPromptColor
            ) ?? ""
        ) ?? .mint
        notificationPromptAnimation = NotificationPromptAnimation(
            rawValue: defaults.string(
                forKey: PreferenceKey.notificationPromptAnimation
            ) ?? ""
        ) ?? .pulse
        if let data = defaults.data(forKey: PreferenceKey.ringAppearance),
           let savedAppearance = try? JSONDecoder().decode(
               RingAppearanceSettings.self,
               from: data
           ) {
            ringAppearance = savedAppearance
        } else {
            ringAppearance = .default
        }
        liquidGlassLevel = LiquidGlassAppearance.restored(
            persistedLevel: defaults.object(forKey: PreferenceKey.liquidGlassLevel),
            legacyStyle: defaults.string(forKey: PreferenceKey.legacyLiquidGlassStyle)
        ).level
        notificationAnimationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_200))
                guard !Task.isCancelled, let self else { return }
                guard self.notificationAttentionActive else { continue }
                self.notificationAnimationTick &+= 1
            }
        }
    }

    private lazy var codexService = CodexUsageService(
        onUsage: { [weak self] limits, credits in
            self?.codexLimits = limits
            self?.codexCredits = credits
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
            if case .ready = health {
                self?.accessibilityRepairSuggested = false
            }
            self?.applyHealth(health, to: .notifications)
        },
        onAuthorizationRepairSuggested: { [weak self] in
            self?.accessibilityRepairSuggested = true
            self?.diagnostics.recordLifecycle(
                "多次检查仍未获得辅助功能权限，可能存在旧构建授权记录",
                level: .warning
            )
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
            compactInterval: 1.5,
            interactiveInterval: 1,
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
            action: { [weak self] in
                self?.checkForUpdates(context: .automatic)
            }
        )
    ])

    private lazy var activityMonitor = AppActivityMonitor { [weak self] paused, reason in
        self?.setBackgroundRefreshPaused(paused, reason: reason)
    }

    func start() {
        areApplicationServicesRunning = true
        codexService.start()
        mediaService.start()
        notificationService.autoDismissBanners = autoDismissBanners
        notificationService.start(promptForAccessibility: true)
        trashService.start()
        powerService.start()
        acceptsSystemHUDEvents = true
        systemHUDService.start()
        refreshLaunchAtLoginStatus()
        refreshScheduler.start()
        activityMonitor.start()
        startClipboardHistoryLifecycle()
        checkForUpdates(context: .automatic)
        diagnostics.recordLifecycle("应用服务已启动；后台刷新由统一调度器管理")
    }

    func stop() {
        areApplicationServicesRunning = false
        stopClipboardHistoryLifecycle()
        acceptsSystemHUDEvents = false
        activityMonitor.stop()
        refreshScheduler.stop()
        pulseTask?.cancel()
        notificationAnimationTask?.cancel()
        systemHUDDismissTask?.cancel()
        hoverCollapseTask?.cancel()
        panelCloseTask?.cancel()
        updateTask?.cancel()
        updatePromptPresentationTask?.cancel()
        settingsWindowTask?.cancel()
        fileDropActivationTask?.cancel()
        fileDropExitTask?.cancel()
        fileDropSafetyTask?.cancel()
        fileShelfAddTask?.cancel()
        fileShelfMaintenanceTask?.cancel()
        fileShelfFeedbackTask?.cancel()
        clipboardStoreTask?.cancel()
        clipboardFeedbackTask?.cancel()
        cancelFileDropInFlight()
        pendingFileDropSessionID = nil
        accessibilityRequestTask?.cancel()
        codexService.stop()
        mediaService.stop()
        notificationService.stop()
        trashService.stop()
        powerService.stop()
        systemHUDService.stop()
        fileShelfItems.removeAll()
        fileShelfFeedback = nil
        Task { [fileShelfStore] in
            _ = await fileShelfStore.removeAll()
        }
        sendPanelEvent(.reset)
        diagnostics.recordLifecycle("应用服务已停止")
    }

    func toggleExpanded() {
        guard !panelState.blocksOrdinaryPanelInput,
              !isPanelClosing else { return }
        if isExpanded {
            collapseExpanded()
            return
        }

        sendPanelEvent(.workspaceOpened)
        if let updatePrompt, updatePrompt.release != nil {
            sendPanelEvent(
                .releaseUpdatePromptPresented(id: updatePrompt.id)
            )
        }
        refreshScheduler.setInteractive(true)
        notificationService.refreshNow()
        trashService.refresh()
        powerService.refresh()
    }

    func collapseExpanded() {
        guard isExpanded,
              !isPanelClosing,
              !panelState.blocksOrdinaryPanelInput else { return }
        sendPanelEvent(.workspaceCloseRequested)
        refreshScheduler.setInteractive(false)
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

    func presentAccessibilityRepairPrompt() {
        updatePrompt = AppUpdatePrompt(
            title: "修复辅助功能授权？",
            message: "macOS 可能仍在使用旧构建的授权记录。继续后只会重置 Notch Triage 的辅助功能权限，并立即打开系统设置让你重新开启；其他 App 的权限不会变化。",
            release: nil,
            recovery: .resetAccessibility
        )
    }

    func repairAccessibilityAuthorization() {
        accessibilityRequestTask?.cancel()
        let shouldWaitForPanel = isExpanded || isPanelClosing
        if isExpanded {
            collapseExpanded()
        }
        accessibilityRepairSuggested = false
        applyHealth(.loading("正在清除旧的辅助功能授权记录"), to: .notifications)
        diagnostics.recordLifecycle("用户确认修复辅助功能授权记录")

        accessibilityRequestTask = Task { [weak self] in
            try? await Task.sleep(
                for: shouldWaitForPanel
                    ? .milliseconds(760)
                    : .milliseconds(120)
            )
            guard !Task.isCancelled, let self else { return }

            let bundleIdentifier = Bundle.main.bundleIdentifier
                ?? "com.hyacinth.notchtriage"
            let errorMessage = await Task.detached(priority: .userInitiated) {
                NotificationBridge.resetSystemAccessibilityAuthorization(
                    bundleIdentifier: bundleIdentifier
                )
            }.value
            guard !Task.isCancelled else { return }

            if let errorMessage {
                self.applyHealth(
                    .failed("无法重置辅助功能授权：\(errorMessage)"),
                    to: .notifications
                )
                self.updatePrompt = AppUpdatePrompt(
                    title: "无法修复辅助功能授权",
                    message: errorMessage,
                    release: nil
                )
                return
            }

            self.diagnostics.recordLifecycle("已清除旧授权记录，正在请求当前构建权限")
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

    func setWorkspaceSection(_ section: WorkspaceSection) {
        withAnimation(motion(NotchDesign.Motion.sectionChange)) {
            workspaceSection = section
        }
        if section == .shelf {
            refreshFileShelfAvailability()
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

    func setRingTheme(_ theme: RingTheme) {
        withAnimation(motion(NotchDesign.Motion.value)) {
            ringAppearance.theme = theme
        }
    }

    func setNotificationPromptIcon(_ icon: NotificationPromptIcon) {
        withAnimation(motion(NotchDesign.Motion.value)) {
            notificationPromptIcon = icon
        }
    }

    func setNotificationPromptColor(_ color: NotificationPromptColor) {
        withAnimation(motion(NotchDesign.Motion.value)) {
            notificationPromptColor = color
        }
    }

    func setNotificationPromptAnimation(_ animation: NotificationPromptAnimation) {
        withAnimation(motion(NotchDesign.Motion.value)) {
            notificationPromptAnimation = animation
        }
    }

    func resetRingAppearance() {
        withAnimation(motion(NotchDesign.Motion.value)) {
            ringAppearance = .default
        }
    }

    func setLiquidGlassLevel(_ level: Double) {
        let normalized = LiquidGlassAppearance.normalized(level)
        guard normalized != liquidGlassLevel else { return }
        liquidGlassLevel = normalized
        UserDefaults.standard.set(normalized, forKey: PreferenceKey.liquidGlassLevel)
    }

    func ringOverride(for metric: RingMetric) -> RingStyleOverride {
        ringAppearance.override(for: metric)
    }

    func setRingOverrideEnabled(_ enabled: Bool, for metric: RingMetric) {
        var updated = ringAppearance
        switch metric {
        case .battery: updated.battery.isEnabled = enabled
        case .codex: updated.codex.isEnabled = enabled
        case .media: updated.media.isEnabled = enabled
        }
        withAnimation(motion(NotchDesign.Motion.value)) {
            ringAppearance = updated
        }
    }

    func setRingGradientMode(_ mode: RingGradientMode, for metric: RingMetric) {
        var updated = ringAppearance
        switch metric {
        case .battery: updated.battery.style.gradientMode = mode
        case .codex: updated.codex.style.gradientMode = mode
        case .media: updated.media.style.gradientMode = mode
        }
        ringAppearance = updated
    }

    func setRingColor(_ color: Color, for metric: RingMetric, component: RingColorComponent) {
        var updated = ringAppearance
        let ringColor = RingColor(color)
        switch metric {
        case .battery:
            update(&updated.battery.style, color: ringColor, component: component)
        case .codex:
            update(&updated.codex.style, color: ringColor, component: component)
        case .media:
            update(&updated.media.style, color: ringColor, component: component)
        }
        ringAppearance = updated
    }

    private func update(
        _ style: inout RingStyle,
        color: RingColor,
        component: RingColorComponent
    ) {
        switch component {
        case .start: style.start = color
        case .end: style.end = color
        case .track: style.track = color
        }
    }

    func setNotchHovered(_ hovered: Bool) {
        if hovered {
            withAnimation(motion(NotchDesign.Motion.hover)) {
                sendPanelEvent(.pointerEntered)
            }
        } else {
            sendPanelEvent(.pointerExited)
        }
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func openSettings() {
        guard panelState.presentationOverride != .installingUpdate else { return }
        let shouldWaitForPanel = isExpanded || isPanelClosing
        if isExpanded {
            collapseExpanded()
        }

        settingsWindowTask?.cancel()
        settingsWindowTask = Task { [weak self] in
            if shouldWaitForPanel {
                try? await Task.sleep(for: .milliseconds(420))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled, self != nil else { return }
            guard let self else { return }
            if let settingsWindowOpener = self.settingsWindowOpener {
                settingsWindowOpener()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(
                    Selector(("showSettingsWindow:")),
                    to: nil,
                    from: nil
                )
            }
        }
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
        guard acceptsSystemHUDEvents,
              !isBackgroundRefreshPaused else { return }
        let isContinuousUpdate = systemHUD?.kind == snapshot.kind

        withAnimation(
            motion(
                isContinuousUpdate
                    ? NotchDesign.Motion.value
                    : NotchDesign.Motion.panelOpen
            )
        ) {
            sendPanelEvent(.hudReceived(snapshot))
        }
    }
}
