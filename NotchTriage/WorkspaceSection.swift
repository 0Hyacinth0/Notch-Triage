import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case power
    case notifications
    case shelf
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .power: return "电源"
        case .notifications: return "通知"
        case .shelf: return "暂存"
        case .clipboard: return "剪贴板"
        }
    }

    var symbol: String {
        switch self {
        case .power: return "bolt.fill"
        case .notifications: return "bell.fill"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "clipboard.fill"
        }
    }

    static func restored(from persistedValue: String?) -> WorkspaceSection {
        if persistedValue == "triage" {
            return .notifications
        }
        guard let persistedValue,
              let section = WorkspaceSection(rawValue: persistedValue) else {
            return .power
        }
        return section
    }
}
