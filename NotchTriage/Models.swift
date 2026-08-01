import AppKit
import Foundation

enum NotchWingContent: String, CaseIterable, Identifiable {
    case battery
    case codex
    case media
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: return "电池状态"
        case .codex: return "ChatGPT / Codex 额度"
        case .media: return "正在播放"
        case .hidden: return "不显示"
        }
    }

    var symbol: String {
        switch self {
        case .battery: return "battery.75"
        case .codex: return "gauge.with.dots.needle.67percent"
        case .media: return "music.note"
        case .hidden: return "eye.slash"
        }
    }
}

struct CodexLimitBucket: Identifiable, Equatable {
    let id: String
    let name: String
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var remainingFraction: Double {
        remainingPercent / 100
    }

    var windowLabel: String {
        if windowMinutes >= 1_440, windowMinutes.isMultiple(of: 1_440) {
            return "\(windowMinutes / 1_440) 天"
        }
        if windowMinutes >= 60, windowMinutes.isMultiple(of: 60) {
            return "\(windowMinutes / 60) 小时"
        }
        return "\(windowMinutes) 分钟"
    }
}

struct MediaSnapshot: Equatable {
    var sourceName: String
    var bundleIdentifier: String?
    var title: String
    var artist: String
    var duration: TimeInterval
    var elapsed: TimeInterval
    var isPlaying: Bool

    var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, elapsed / duration))
    }

    static let idle = MediaSnapshot(
        sourceName: "音乐",
        bundleIdentifier: nil,
        title: "没有正在播放的曲目",
        artist: "",
        duration: 0,
        elapsed: 0,
        isPlaying: false
    )
}

struct NotificationSource: Identifiable, Equatable {
    var id: String { bundleIdentifier ?? sourceName }
    let sourceName: String
    let bundleIdentifier: String?
    let count: Int
}

struct NotificationPulse: Identifiable, Equatable {
    let id = UUID()
    let sourceName: String
    let bundleIdentifier: String?
}

enum SystemHUDKind: Hashable {
    case volume
    case brightness
    case airPods
}

struct SystemHUDSnapshot: Identifiable, Equatable {
    let id = UUID()
    let kind: SystemHUDKind
    let title: String
    let subtitle: String
    let symbol: String
    let value: Double?

    static func volume(_ value: Double, muted: Bool) -> SystemHUDSnapshot {
        let normalized = max(0, min(1, value))
        let symbol: String
        if muted || normalized <= 0.001 {
            symbol = "speaker.slash.fill"
        } else if normalized < 0.34 {
            symbol = "speaker.wave.1.fill"
        } else if normalized < 0.67 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }

        return SystemHUDSnapshot(
            kind: .volume,
            title: muted ? "已静音" : "音量",
            subtitle: "\(Int((normalized * 100).rounded()))%",
            symbol: symbol,
            value: muted ? 0 : normalized
        )
    }

    static func brightness(_ value: Double) -> SystemHUDSnapshot {
        let normalized = max(0, min(1, value))
        return SystemHUDSnapshot(
            kind: .brightness,
            title: "显示亮度",
            subtitle: "\(Int((normalized * 100).rounded()))%",
            symbol: normalized < 0.4 ? "sun.min.fill" : "sun.max.fill",
            value: normalized
        )
    }

    static func airPods(name: String) -> SystemHUDSnapshot {
        SystemHUDSnapshot(
            kind: .airPods,
            title: name,
            subtitle: "已连接 · 音频输出",
            symbol: "airpodspro",
            value: nil
        )
    }
}

enum ServiceHealth: Equatable {
    case loading(String)
    case ready(String)
    case warning(String)
    case failed(String)

    var message: String {
        switch self {
        case .loading(let message), .ready(let message),
             .warning(let message), .failed(let message):
            return message
        }
    }

