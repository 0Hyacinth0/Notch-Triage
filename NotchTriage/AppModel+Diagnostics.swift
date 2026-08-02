import AppKit
import Foundation

extension AppModel {
    func applyHealth(_ health: ServiceHealth, to service: DiagnosticService) {
        switch service {
        case .media:
            mediaHealth = health
        case .notifications:
            notificationHealth = health
        case .power:
            powerHealth = health
        case .codex:
            codexHealth = health
        case .updates:
            break
        case .trash:
            trashHealth = health
        }
        diagnostics.update(service, health: health)
    }

    func refreshDiagnostics() {
        diagnostics.recordLifecycle("用户请求立即刷新全部服务")
        refreshScheduler.refreshAll()
    }

    func copyDiagnosticReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticReport, forType: .string)
        diagnostics.recordLifecycle("诊断报告已复制到剪贴板")
    }

    var diagnosticReport: String {
        diagnostics.report(
            version: currentVersion,
            isPaused: isBackgroundRefreshPaused,
            launchAtLoginDescription: launchAtLoginStatusDescription
        )
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let snapshot = launchAtLoginService.setEnabled(enabled)
        applyLaunchAtLoginSnapshot(snapshot)
        diagnostics.recordLifecycle(
            enabled ? "已请求启用开机启动" : "已请求关闭开机启动",
            level: healthEventLevel(snapshot.health)
        )
    }

    func refreshLaunchAtLoginStatus() {
        applyLaunchAtLoginSnapshot(launchAtLoginService.snapshot())
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    var launchAtLoginStatusDescription: String {
        if launchAtLoginRequiresApproval { return "等待系统批准" }
        return launchAtLoginEnabled ? "已启用" : launchAtLoginHealth.message
    }

    func setBackgroundRefreshPaused(_ paused: Bool, reason: String) {
        isBackgroundRefreshPaused = paused
        refreshScheduler.setSuspended(paused)

        if paused {
            systemHUDDismissTask?.cancel()
            systemHUD = nil
            systemHUDService.stop()
        } else {
            systemHUDService.start()
        }

        diagnostics.recordLifecycle(
            paused ? "后台刷新已暂停：\(reason)" : "后台刷新已恢复：\(reason)"
        )
    }

    private func applyLaunchAtLoginSnapshot(_ snapshot: LaunchAtLoginService.Snapshot) {
        launchAtLoginEnabled = snapshot.isRequested
        launchAtLoginRequiresApproval = snapshot.requiresApproval
        launchAtLoginHealth = snapshot.health
    }

    private func healthEventLevel(_ health: ServiceHealth) -> DiagnosticEventLevel {
        switch health {
        case .loading, .ready: return .info
        case .warning: return .warning
        case .failed: return .error
        }
    }
}
