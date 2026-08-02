import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService {
    struct Snapshot: Equatable {
        let isRequested: Bool
        let requiresApproval: Bool
        let description: String
        let health: ServiceHealth
    }

    func snapshot() -> Snapshot {
        switch SMAppService.mainApp.status {
        case .enabled:
            return Snapshot(
                isRequested: true,
                requiresApproval: false,
                description: "已启用",
                health: .ready("登录后将自动启动")
            )
        case .requiresApproval:
            return Snapshot(
                isRequested: true,
                requiresApproval: true,
                description: "等待系统批准",
                health: .warning("请在系统设置的登录项中批准 Notch Triage")
            )
        case .notRegistered:
            return Snapshot(
                isRequested: false,
                requiresApproval: false,
                description: "未启用",
                health: .ready("开机启动未启用")
            )
        case .notFound:
            return Snapshot(
                isRequested: false,
                requiresApproval: false,
                description: "当前构建不可用",
                health: .warning("请从“应用程序”文件夹运行后再启用")
            )
        @unknown default:
            return Snapshot(
                isRequested: false,
                requiresApproval: false,
                description: "未知状态",
                health: .warning("系统没有返回登录项状态")
            )
        }
    }

    func setEnabled(_ enabled: Bool) -> Snapshot {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return snapshot()
        } catch {
            return Snapshot(
                isRequested: snapshot().isRequested,
                requiresApproval: snapshot().requiresApproval,
                description: "设置失败",
                health: .failed("无法修改开机启动：\(error.localizedDescription)")
            )
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