    var symbol: String {
        switch self {
        case .loading:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .loading:
            return .secondaryLabelColor
        case .ready:
            return .systemGreen
        case .warning:
            return .systemOrange
        case .failed:
            return .systemRed
        }
    }
}

struct ChargeLimitSnapshot: Equatable {
    var isSupported: Bool
    var isEnabled: Bool
    var configuredLimit: Int
    var effectiveLimit: Int
    var availableLimits: [Int]

    var isTemporarilyFilling: Bool {
        isEnabled && effectiveLimit > configuredLimit
    }

    static let unavailable = ChargeLimitSnapshot(
        isSupported: false,
        isEnabled: false,
        configuredLimit: 100,
        effectiveLimit: 100,
        availableLimits: [80, 85, 90, 95, 100]
    )
}

struct AdapterSnapshot: Equatable {
    var isConnected: Bool
    var currentAmps: Double?
    var voltageVolts: Double?
    var negotiatedWatts: Double?
    var ratedWatts: Double?
    var name: String
    var manufacturer: String
    var serialNumber: String?

    static let disconnected = AdapterSnapshot(
        isConnected: false,
        currentAmps: nil,
        voltageVolts: nil,
        negotiatedWatts: nil,
        ratedWatts: nil,
        name: "未连接电源适配器",
        manufacturer: "—",
        serialNumber: nil
    )
}

struct PowerSnapshot: Equatable {
    var batteryPercent: Int
    var isCharging: Bool
    var isFullyCharged: Bool
    var isExternalPowerConnected: Bool

    var designCapacityMAh: Int?
    var hardwareMaximumCapacityMAh: Int?
    var macOSMaximumCapacityMAh: Int?
    var currentCapacityMAh: Int?
    var cycleCount: Int?
    var healthStatus: String

    var temperatureCelsius: Double?
    var timeToFullMinutes: Int?
    var timeToEmptyMinutes: Int?
    var serialNumber: String?

    var batteryCurrentAmps: Double?
    var batteryVoltageVolts: Double?
    var batteryPowerWatts: Double?
    var systemLoadWatts: Double?
    var adapterInputWatts: Double?
    var lowPowerModeEnabled: Bool
    var adapter: AdapterSnapshot
    var updatedAt: Date

    var hardwareHealthPercent: Int? {
        percentage(hardwareMaximumCapacityMAh, of: designCapacityMAh)
    }

    var macOSHealthPercent: Int? {
        percentage(macOSMaximumCapacityMAh, of: designCapacityMAh)
    }

    var chargingWatts: Double? {
        guard isCharging,
              let batteryPowerWatts,
              batteryPowerWatts.isFinite else {
            return nil
        }
        return abs(batteryPowerWatts)
    }

    var maskedSerialNumber: String {
        guard let serialNumber, !serialNumber.isEmpty else { return "—" }
        return "•••• " + String(serialNumber.suffix(4))
    }

    static let empty = PowerSnapshot(
        batteryPercent: 0,
        isCharging: false,
        isFullyCharged: false,
        isExternalPowerConnected: false,
        designCapacityMAh: nil,
        hardwareMaximumCapacityMAh: nil,
        macOSMaximumCapacityMAh: nil,
        currentCapacityMAh: nil,
        cycleCount: nil,
        healthStatus: "正在读取",
        temperatureCelsius: nil,
        timeToFullMinutes: nil,
        timeToEmptyMinutes: nil,
        serialNumber: nil,
        batteryCurrentAmps: nil,
        batteryVoltageVolts: nil,
        batteryPowerWatts: nil,
        systemLoadWatts: nil,
        adapterInputWatts: nil,
        lowPowerModeEnabled: false,
        adapter: .disconnected,
        updatedAt: .distantPast
    )

    private func percentage(_ value: Int?, of total: Int?) -> Int? {
        guard let value, let total, total > 0 else { return nil }
        return Int((Double(value) / Double(total) * 100).rounded())
    }
}
