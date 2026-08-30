import Foundation

/// Command IDs are kept in sync with `MRACommand` in the bundled
/// MediaRemoteAdapter framework.
enum MediaCommand: Int, CaseIterable, Equatable, Sendable {
    case previousTrack = 5
    case togglePlayPause = 2
    case nextTrack = 4

    var title: String {
        switch self {
        case .previousTrack:
            return "上一首"
        case .togglePlayPause:
            return "播放/暂停"
        case .nextTrack:
            return "下一首"
        }
    }

    var systemImage: String {
        switch self {
        case .previousTrack:
            return "backward.end.fill"
        case .togglePlayPause:
            return "playpause.fill"
        case .nextTrack:
            return "forward.end.fill"
        }
    }

    var isSkipCommand: Bool {
        switch self {
        case .previousTrack, .nextTrack:
            return true
        case .togglePlayPause:
            return false
        }
    }
}

struct MediaCommandAvailability: Equatable, Sendable {
    let hasMedia: Bool
    let transportAvailable: Bool
    let prohibitsSkip: Bool
    let isBusy: Bool

    func isEnabled(for command: MediaCommand) -> Bool {
        guard hasMedia, transportAvailable, !isBusy else { return false }
        return !command.isSkipCommand || !prohibitsSkip
    }

    func disabledReason(for command: MediaCommand) -> String? {
        if !hasMedia {
            return "没有正在播放的媒体"
        }
        if isBusy {
            return "正在发送媒体控制命令"
        }
        if command.isSkipCommand, prohibitsSkip {
            return "当前媒体禁止跳过"
        }
        if !transportAvailable {
            return "媒体控制适配器不可用"
        }
        return nil
    }
}

@MainActor
protocol MediaCommandSending {
    var isAvailable: Bool { get }
    func send(_ command: MediaCommand) async -> Bool
}
