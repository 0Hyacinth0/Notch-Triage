import SwiftUI

struct DiagnosticsDashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var diagnostics: DiagnosticsStore

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    init(model: AppModel) {
        self.model = model
        _diagnostics = ObservedObject(wrappedValue: model.diagnostics)
    }

    var body: some View {
        VStack(spacing: 12) {
            schedulerCard

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(DiagnosticService.allCases) { service in
                    if let record = diagnostics.records[service] {
                        serviceCard(record)
                    }
                }
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var schedulerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        model.isBackgroundRefreshPaused
                            ? Color.orange.opacity(0.14)
                            : Color.green.opacity(0.14)
                    )
                Image(
                    systemName: model.isBackgroundRefreshPaused
                        ? "pause.fill"
                        : "leaf.fill"
                )
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.isBackgroundRefreshPaused ? .orange : .green)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.isBackgroundRefreshPaused ? "后台刷新已暂停" : "节能调度正常")
                    .font(.system(size: 13, weight: .semibold))
                Text(
                    model.isBackgroundRefreshPaused
                        ? "解锁或唤醒后会自动刷新全部状态"
                        : "7 项任务共享一个带容差的唤醒计时器"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("v\(model.currentVersion)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(model.launchAtLoginStatusDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .panelGroupSurface(cornerRadius: NotchDesign.Radius.compactGroup)
    }

    private func serviceCard(_ record: ServiceDiagnosticRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: record.service.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: record.health.color))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(record.service.title)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 2)
                    Circle()
                        .fill(Color(nsColor: record.health.color))
                        .frame(width: 6, height: 6)
                }

                Text(record.health.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(record.lastCheckedAt, style: .relative)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .panelGroupSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.service.title)，\(record.health.message)")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let event = diagnostics.events.last {
                Image(
                    systemName: event.level == .error
                        ? "xmark.octagon.fill"
                        : (event.level == .warning
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill")
                )
                .foregroundStyle(
                    event.level == .error
                        ? .red
                        : (event.level == .warning ? .orange : .secondary)
                )
                Text(event.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("尚无诊断事件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                model.refreshDiagnostics()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("立即刷新全部服务")

            Button {
                model.copyDiagnosticReport()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .help("复制诊断报告")
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .frame(height: 26)
    }
}
