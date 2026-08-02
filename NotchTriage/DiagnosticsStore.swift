import Foundation
import OSLog

@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published private(set) var records: [DiagnosticService: ServiceDiagnosticRecord]
    @Published private(set) var events: [DiagnosticEvent] = []

    private static let subsystem = Bundle.main.bundleIdentifier
        ?? "com.hyacinth.notchtriage"
    private static let logger = Logger(
        subsystem: subsystem,
        category: "Diagnostics"
    )

    init() {
        let now = Date()
        records = Dictionary(
            uniqueKeysWithValues: DiagnosticService.allCases.map { service in
                (
                    service,
                    ServiceDiagnosticRecord(
                        service: service,
                        health: .loading("等待首次检查"),
                        lastCheckedAt: now,
                        lastHealthyAt: nil
                    )
                )
            }
        )
    }

    func update(_ service: DiagnosticService, health: ServiceHealth) {
        let now = Date()
        let previous = records[service]
        let lastHealthyAt: Date?
        if case .ready = health {
            lastHealthyAt = now
        } else {
            lastHealthyAt = previous?.lastHealthyAt
        }

        records[service] = ServiceDiagnosticRecord(
            service: service,
            health: health,
            lastCheckedAt: now,
            lastHealthyAt: lastHealthyAt
        )

        guard previous?.health != health else { return }
        switch health {
        case .loading(let message):
            Self.logger.info("[\(service.rawValue, privacy: .public)] \(message, privacy: .public)")
            append(.info, service: service, message: message, at: now)
        case .ready(let message):
            Self.logger.info("[\(service.rawValue, privacy: .public)] \(message, privacy: .public)")
            append(.info, service: service, message: message, at: now)
        case .warning(let message):
            Self.logger.warning("[\(service.rawValue, privacy: .public)] \(message, privacy: .public)")
            append(.warning, service: service, message: message, at: now)
        case .failed(let message):
            Self.logger.error("[\(service.rawValue, privacy: .public)] \(message, privacy: .public)")
            append(.error, service: service, message: message, at: now)
        }
    }

    func recordLifecycle(_ message: String, level: DiagnosticEventLevel = .info) {
        switch level {
        case .info:
            Self.logger.info("[lifecycle] \(message, privacy: .public)")
        case .warning:
            Self.logger.warning("[lifecycle] \(message, privacy: .public)")
        case .error:
            Self.logger.error("[lifecycle] \(message, privacy: .public)")
        }
        append(level, service: nil, message: message, at: Date())
    }

    func report(
        version: String,
        isPaused: Bool,
        launchAtLoginDescription: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Notch Triage v\(version)",
            "Generated: \(formatter.string(from: Date()))",
            "Background refresh: \(isPaused ? "paused" : "active")",
            "Launch at login: \(launchAtLoginDescription)",
            ""
        ]

        for service in DiagnosticService.allCases {
            guard let record = records[service] else { continue }
            lines.append(
                "[\(service.rawValue)] \(healthLabel(record.health)): "
                    + record.health.message
                    + " (checked \(formatter.string(from: record.lastCheckedAt)))"
            )
        }

        if !events.isEmpty {
            lines.append("")
            lines.append("Recent events:")
            for event in events.suffix(20) {
                let service = event.service?.rawValue ?? "lifecycle"
                lines.append(
                    "\(formatter.string(from: event.date)) "
                        + "[\(event.level.rawValue)] [\(service)] \(event.message)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private func append(
        _ level: DiagnosticEventLevel,
        service: DiagnosticService?,
        message: String,
        at date: Date
    ) {
        events.append(
            DiagnosticEvent(
                date: date,
                service: service,
                level: level,
                message: message
            )
        )
        if events.count > 80 {
            events.removeFirst(events.count - 80)
        }
    }

    private func healthLabel(_ health: ServiceHealth) -> String {
        switch health {
        case .loading: return "loading"
        case .ready: return "ready"
        case .warning: return "warning"
        case .failed: return "failed"
        }
    }
}
